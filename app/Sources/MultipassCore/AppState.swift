import Foundation

public enum Phase: Equatable {
  case idle, switching(String), saving(String)
}

public enum CLIStatus: Equatable {
  case unknown, ready(String), missing, tooOld
}

/// The one row-level failure on show: `refused` picks "Switch anyway" over Retry.
public struct RowError: Equatable {
  public let name: String
  public let message: String
  public let refused: Bool

  public init(name: String, message: String, refused: Bool) {
    self.name = name
    self.message = message
    self.refused = refused
  }
}

/// A warning the tool printed while a switch or save succeeded (for example
/// "switched Desktop only"), shown under the row until the next action.
public struct RowNote: Equatable {
  public let name: String
  public let message: String

  public init(name: String, message: String) {
    self.name = name
    self.message = message
  }
}

/// Everything the views read. The CLI is reached only through `CommandRunner`;
/// `switch` and `save` run only from `switchTo` and `saveCurrent`, which the
/// confirm buttons call. Settings change only through `apply`, so the work a
/// change triggers is awaited by callers and tests alike.
@MainActor
public final class AppState: ObservableObject {
  @Published public private(set) var snapshot: Snapshot?
  @Published public private(set) var usage: [String: UsageEntry] = [:]
  @Published public private(set) var phase: Phase = .idle
  @Published public private(set) var isRefreshing = false
  @Published public private(set) var isRefreshingUsage = false
  /// A snapshot error, else a usage error; each clears only on its own success.
  public var lastError: String? { snapshotError ?? usageError }
  @Published public private(set) var rowError: RowError?
  @Published public private(set) var rowNote: RowNote?
  @Published public private(set) var cliStatus: CLIStatus = .unknown
  @Published public private(set) var cliLocation: String?
  @Published public private(set) var settings: AppSettings

  public var currentUsage: UsageEntry? { usage[snapshot?.current ?? "(signed in)"] }
  public var isPollingUsage: Bool { usageTask != nil }

  private let makeRunner: (AppSettings) -> CommandRunner?
  private let store: SettingsStore
  private let now: () -> Date
  private var runner: CommandRunner?
  private var probeGeneration = 0
  private var mainTask: Task<Void, Never>?
  private var snapshotTask: Task<Void, Never>?
  private var usageTask: Task<Void, Never>?
  @Published private var snapshotError: String?
  @Published private var usageError: String?

  public init(makeRunner: @escaping (AppSettings) -> CommandRunner?, store: SettingsStore, now: @escaping () -> Date = Date.init) {
    self.makeRunner = makeRunner
    self.store = store
    self.now = now
    settings = store.load()
  }

  public func apply(_ new: AppSettings) async {
    let old = settings
    settings = new
    store.save(new)
    if old.cliPathOverride != new.cliPathOverride {
      await relocate()
    }
    switch (old.usageEnabled, new.usageEnabled) {
    case (false, true):
      await refreshUsage()
      startUsageTimer()
    case (true, false):
      usageTask?.cancel()
      usageTask = nil
      usageError = nil
    case (true, true) where old.usageIntervalMinutes != new.usageIntervalMinutes:
      startUsageTimer()
    default:
      break
    }
  }

  /// Overlapping probes (the settings path field applies per keystroke) can
  /// finish out of order; only the latest one may set the status.
  public func relocate() async {
    probeGeneration += 1
    let generation = probeGeneration
    runner = makeRunner(settings)
    cliLocation = runner?.location
    guard let runner else {
      cliStatus = .missing
      return
    }
    var status = CLIStatus.tooOld
    if let data = try? await runner.run(["--version"]), let version = CLI.parseVersion(data), CLI.isSupported(version) {
      status = .ready(version)
    }
    guard generation == probeGeneration else { return }
    cliStatus = status
  }

  public func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    // Not ready: re-probe first, so a brew upgrade or a path fix is picked
    // up without a relaunch, then carry on when it answered.
    if case .ready = cliStatus {} else { await relocate() }
    guard case .ready = cliStatus, let runner else { return }
    do {
      let data = try await runner.run(["list", "--json"])
      snapshot = try decode(Snapshot.self, data)
      snapshotError = nil
    } catch {
      snapshotError = describe(error)
    }
  }

  public func refreshUsage() async {
    guard settings.usageEnabled, case .ready = cliStatus, let runner, !isRefreshingUsage else { return }
    isRefreshingUsage = true
    defer { isRefreshingUsage = false }
    do {
      let data = try await runner.run(["usage", "--json"])
      let report = try decode(UsageReport.self, data)
      usage = Dictionary(report.profiles.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
      usageError = nil
    } catch {
      // Old figures would read as current; the error says why they are gone.
      usage = [:]
      usageError = describe(error)
    }
  }

  public func refreshAll() async {
    await refresh()
    await refreshUsage()
  }

  public func switchTo(_ name: String, force: Bool = false) async {
    await act(name, phase: .switching(name), args: ["switch", name] + (force ? ["--force"] : []))
  }

  public func saveCurrent(as name: String) async {
    await act(name, phase: .saving(name), args: ["save", name])
  }

  public func dismissRowError() {
    rowError = nil
    rowNote = nil
  }

  public func start() {
    stop()
    mainTask = Task { [weak self] in
      guard let self else { return }
      await relocate()
      await refreshAll()
      startSnapshotTimer()
      if settings.usageEnabled { startUsageTimer() }
    }
  }

  public func stop() {
    mainTask?.cancel()
    snapshotTask?.cancel()
    usageTask?.cancel()
    mainTask = nil
    snapshotTask = nil
    usageTask = nil
  }

  private func act(_ name: String, phase: Phase, args: [String]) async {
    guard self.phase == .idle, let runner else { return }
    rowError = nil
    rowNote = nil
    self.phase = phase
    defer { self.phase = .idle }
    do {
      let output = try await runner.runCapturing(args)
      if !output.stderr.isEmpty { rowNote = RowNote(name: name, message: output.stderr) }
    } catch CLIError.refused(let message) {
      rowError = RowError(name: name, message: message, refused: true)
      return
    } catch {
      rowError = RowError(name: name, message: describe(error), refused: false)
      return
    }
    await refresh()
  }

  private func startSnapshotTimer() {
    snapshotTask?.cancel()
    snapshotTask = timer(every: AppSettings.snapshotInterval) { await $0.refresh() }
  }

  private func startUsageTimer() {
    usageTask?.cancel()
    usageTask = timer(every: TimeInterval(max(settings.usageIntervalMinutes, 5) * 60)) { await $0.refreshUsage() }
  }

  private func timer(every interval: TimeInterval, _ tick: @escaping @MainActor (AppState) async -> Void) -> Task<Void, Never> {
    Task { [weak self] in
      while !Task.isCancelled {
        guard (try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))) != nil, let self else { return }
        await tick(self)
      }
    }
  }

  private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    do {
      return try MultipassJSON.decoder.decode(type, from: data)
    } catch {
      throw CLIError.badJSON(String(decoding: data.prefix(200), as: UTF8.self))
    }
  }

  private func describe(_ error: Error) -> String {
    switch error {
    case CLIError.refused(let message), CLIError.failed(_, let message):
      return message.isEmpty ? "the CLI failed without a message" : message
    case CLIError.badJSON(let text):
      return "unexpected CLI output: \(text)"
    case CLIError.timedOut:
      return "the CLI did not finish in time"
    default:
      return String(describing: error)
    }
  }
}
