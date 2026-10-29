import Foundation

public enum Phase: Equatable {
  case idle, switching(String), saving(String)
}

/// `failed` carries why the version probe got no version: a timeout, a
/// non-zero exit (a missing `jq`) or output that is not a version line.
public enum CLIStatus: Equatable {
  case unknown, ready(String), missing, tooOld, failed(String)
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
  /// When the shown usage figures were fetched; nil while there are none.
  @Published public private(set) var usageUpdatedAt: Date?
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
  private var reloadPending = false
  private var mainTask: Task<Void, Never>?
  private var snapshotTask: Task<Void, Never>?
  private var usageTask: Task<Void, Never>?
  /// The usage run in flight, so an action can wait for its Keychain prompt to close.
  private var usageFetch: Task<Void, Never>?
  @Published private var snapshotError: String?
  @Published private var usageError: String?

  public init(makeRunner: @escaping (AppSettings) -> CommandRunner?, store: SettingsStore, now: @escaping () -> Date = Date.init) {
    self.makeRunner = makeRunner
    self.store = store
    self.now = now
    settings = store.load()
  }

  public func apply(_ new: AppSettings) async {
    guard new != settings else { return }
    let old = settings
    settings = new
    store.save(new)
    if old.cliPathOverride != new.cliPathOverride {
      await relocate()
    }
    switch (old.usageEnabled, new.usageEnabled) {
    case (false, true):
      await refreshUsage()
      if settings.usageEnabled { startUsageTimer() }
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
    let status: CLIStatus
    do {
      let data = try await runner.run(["--version"])
      if let version = CLI.parseVersion(data) {
        status = CLI.isSupported(version) ? .ready(version) : .tooOld
      } else {
        status = .failed("unexpected CLI output: \(String(decoding: data.prefix(200), as: UTF8.self))")
      }
    } catch {
      status = .failed(describe(error))
    }
    guard generation == probeGeneration else { return }
    cliStatus = status
  }

  /// Skipped while a switch or save rewrites `config.json`; `act` loads the
  /// snapshot once it finishes.
  public func refresh() async {
    guard phase == .idle, !isRefreshing else { return }
    await loadSnapshot()
  }

  private func loadSnapshot() async {
    isRefreshing = true
    defer { isRefreshing = false }
    repeat {
      reloadPending = false
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
    } while reloadPending
  }

  /// Usage can be turned off while a fetch waits on a Keychain prompt (up to
  /// 10 minutes), so its result is dropped unless usage is still on.
  public func refreshUsage() async {
    guard settings.usageEnabled, phase == .idle, case .ready = cliStatus, let runner, !isRefreshingUsage else { return }
    isRefreshingUsage = true
    let fetch = Task { await fetchUsage(runner) }
    usageFetch = fetch
    await fetch.value
    usageFetch = nil
    isRefreshingUsage = false
  }

  private func fetchUsage(_ runner: CommandRunner) async {
    do {
      let data = try await runner.run(["usage", "--json"])
      guard settings.usageEnabled else { return }
      let report = try decode(UsageReport.self, data)
      usage = Dictionary(report.profiles.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
      usageUpdatedAt = now()
      usageError = nil
    } catch {
      guard settings.usageEnabled else { return }
      // Old figures would read as current; the error says why they are gone.
      usage = [:]
      usageUpdatedAt = nil
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
    // A usage run may be waiting on a Keychain prompt; a switch now would open a second one.
    await usageFetch?.value
    do {
      let output = try await runner.runCapturing(args)
      if !output.stderr.isEmpty { rowNote = RowNote(name: name, message: output.stderr) }
    } catch CLIError.refused(let message) {
      rowError = RowError(name: name, message: message, refused: true)
      return
    } catch {
      // A failure, unlike a refusal, may come after Desktop quit and relaunched.
      rowError = RowError(name: name, message: describe(error), refused: false)
    }
    // A load that started before the switch read the old login; run again after it.
    if isRefreshing { reloadPending = true } else { await loadSnapshot() }
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
