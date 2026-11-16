import Foundation

public enum Version {
  /// "0.10.1" → [0, 10, 1]. Empty parts are dropped; nil unless what is left
  /// is digits, since `Int` alone would also take the "+9" a feed could send.
  public static func components(_ v: String) -> [Int]? {
    let parts = v.split(separator: ".").map { $0.allSatisfy(\.isWholeNumber) ? Int($0) : nil }
    return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap { $0 }
  }

  /// Missing components count as 0. An unparseable side is never newer.
  public static func isNewer(_ a: String, than b: String) -> Bool {
    guard let a = components(a), let b = components(b) else { return false }
    let width = max(a.count, b.count)
    let padded = { (v: [Int]) in v + Array(repeating: 0, count: width - v.count) }
    return padded(b).lexicographicallyPrecedes(padded(a))
  }
}

/// How this bundle got here, which decides who may replace it.
public enum InstallKind: Equatable {
  case homebrew(brew: URL), mise(mise: URL), homebrewMissing, miseMissing, direct, development

  /// Where a `mise` may be: its own installer's path first, since an app opened from Finder has no shell PATH.
  public static let miseCandidates = [
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/mise"),
    URL(fileURLWithPath: "/opt/homebrew/bin/mise"),
    URL(fileURLWithPath: "/usr/local/bin/mise"),
  ]

  /// Stat only, never a subprocess. A second copy of the app beside a cask
  /// install is `direct`, since only the cask's own symlink proves brew owns it.
  public static func detect(
    bundleURL: URL,
    version: String?,
    prefixes: [URL] = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")],
    miseCandidates: [URL] = InstallKind.miseCandidates
  ) -> InstallKind {
    guard version != nil, bundleURL.pathExtension == "app" else { return .development }
    let fm = FileManager.default
    let bundle = bundleURL.resolvingSymlinksInPath().path
    // Every prefix's folders that link this bundle, before anything is decided: a link
    // left in one prefix must not hide mise's receipt in the other.
    let owned = prefixes.compactMap { prefix -> (prefix: URL, owners: [URL])? in
      let cask = prefix.appendingPathComponent("Caskroom/claude-multipass-app")
      let versions = (try? fm.contentsOfDirectory(at: cask, includingPropertiesForKeys: nil)) ?? []
      let owners = versions.filter { version in
        let link = version.appendingPathComponent("Claude Multipass.app")
        // A link to a deleted bundle does not resolve, so what it says it points at counts too.
        return link.resolvingSymlinksInPath().path == bundle || (try? fm.destinationOfSymbolicLink(atPath: link.path)) == bundleURL.path
      }
      return owners.isEmpty ? nil : (prefix, owners)
    }
    guard let first = owned.first else { return .direct }
    let present = fm.fileExists(atPath: bundleURL.path)
    // mise installs a cask with no Homebrew and leaves its own receipt beside the same
    // link. Homebrew does not know such an install, so a brew that is also there is never run on it.
    if owned.flatMap(\.owners).contains(where: { fm.fileExists(atPath: $0.appendingPathComponent(".mise-cask.toml").path) }) {
      guard present, let mise = miseCandidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else { return .miseMissing }
      return .mise(mise: mise)
    }
    guard present else { return .homebrewMissing }
    let brew = first.prefix.appendingPathComponent("bin/brew")
    return fm.isExecutableFile(atPath: brew.path) ? .homebrew(brew: brew) : .homebrewMissing
  }
}

extension InstallKind {
  /// The tool to run and the manager it is, for a cask install whose tool was found.
  public var cask: (tool: URL, manager: CaskInstaller.Manager)? {
    switch self {
    case .homebrew(let brew): return (brew, .homebrew)
    case .mise(let mise): return (mise, .mise)
    case .homebrewMissing, .miseMissing, .direct, .development: return nil
    }
  }
}

/// One version's section of `CHANGELOG.md`.
public struct ReleaseNote: Equatable, Identifiable {
  public let version: String
  public let date: String
  public fileprivate(set) var lines: [String]
  public var id: String { version }

  public init(version: String, date: String, lines: [String]) {
    self.version = version
    self.date = date
    self.lines = lines
  }
}

public enum ChangeLog {
  /// The sections newer than `running`, in file order, which is newest first.
  public static func notes(in markdown: String, newerThan running: String) -> [ReleaseNote] {
    var all: [ReleaseNote] = []
    var inSection = false
    // Not `separator: "\n"`, because "\r\n" is one Character and would never match.
    for raw in markdown.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("## ") {
        let note = heading(line)
        inSection = note != nil
        if let note { all.append(note) }
      } else if inSection, !line.isEmpty {
        all[all.count - 1].lines.append(line.hasPrefix("- ") ? String(line.dropFirst(2)) : line)
      }
    }
    return all.filter { Version.isNewer($0.version, than: running) }
  }

  private static func heading(_ line: String) -> ReleaseNote? {
    guard line.range(of: #"^## \d+(\.\d+)+ \(\S+\)$"#, options: .regularExpression) != nil else { return nil }
    let parts = line.split(separator: " ")
    return ReleaseNote(version: String(parts[1]), date: String(parts[2].dropFirst().dropLast()), lines: [])
  }
}

/// What a probe of the feed found. `changelog` is the whole `CHANGELOG.md`.
public struct FeedItem: Equatable {
  public let version: String
  public let changelog: String

  public init(version: String, changelog: String) {
    self.version = version
    self.changelog = changelog
  }
}

public struct UpdateOffer: Equatable {
  public let version: String
  public let notes: [ReleaseNote]

  public init(version: String, notes: [ReleaseNote]) {
    self.version = version
    self.notes = notes
  }
}

public enum InstallStage: Equatable, Sendable {
  case preparing, updatingHomebrew, upgrading, downloading(Double?), extracting, installing, relaunching
}

public struct UpdateProblem: Equatable {
  public enum Fallback: Equatable { case command(String), download(URL) }
  public let message: String
  public let detail: String?
  public let fallback: Fallback?

  public init(message: String, detail: String?, fallback: Fallback?) {
    self.message = message
    self.detail = detail
    self.fallback = fallback
  }
}

extension UpdateProblem: Error {
  /// Sparkle says the offered release is gone: the offer goes too.
  public static let noLongerOffered = UpdateProblem(message: "This update is no longer offered.", detail: nil, fallback: nil)
  public static let brewMissing = UpdateProblem(message: "Homebrew installed this app, but brew was not found. Download the update instead.", detail: nil, fallback: .download(UpdateController.releasePage))
  /// Not a download: mise keeps a fingerprint of the bundle it installed.
  public static let miseMissing = UpdateProblem(message: "mise installed this app, but mise was not found. Run the upgrade yourself.", detail: nil, fallback: .command(CaskInstaller.Manager.mise.command))
}

public enum UpdateState: Equatable {
  case idle, checking, upToDate(Date), available(UpdateOffer)
  case installing(UpdateOffer, InstallStage), failed(UpdateOffer?, UpdateProblem)

  public var offer: UpdateOffer? {
    switch self {
    case .available(let offer), .installing(let offer, _): return offer
    case .failed(let offer, _): return offer
    case .idle, .checking, .upToDate: return nil
    }
  }

  /// Killing brew or mise between removing and placing a bundle is the one way to
  /// lose the app. Sparkle's own terminate and the relaunch must still pass.
  public var blocksQuit: Bool {
    guard case .installing(_, let stage) = self else { return false }
    return stage == .updatingHomebrew || stage == .upgrading
  }
}

public protocol UpdateFeed: AnyObject {
  @MainActor func probe() async throws -> FeedItem?
}

public protocol Installer: AnyObject {
  /// Returns once the relaunch has started (brew, mise). Never returns on success when the installer's own quit ends the process (Sparkle). Throws UpdateProblem.
  @MainActor func install(_ offer: UpdateOffer, report: @escaping @MainActor (InstallStage) -> Void) async throws
}

/// Upgrades the formula and the cask through the manager that installed them,
/// then relaunches. The disk decides the outcome, not the exit code: brew can
/// exit 0 and leave the old version, or time out after the new one landed.
public final class CaskInstaller: Installer {
  /// Homebrew or mise: the runs that upgrade a cask install, and the words for a failure.
  public struct Manager: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
      let stage: InstallStage
      let arguments: [String]
    }

    public let name: String
    /// Run in order. A failure before the last step still lets the last one run.
    let steps: [Step]
    /// What About offers to copy when the upgrade fails.
    public let command: String
    public let environment: [String: String]
    /// The variable that names the folder casks install into, where the manager reads one.
    var appDirVariable: String? = nil

    /// For a run from this app. Opened from Finder it has none of the shell's variables, so
    /// an install outside /Applications made with one would be upgraded into the default folder.
    public func environment(forAppAt app: URL) -> [String: String] {
      guard let appDirVariable else { return environment }
      return environment.merging([appDirVariable: app.deletingLastPathComponent().path]) { _, here in here }
    }

    private static let formula = "jrmatherly/tap/claude-multipass"
    private static let cask = "jrmatherly/tap/claude-multipass-app"

    public static let homebrew = Manager(
      name: "Homebrew",
      // Any one stale tap fails `brew update`, so the upgrade still gets its chance.
      steps: [Step(stage: .updatingHomebrew, arguments: ["update", "--quiet"]), Step(stage: .upgrading, arguments: ["upgrade", formula, cask])],
      command: "brew update && brew upgrade \(formula) \(cask)",
      environment: [
        "HOMEBREW_NO_ASK": "1",
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
      ])

    /// One run: mise refreshes the tap itself, and skips a name its config does not declare.
    public static let mise: Manager = {
      let upgrade = ["bootstrap", "packages", "upgrade", "--yes", "brew:\(formula)", "brew-cask:\(cask)"]
      return Manager(name: "mise", steps: [Step(stage: .upgrading, arguments: upgrade)], command: "mise " + upgrade.joined(separator: " "), environment: [:], appDirVariable: "MISE_BREW_CASK_OPT_APPDIR")
    }()
  }

  /// Long, because the timeout kills the upgrade, and a kill mid-swap is the one way to lose the app.
  public static let timeout: TimeInterval = 1800

  private let runner: CommandRunner
  private let manager: Manager
  private let appURL: URL
  private let diskVersion: (URL) -> String?
  private let relaunch: (URL) -> Void
  private let log: (String) -> Void

  public init(
    runner: CommandRunner,
    manager: Manager,
    appURL: URL,
    diskVersion: @escaping (URL) -> String?,
    relaunch: @escaping (URL) -> Void,
    log: @escaping (String) -> Void = { NSLog("Claude Multipass: %@", $0) }
  ) {
    self.runner = runner
    self.manager = manager
    self.appURL = appURL
    self.diskVersion = diskVersion
    self.relaunch = relaunch
    self.log = log
  }

  @MainActor
  public func install(_ offer: UpdateOffer, report: @escaping @MainActor (InstallStage) -> Void) async throws {
    let landed = { (disk: String) in Version.components(disk) != nil && !Version.isNewer(offer.version, than: disk) }
    var failure: Error?
    var output = ""
    let fail = { (error: Error) in
      failure = error
      let said = Self.output(of: error)
      if !said.isEmpty { output = said }
    }
    // An upgrade from a terminal may have got here first.
    if diskVersion(appURL).map(landed) != true {
      for step in manager.steps {
        report(step.stage)
        do {
          let warnings = try await runner.runCapturing(step.arguments).stderr
          // The upgrade got past any earlier failure, so what it said explains the outcome.
          if step == manager.steps.last, !warnings.isEmpty {
            failure = nil
            output = warnings
          }
        } catch {
          fail(error)
        }
      }
    }
    let detail = output.isEmpty ? nil : output.split(separator: "\n", omittingEmptySubsequences: false).suffix(20).joined(separator: "\n")
    guard let disk = diskVersion(appURL) else {
      throw UpdateProblem(message: "The app could not be read from disk after \(manager.name) ran. Download it to reinstall.", detail: detail, fallback: .download(UpdateController.releasePage))
    }
    guard landed(disk) else {
      throw UpdateProblem(message: message(for: failure, detail: detail, disk: disk), detail: detail, fallback: .command(manager.command))
    }
    if let failure { log("\(manager.name) reported a failure, but \(disk) landed: \(failure)") }
    report(.relaunching)
    relaunch(appURL)
  }

  private func message(for failure: Error?, detail: String?, disk: String) -> String {
    switch failure {
    case nil:
      return "\(manager.name) finished, but the app on disk is still \(disk)."
    case CLIError.timedOut?:
      return "\(manager.name) did not finish in time. The app on disk is still \(disk)."
    default:
      let denied = detail?.contains("Operation not permitted") == true
      return "\(manager.name) could not update the app." + (denied ? " macOS may be blocking this. Check System Settings, Privacy and Security, App Management." : "")
    }
  }

  private static func output(of error: Error) -> String {
    switch error {
    case CLIError.timedOut:
      return ""
    case CLIError.failed(_, let stderr), CLIError.refused(let stderr):
      return stderr
    default:
      return error.localizedDescription
    }
  }
}

/// The one owner of `UpdateState`. Nothing installs but `install`, which only
/// the Update button calls.
@MainActor
public final class UpdateController: ObservableObject {
  @Published public private(set) var state: UpdateState = .idle
  @Published public private(set) var checkedAt: Date?

  public static let releasePage = URL(string: "https://github.com/jrmatherly/claude-multipass/releases/latest")!

  /// False for a development build: no update rows. True with a `startProblem`, so About can say updates are off.
  public var isAvailable: Bool { (feed != nil || startProblem != nil) && runningVersion != nil }
  /// Read from disk each time: a menu bar app runs for weeks, and brew or mise can appear under it.
  public var installKind: InstallKind { detect() }

  private let appState: AppState
  /// Why the feed did not start, on an install that should have one.
  public let startProblem: String?
  private let feed: UpdateFeed?
  private let detect: @MainActor () -> InstallKind
  private let installer: @MainActor (InstallKind) -> Installer?
  private let runningVersion: String?
  private let checkInterval: TimeInterval
  private let now: () -> Date
  private var schedule: Task<Void, Never>?
  /// The probe in flight. Sparkle runs one session at a time and ignores a check during one, so probes never overlap and an install waits for this.
  private var probing: Task<Void, Never>?

  public init(
    appState: AppState,
    feed: UpdateFeed?,
    startProblem: String? = nil,
    detect: @escaping @MainActor () -> InstallKind,
    installer: @escaping @MainActor (InstallKind) -> Installer?,
    runningVersion: String?,
    checkInterval: TimeInterval = 86_400,
    now: @escaping () -> Date = Date.init
  ) {
    self.appState = appState
    self.feed = feed
    self.startProblem = startProblem
    self.detect = detect
    self.installer = installer
    self.runningVersion = runningVersion
    self.checkInterval = checkInterval
    self.now = now
  }

  public func start() {
    stop()
    let interval = checkInterval
    schedule = Task { [weak self] in
      while !Task.isCancelled {
        if let self, self.appState.settings.updateChecksEnabled { await self.probe(manual: false) }
        // The continuous clock, because a closed lid must count toward a daily check.
        guard (try? await Task.sleep(for: .seconds(interval))) != nil, self != nil else { return }
      }
    }
  }

  public func stop() {
    schedule?.cancel()
    schedule = nil
  }

  public func check() async {
    await probe(manual: true)
  }

  /// A scheduled failure changes nothing on screen, since a laptop waking
  /// offline is not news. A manual one reports and keeps any offer.
  private func probe(manual: Bool) async {
    guard let feed, let runningVersion, probing == nil, appState.phase == .idle else { return }
    let shown = state.offer
    if manual { state = .checking }
    let work = Task {
      defer { probing = nil }
      do {
        let item = try await feed.probe()
        if let item, Version.components(item.version) == nil || Version.components(runningVersion) == nil {
          throw UpdateProblem(message: "The feed offered \(item.version), which this app cannot read", detail: nil, fallback: nil)
        }
        let checked = now()
        checkedAt = checked
        if let item, Version.isNewer(item.version, than: runningVersion) {
          state = .available(UpdateOffer(version: item.version, notes: ChangeLog.notes(in: item.changelog, newerThan: runningVersion)))
        } else {
          state = .upToDate(checked)
        }
      } catch {
        if manual { state = .failed(shown, Self.problem(from: error)) }
      }
    }
    probing = work
    await work.value
  }

  public func install() async {
    while let probe = probing { await probe.value }
    guard let offer = state.offer else { return }
    if case .installing = state { return }
    let kind = detect()
    guard let installer = installer(kind) else {
      state = .failed(offer, kind == .miseMissing ? .miseMissing : .brewMissing)
      return
    }
    let before = state
    // Before the lock, because beginUpdate can wait out a Keychain prompt and the UI must say so.
    state = .installing(offer, .preparing)
    guard await appState.beginUpdate() else {
      state = before
      return
    }
    do {
      try await installer.install(offer) { [weak self] stage in
        // A late stage must not undo .relaunching: blocksQuit would cancel the relaunch's terminate.
        guard let self, case .installing(_, let shown) = self.state, shown != .relaunching else { return }
        self.state = .installing(offer, stage)
      }
      // Only an installer that returns (brew) gets here; the phase stays held until the process exits.
      state = .installing(offer, .relaunching)
    } catch {
      let problem = Self.problem(from: error)
      state = .failed(problem == .noLongerOffered ? nil : offer, problem)
      await appState.endUpdate()
    }
  }

  private static func problem(from error: Error) -> UpdateProblem {
    error as? UpdateProblem ?? UpdateProblem(message: error.localizedDescription, detail: nil, fallback: nil)
  }
}
