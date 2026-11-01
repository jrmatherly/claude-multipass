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
  case homebrew(brew: URL), homebrewMissing, direct, development

  /// Stat only, never a subprocess. A second copy of the app beside a cask
  /// install is `direct`, since only the cask's own symlink proves brew owns it.
  public static func detect(
    bundleURL: URL,
    version: String?,
    prefixes: [URL] = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")]
  ) -> InstallKind {
    guard version != nil, bundleURL.pathExtension == "app" else { return .development }
    let fm = FileManager.default
    let bundle = bundleURL.resolvingSymlinksInPath().path
    for prefix in prefixes {
      let cask = prefix.appendingPathComponent("Caskroom/claude-multipass-app")
      let versions = (try? fm.contentsOfDirectory(at: cask, includingPropertiesForKeys: nil)) ?? []
      guard versions.contains(where: { $0.appendingPathComponent("Claude Multipass.app").resolvingSymlinksInPath().path == bundle }) else { continue }
      let brew = prefix.appendingPathComponent("bin/brew")
      return fm.isExecutableFile(atPath: brew.path) ? .homebrew(brew: brew) : .homebrewMissing
    }
    return .direct
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

public enum InstallStage: Equatable {
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

extension UpdateProblem: Error {}

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

  /// Killing brew between removing and placing a bundle is the one way to
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
  /// Returning means the process is about to relaunch, and an installer may instead
  /// never return while the process exits. Throws UpdateProblem.
  @MainActor func install(_ offer: UpdateOffer, report: @escaping @MainActor (InstallStage) -> Void) async throws
}

/// Upgrades the formula and the cask, then relaunches. The disk decides the
/// outcome, not brew's exit code: brew can exit 0 and leave the old version, or
/// time out after the new one landed.
public final class BrewInstaller: Installer {
  public static let environment = [
    "HOMEBREW_NO_ASK": "1",
    "HOMEBREW_NO_AUTO_UPDATE": "1",
    "HOMEBREW_NO_INSTALL_CLEANUP": "1",
    "HOMEBREW_NO_ENV_HINTS": "1",
  ]
  /// Long, because the timeout kills brew, and a kill mid-swap is the one way to lose the app.
  public static let timeout: TimeInterval = 1800
  private static let packages = ["jrmatherly/tap/claude-multipass", "jrmatherly/tap/claude-multipass-app"]
  public static let command = "brew update && brew upgrade " + packages.joined(separator: " ")

  private let runner: CommandRunner
  private let appURL: URL
  private let diskVersion: (URL) -> String?
  private let relaunch: (URL) -> Void

  public init(runner: CommandRunner, appURL: URL, diskVersion: @escaping (URL) -> String?, relaunch: @escaping (URL) -> Void) {
    self.runner = runner
    self.appURL = appURL
    self.diskVersion = diskVersion
    self.relaunch = relaunch
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
    // A terminal `brew upgrade` may have got here first.
    if diskVersion(appURL).map(landed) != true {
      report(.updatingHomebrew)
      // Any one stale tap fails `brew update`, so the upgrade still gets its chance.
      do { _ = try await runner.run(["update", "--quiet"]) } catch { fail(error) }
      report(.upgrading)
      do {
        let warnings = try await runner.runCapturing(["upgrade"] + Self.packages).stderr
        // The upgrade got past any update failure, so what it said explains the outcome.
        if !warnings.isEmpty {
          failure = nil
          output = warnings
        }
      } catch {
        fail(error)
      }
    }
    let detail = output.isEmpty ? nil : output.split(separator: "\n", omittingEmptySubsequences: false).suffix(20).joined(separator: "\n")
    guard let disk = diskVersion(appURL) else {
      throw UpdateProblem(message: "The app could not be read from disk after Homebrew ran. Download it to reinstall.", detail: detail, fallback: .download(UpdateController.releasePage))
    }
    guard landed(disk) else {
      throw UpdateProblem(message: Self.message(for: failure, detail: detail, disk: disk), detail: detail, fallback: .command(Self.command))
    }
    report(.relaunching)
    relaunch(appURL)
  }

  private static func message(for failure: Error?, detail: String?, disk: String) -> String {
    switch failure {
    case nil:
      return "Homebrew finished, but the app on disk is still \(disk)."
    case CLIError.timedOut?:
      return "Homebrew did not finish in time. The app on disk is still \(disk)."
    default:
      let denied = detail?.contains("Operation not permitted") == true
      return "Homebrew could not update the app." + (denied ? " macOS may be blocking this. Check System Settings, Privacy and Security, App Management." : "")
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

  /// False for a development build: no update rows.
  public var isAvailable: Bool { feed != nil && runningVersion != nil }
  /// Read from disk each time: a menu bar app runs for weeks, and brew can appear under it.
  public var installKind: InstallKind { detect() }

  private let appState: AppState
  private let feed: UpdateFeed?
  private let detect: @MainActor () -> InstallKind
  private let installer: @MainActor (InstallKind) -> Installer?
  private let runningVersion: String?
  private let checkInterval: TimeInterval
  private let now: () -> Date
  private var schedule: Task<Void, Never>?
  /// The probe in flight. Sparkle has one continuation, and it ignores a check
  /// during a session, so probes never overlap and an install waits for this.
  private var probing: Task<Void, Never>?

  public init(
    appState: AppState,
    feed: UpdateFeed?,
    detect: @escaping @MainActor () -> InstallKind,
    installer: @escaping @MainActor (InstallKind) -> Installer?,
    runningVersion: String?,
    checkInterval: TimeInterval = 86_400,
    now: @escaping () -> Date = Date.init
  ) {
    self.appState = appState
    self.feed = feed
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
    guard let installer = installer(detect()) else {
      state = .failed(offer, UpdateProblem(message: "Homebrew installed this app, but brew was not found. Download the update instead.", detail: nil, fallback: .download(Self.releasePage)))
      return
    }
    // Before the lock, because beginUpdate can wait out a Keychain prompt and the UI must say so.
    state = .installing(offer, .preparing)
    guard await appState.beginUpdate() else {
      state = .available(offer)
      return
    }
    do {
      try await installer.install(offer) { [weak self] stage in
        // A late stage must not undo .relaunching: blocksQuit would cancel the relaunch's terminate.
        guard let self, case .installing(_, let shown) = self.state, shown != .relaunching else { return }
        self.state = .installing(offer, stage)
      }
      // The phase stays held until the process exits.
      state = .installing(offer, .relaunching)
    } catch {
      state = .failed(offer, Self.problem(from: error))
      await appState.endUpdate()
    }
  }

  private static func problem(from error: Error) -> UpdateProblem {
    error as? UpdateProblem ?? UpdateProblem(message: error.localizedDescription, detail: nil, fallback: nil)
  }
}
