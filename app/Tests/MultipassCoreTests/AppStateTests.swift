import Foundation
import MultipassCore
import Testing

/// Scripted CLI: responses keyed by the first argument, every call recorded.
final class FakeRunner: CommandRunner, @unchecked Sendable {
  private let lock = NSLock()
  private var _calls: [[String]] = []
  private var responses: [String: Result<Data, CLIError>] = [:]
  /// stderr to hand back beside a successful response, keyed the same way.
  var onStderr: [String: String] = [:]
  var onCall: (@Sendable ([String]) async -> Void)?
  var location: String?

  var calls: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return _calls
  }

  func clearCalls() {
    lock.lock()
    _calls = []
    lock.unlock()
  }

  func answer(_ command: String, _ json: String) {
    lock.lock()
    responses[command] = .success(Data(json.utf8))
    lock.unlock()
  }

  func fail(_ command: String, _ error: CLIError) {
    lock.lock()
    responses[command] = .failure(error)
    lock.unlock()
  }

  private func record(_ args: [String]) -> Result<Data, CLIError>? {
    lock.lock()
    defer { lock.unlock() }
    _calls.append(args)
    return responses[args[0]]
  }

  func runCapturing(_ args: [String]) async throws -> CommandOutput {
    let response = record(args)
    await onCall?(args)
    guard let response else { throw CLIError.failed(status: 1, stderr: "unscripted \(args)") }
    return CommandOutput(stdout: try response.get(), stderr: onStderr[args[0]] ?? "")
  }
}

/// Holds a scripted call until `open`, so a test can act while it is in flight.
final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { c in
      lock.lock()
      if isOpen { lock.unlock(); c.resume(); return }
      waiters.append(c)
      lock.unlock()
    }
  }

  func open() {
    lock.lock()
    isOpen = true
    let ready = waiters
    waiters = []
    lock.unlock()
    ready.forEach { $0.resume() }
  }
}

@MainActor
func until(_ condition: () -> Bool) async {
  for _ in 0..<10_000 {
    if condition() { break }
    await Task.yield()
  }
  #expect(condition())
}

private let snapshotAlpha = #"{"version":"0.2.0","signedIn":true,"desktopRunning":false,"current":"alpha","profiles":[{"name":"alpha","account":"a","savedAt":"2026-01-01T00:00:00Z","sessions":1},{"name":"beta","account":"b","savedAt":"2026-01-01T00:00:00Z","sessions":4}]}"#
private let snapshotBeta = #"{"version":"0.2.0","signedIn":true,"desktopRunning":false,"current":"beta","profiles":[{"name":"alpha","account":"a","savedAt":"2026-01-01T00:00:00Z","sessions":1},{"name":"beta","account":"b","savedAt":"2026-01-01T00:00:00Z","sessions":4}]}"#
private let snapshotUnsaved = #"{"version":"0.2.0","signedIn":true,"desktopRunning":false,"current":null,"profiles":[{"name":"alpha","account":"a","savedAt":"2026-01-01T00:00:00Z","sessions":1}]}"#
private let usageBoth = #"{"profiles":[{"name":"alpha","fiveHour":{"utilization":10}},{"name":"beta","fiveHour":{"utilization":42.6,"resetsAt":"2026-10-23T19:45:00Z"},"sevenDay":{"utilization":18}}]}"#

/// One suite per test target, emptied before each AppState is made, so a run
/// leaves one plist in ~/Library/Preferences instead of one per test. AppState
/// reads the store only in its init, on the main actor with no await between
/// this clear and that read, so tests sharing the suite still start empty.
@MainActor
private func scratchDefaults() -> UserDefaults {
  let suite = "net.matherly.claude-multipass.tests"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@MainActor
private func makeState(_ runner: FakeRunner?, makeRunner: ((AppSettings) -> CommandRunner?)? = nil, now: @escaping () -> Date = Date.init) -> AppState {
  let store = SettingsStore(defaults: scratchDefaults())
  return AppState(makeRunner: makeRunner ?? { _ in runner }, store: store, now: now)
}

@MainActor
private func readyRunner() -> FakeRunner {
  let r = FakeRunner()
  r.answer("--version", "claude-multipass 0.3.0\n")
  r.answer("list", snapshotBeta)
  r.answer("switch", "")
  r.answer("save", "")
  r.answer("usage", usageBoth)
  return r
}

final class TestClock {
  var now = Date(timeIntervalSince1970: 1_000_000)
}

@MainActor
private func readyState(clock: TestClock = TestClock()) async -> (AppState, FakeRunner) {
  let r = readyRunner()
  let s = makeState(r, now: { clock.now })
  await s.relocate()
  await s.refresh()
  r.clearCalls()
  return (s, r)
}

@MainActor
private func enabledUsage(_ s: AppState) -> AppSettings {
  var settings = s.settings
  settings.usageEnabled = true
  return settings
}

@Test @MainActor func relocateReadyWhenVersionSupported() async {
  let s = makeState(readyRunner())
  #expect(s.cliStatus == .unknown)
  await s.relocate()
  #expect(s.cliStatus == .ready("0.3.0"))
}

@Test @MainActor func relocateExposesTheRunnerLocation() async {
  let r = readyRunner()
  r.location = "/opt/homebrew/bin/claude-multipass"
  let s = makeState(r)
  #expect(s.cliLocation == nil)
  await s.relocate()
  #expect(s.cliLocation == "/opt/homebrew/bin/claude-multipass")
  let none = makeState(nil)
  await none.relocate()
  #expect(none.cliLocation == nil)
}

@Test @MainActor func relocateFailedWhenVersionProbeFails() async {
  // A non-zero exit, a timeout or stray output is not an old version; "brew upgrade" would not fix it.
  let r = FakeRunner()
  r.fail("--version", .failed(status: 2, stderr: "bogus line"))
  let s = makeState(r)
  await s.relocate()
  #expect(s.cliStatus == .failed("bogus line"))
  r.fail("--version", .timedOut)
  await s.relocate()
  #expect(s.cliStatus == .failed("the CLI did not finish in time"))
  r.answer("--version", "Usage: ...\n")
  await s.relocate()
  #expect(s.cliStatus == .failed("unexpected CLI output: Usage: ...\n"))
}

@Test @MainActor func relocateTooOldWhenVersionIsOld() async {
  let r = FakeRunner()
  r.answer("--version", "claude-multipass 0.1.0\n")
  let s = makeState(r)
  await s.relocate()
  #expect(s.cliStatus == .tooOld)
}

@Test @MainActor func relocateMissingWhenNoRunner() async {
  let s = makeState(nil)
  await s.relocate()
  #expect(s.cliStatus == .missing)
  await s.refresh()
  #expect(s.snapshot == nil)
  #expect(s.cliStatus == .missing)
}

@Test @MainActor func refreshReprobesWhileNotReady() async {
  let r = FakeRunner()
  r.fail("--version", .failed(status: 2, stderr: "usage"))
  let s = makeState(r)
  await s.relocate()
  #expect(s.cliStatus == .failed("usage"))
  r.answer("--version", "claude-multipass 0.3.0\n")
  r.answer("list", snapshotBeta)
  r.clearCalls()
  await s.refresh()
  #expect(s.cliStatus == .ready("0.3.0"))
  #expect(r.calls == [["--version"], ["list", "--json"]])
  #expect(s.snapshot?.current == "beta")
}

@Test @MainActor func overlappingRelocatesKeepTheLastRequested() async {
  // The settings path field applies per keystroke; an earlier probe that
  // finishes last must not overwrite the status of the path typed later.
  let slow = FakeRunner()
  slow.answer("--version", "claude-multipass 0.3.0\n")
  slow.onCall = { _ in try? await Task.sleep(nanoseconds: 200_000_000) }
  let s = makeState(nil) { settings in settings.cliPathOverride == "/slow" ? slow : nil }
  var slowPath = s.settings
  slowPath.cliPathOverride = "/slow"
  var missingPath = s.settings
  missingPath.cliPathOverride = "/missing"
  let first = slowPath
  let second = missingPath
  async let a: Void = s.apply(first)
  try? await Task.sleep(nanoseconds: 20_000_000)
  async let b: Void = s.apply(second)
  _ = await (a, b)
  #expect(s.cliStatus == .missing)
  #expect(s.settings.cliPathOverride == "/missing")
}

@Test @MainActor func applyPathOverrideRelocates() async {
  let r = readyRunner()
  final class Seen: @unchecked Sendable { var overrides: [String?] = [] }
  let seen = Seen()
  let s = makeState(nil) { settings in
    seen.overrides.append(settings.cliPathOverride)
    return r
  }
  await s.relocate()
  var settings = s.settings
  settings.cliPathOverride = "/x/claude-multipass"
  await s.apply(settings)
  #expect(seen.overrides == [nil, "/x/claude-multipass"])
  #expect(s.settings.cliPathOverride == "/x/claude-multipass")
  settings.usageIntervalMinutes = 30
  await s.apply(settings)
  #expect(seen.overrides.count == 2)
}

@Test @MainActor func refreshStoresSnapshot() async {
  let (s, _) = await readyState()
  #expect(s.snapshot?.current == "beta")
  #expect(s.snapshot?.profiles.count == 2)
  #expect(s.lastError == nil)
  #expect(s.isRefreshing == false)
}

@Test @MainActor func refreshFailureKeepsOldSnapshot() async {
  let (s, r) = await readyState()
  r.fail("list", .failed(status: 1, stderr: "No config.json"))
  await s.refresh()
  #expect(s.snapshot?.current == "beta")
  #expect(s.lastError == "No config.json")
  r.answer("list", snapshotUnsaved)
  await s.refresh()
  #expect(s.lastError == nil)
  #expect(s.snapshot?.current == nil)
}

@Test @MainActor func refreshRejectsBadJSON() async {
  let (s, r) = await readyState()
  r.answer("list", "not json")
  await s.refresh()
  #expect(s.snapshot?.current == "beta")
  #expect(s.lastError != nil)
}

@Test @MainActor func switchSuccessRefreshes() async {
  let (s, r) = await readyState()
  final class Seen: @unchecked Sendable { var phaseDuringRefresh: Phase? }
  let seen = Seen()
  r.onCall = { args in
    guard args == ["list", "--json"] else { return }
    await MainActor.run { seen.phaseDuringRefresh = s.phase }
  }
  await s.switchTo("alpha")
  #expect(r.calls == [["switch", "alpha"], ["list", "--json"]])
  #expect(seen.phaseDuringRefresh == .switching("alpha"))
  #expect(s.phase == .idle)
  #expect(s.rowError == nil)
}

@Test @MainActor func switchWarningBecomesRowNote() async {
  let (s, r) = await readyState()
  r.onStderr["switch"] = "no CLI login saved for alpha; switched Desktop only"
  await s.switchTo("alpha")
  #expect(s.rowNote == RowNote(name: "alpha", message: "no CLI login saved for alpha; switched Desktop only"))
  #expect(s.rowError == nil)
  #expect(r.calls == [["switch", "alpha"], ["list", "--json"]])
}

@Test @MainActor func nextActionClearsRowNote() async {
  let (s, r) = await readyState()
  r.onStderr["switch"] = "switched Desktop only"
  await s.switchTo("alpha")
  #expect(s.rowNote != nil)
  r.onStderr = [:]
  await s.saveCurrent(as: "work")
  #expect(s.rowNote == nil)
  r.onStderr["switch"] = "switched Desktop only"
  await s.switchTo("alpha")
  s.dismissRowError()
  #expect(s.rowNote == nil)
}

@Test @MainActor func switchRefusedSetsRowError() async {
  let (s, r) = await readyState()
  r.fail("switch", .refused("The signed-in account isn't saved"))
  await s.switchTo("alpha")
  #expect(s.rowError == RowError(name: "alpha", message: "The signed-in account isn't saved", refused: true))
  #expect(s.phase == .idle)
  #expect(r.calls == [["switch", "alpha"]])
}

@Test @MainActor func switchFailureSetsRetryError() async {
  let (s, r) = await readyState()
  r.fail("switch", .failed(status: 1, stderr: "Claude did not quit"))
  await s.switchTo("alpha")
  #expect(s.rowError == RowError(name: "alpha", message: "Claude did not quit", refused: false))
  r.fail("switch", .timedOut)
  await s.switchTo("alpha")
  #expect(s.rowError?.refused == false)
  #expect(s.rowError?.message.isEmpty == false)
  #expect(r.calls.last == ["list", "--json"])
}

@Test @MainActor func switchAnywayPassesForce() async {
  let (s, r) = await readyState()
  r.fail("switch", .refused("unsaved"))
  await s.switchTo("alpha")
  #expect(s.rowError?.refused == true)
  r.answer("switch", "")
  r.clearCalls()
  await s.switchTo("alpha", force: true)
  #expect(r.calls[0] == ["switch", "alpha", "--force"])
  #expect(s.rowError == nil)
}

@Test @MainActor func dismissClearsRowError() async {
  let (s, r) = await readyState()
  r.fail("switch", .refused("unsaved"))
  await s.switchTo("alpha")
  #expect(s.rowError != nil)
  s.dismissRowError()
  #expect(s.rowError == nil)
}

@Test @MainActor func saveCurrentRunsSave() async {
  let (s, r) = await readyState()
  await s.saveCurrent(as: "work")
  #expect(r.calls == [["save", "work"], ["list", "--json"]])
  #expect(s.phase == .idle)
  r.fail("save", .refused("work already holds account"))
  await s.saveCurrent(as: "work")
  #expect(s.rowError == RowError(name: "work", message: "work already holds account", refused: true))
}

@Test @MainActor func usageSkippedWhenDisabled() async {
  let (s, r) = await readyState()
  await s.refreshUsage()
  #expect(r.calls == [])
  #expect(s.usage.isEmpty)
}

@Test @MainActor func applyEnablingUsageFetchesOnce() async {
  let (s, r) = await readyState()
  await s.apply(enabledUsage(s))
  #expect(r.calls == [["usage", "--json"]])
  #expect(s.usage["beta"]?.fiveHour?.utilization == 42.6)
  #expect(s.isPollingUsage)
}

@Test @MainActor func applyStripStyleDoesNotFetchUsage() async {
  let (s, r) = await readyState()
  await s.apply(enabledUsage(s))
  r.clearCalls()
  var settings = s.settings
  settings.stripStyle = .ringOnly
  await s.apply(settings)
  settings.usageIntervalMinutes = 60
  await s.apply(settings)
  #expect(r.calls == [])
  #expect(s.isPollingUsage)
  #expect(s.settings.stripStyle == .ringOnly)
}

@Test @MainActor func applyDisablingUsageStopsTimer() async {
  let (s, _) = await readyState()
  await s.apply(enabledUsage(s))
  #expect(s.isPollingUsage)
  await s.apply(AppSettings())
  #expect(!s.isPollingUsage)
  await s.refreshUsage()
  #expect(s.usage.isEmpty == false)
}

@Test @MainActor func refreshAllFetchesUsageWhenEnabled() async {
  let clock = TestClock()
  let (s, r) = await readyState(clock: clock)
  await s.refreshAll()
  #expect(r.calls == [["list", "--json"]])
  await s.apply(enabledUsage(s))
  r.clearCalls()
  clock.now += AppSettings.usageRefreshFloor
  await s.refreshAll()
  #expect(r.calls == [["list", "--json"], ["usage", "--json"]])
}

@Test @MainActor func currentUsageUsesSignedInKey() async {
  let clock = TestClock()
  let (s, r) = await readyState(clock: clock)
  #expect(s.currentUsage == nil)
  await s.apply(enabledUsage(s))
  #expect(s.currentUsage?.name == "beta")
  r.answer("list", snapshotUnsaved)
  r.answer("usage", #"{"profiles":[{"name":"alpha","fiveHour":{"utilization":10}},{"name":"(signed in)","fiveHour":{"utilization":77}}]}"#)
  clock.now += AppSettings.usageRefreshFloor
  await s.refreshAll()
  #expect(s.currentUsage?.name == "(signed in)")
  #expect(s.currentUsage?.fiveHour?.utilization == 77)
}

@Test @MainActor func usageErrorEntryKept() async {
  let (s, r) = await readyState()
  r.answer("usage", #"{"profiles":[{"name":"alpha","error":"token expired, sign in and re-save"},{"name":"beta","fiveHour":{"utilization":42.6}}]}"#)
  await s.apply(enabledUsage(s))
  #expect(s.usage["alpha"]?.error == "token expired, sign in and re-save")
  #expect(s.usage["alpha"]?.fiveHour == nil)
  #expect(s.usage["beta"]?.fiveHour?.utilization == 42.6)
  #expect(s.lastError == nil)
}

@Test @MainActor func usageFailureDoesNotRetry() async {
  let (s, r) = await readyState()
  r.fail("usage", .timedOut)
  await s.apply(enabledUsage(s))
  #expect(r.calls.filter { $0 == ["usage", "--json"] }.count == 1)
  #expect(s.lastError != nil)
  #expect(s.usage.isEmpty)
  #expect(s.isRefreshingUsage == false)
}

@Test @MainActor func usageFailureClearsOldFiguresAndOutlivesASnapshot() async {
  let (s, r) = await readyState()
  await s.apply(enabledUsage(s))
  #expect(s.usage["beta"] != nil)
  r.fail("usage", .failed(status: 1, stderr: "keychain locked"))
  await s.refreshUsage()
  #expect(s.usage.isEmpty)
  await s.refresh()
  #expect(s.lastError == "keychain locked")
  r.answer("usage", usageBoth)
  await s.refreshUsage()
  #expect(s.lastError == nil)
  #expect(s.usage["beta"] != nil)
}

@Test @MainActor func snapshotErrorWinsAndUsageSuccessKeepsIt() async {
  let (s, r) = await readyState()
  await s.apply(enabledUsage(s))
  r.fail("list", .failed(status: 1, stderr: "No config.json"))
  await s.refresh()
  await s.refreshUsage()
  #expect(s.lastError == "No config.json")
}

@Test @MainActor func disablingUsageClearsItsError() async {
  let (s, r) = await readyState()
  r.fail("usage", .timedOut)
  await s.apply(enabledUsage(s))
  #expect(s.lastError != nil)
  await s.apply(AppSettings())
  #expect(s.lastError == nil)
}

@Test @MainActor func refreshDoesNotChangePhase() async {
  let (s, r) = await readyState()
  final class Seen: @unchecked Sendable { var phases: [Phase] = []; var refreshing: [Bool] = [] }
  let seen = Seen()
  r.onCall = { _ in
    await MainActor.run {
      seen.phases.append(s.phase)
      seen.refreshing.append(s.isRefreshing)
    }
  }
  await s.refresh()
  #expect(seen.phases == [.idle])
  #expect(seen.refreshing == [true])
  #expect(s.isRefreshing == false)
}

@Test @MainActor func stopCancelsTimers() async {
  let (s, _) = await readyState()
  await s.apply(enabledUsage(s))
  s.stop()
  #expect(!s.isPollingUsage)
}

@Test @MainActor func usageTurnedOffDuringFirstFetchShowsNothing() async {
  for failure in [nil, CLIError.timedOut] {
    let (s, r) = await readyState()
    if let failure { r.fail("usage", failure) }
    let gate = Gate()
    r.onCall = { args in if args[0] == "usage" { await gate.wait() } }
    let turningOn = Task { await s.apply(enabledUsage(s)) }
    await until { r.calls.count == 1 }
    var off = s.settings
    off.usageEnabled = false
    await s.apply(off)
    gate.open()
    await turningOn.value
    #expect(s.usage.isEmpty)
    #expect(s.lastError == nil)
    #expect(!s.isPollingUsage)
  }
}

@Test @MainActor func overlappingUsageRefreshesRunOnce() async {
  let (s, r) = await readyState()
  await s.apply(enabledUsage(s))
  r.clearCalls()
  let gate = Gate()
  r.onCall = { _ in await gate.wait() }
  let first = Task { await s.refreshUsage() }
  await until { r.calls.count == 1 }
  await s.refreshUsage()
  gate.open()
  await first.value
  #expect(r.calls == [["usage", "--json"]])
}

@Test @MainActor func refreshesWaitOutASwitch() async {
  let (s, r) = await readyState()
  await s.apply(enabledUsage(s))
  r.clearCalls()
  let gate = Gate()
  r.onCall = { args in if args[0] == "switch" { await gate.wait() } }
  let switching = Task { await s.switchTo("alpha") }
  await until { s.phase == .switching("alpha") && r.calls.count == 1 }
  await s.refreshAll()
  #expect(r.calls == [["switch", "alpha"]])
  gate.open()
  await switching.value
  #expect(r.calls == [["switch", "alpha"], ["list", "--json"]])
}

@Test @MainActor func switchIsBlockedDuringAnUpdate() async {
  let (s, r) = await readyState()
  #expect(await s.beginUpdate())
  #expect(s.phase == .updating)
  await s.switchTo("alpha")
  await s.saveCurrent(as: "gamma")
  await s.refreshAll()
  #expect(r.calls.isEmpty)
  await s.endUpdate()
  #expect(s.phase == .idle)
}

@Test @MainActor func updateCannotStartDuringASwitch() async {
  let (s, r) = await readyState()
  let gate = Gate()
  r.onCall = { args in if args[0] == "switch" { await gate.wait() } }
  let switching = Task { await s.switchTo("alpha") }
  await until { r.calls.count == 1 }
  #expect(await s.beginUpdate() == false)
  #expect(s.phase == .switching("alpha"))
  gate.open()
  await switching.value
}

@Test @MainActor func updateCannotStartTwice() async {
  let (s, _) = await readyState()
  #expect(await s.beginUpdate())
  #expect(await s.beginUpdate() == false)
}

@Test @MainActor func updateWaitsOutAUsageFetch() async {
  let (s, r) = await readyState()
  await s.apply(enabledUsage(s))
  r.clearCalls()
  let gate = Gate()
  r.onCall = { args in if args[0] == "usage" { await gate.wait() } }
  let usage = Task { await s.refreshUsage() }
  await until { r.calls.count == 1 }
  var began = false
  let update = Task {
    let ok = await s.beginUpdate()
    began = true
    return ok
  }
  await until { s.phase == .updating }
  for _ in 0..<100 { await Task.yield() }
  #expect(!began)
  gate.open()
  #expect(await update.value)
  await usage.value
}

@Test @MainActor func endUpdateProbesTheToolAgain() async {
  let (s, r) = await readyState()
  #expect(await s.beginUpdate())
  r.answer("--version", "claude-multipass 0.4.0\n")
  await s.endUpdate()
  #expect(r.calls.contains(["--version"]))
  #expect(s.cliStatus == .ready("0.4.0"))
}

@Test @MainActor func switchWaitsOutAUsageRun() async {
  // usage can sit on a Keychain prompt; a switch started then would open a
  // second one, so it runs once the usage run has finished.
  let (s, r) = await readyState()
  await s.apply(enabledUsage(s))
  r.clearCalls()
  let gate = Gate()
  r.onCall = { args in if args[0] == "usage" { await gate.wait() } }
  let fetching = Task { await s.refreshUsage() }
  await until { r.calls.count == 1 }
  let switching = Task { await s.switchTo("alpha") }
  await until { s.phase == .switching("alpha") }
  for _ in 0..<100 { await Task.yield() }
  #expect(r.calls == [["usage", "--json"]])
  gate.open()
  await fetching.value
  await switching.value
  #expect(r.calls == [["usage", "--json"], ["switch", "alpha"], ["list", "--json"]])
  #expect(s.phase == .idle)
}

@Test @MainActor func refreshInFlightWhenASwitchFinishesRunsAgain() async {
  let (s, r) = await readyState()
  let gate = Gate()
  r.onCall = { args in if args[0] == "list" { await gate.wait() } }
  let tick = Task { await s.refresh() }
  await until { r.calls.count == 1 }
  r.answer("list", snapshotAlpha)
  await s.switchTo("alpha")
  gate.open()
  await tick.value
  #expect(s.snapshot?.current == "alpha")
  #expect(r.calls == [["list", "--json"], ["switch", "alpha"], ["list", "--json"]])
}

@Test @MainActor func usageUpdatedAtFollowsTheLastSuccess() async {
  let r = readyRunner()
  let fetched = Date(timeIntervalSince1970: 1_000_000)
  let s = makeState(r, now: { fetched })
  await s.relocate()
  await s.refresh()
  #expect(s.usageUpdatedAt == nil)
  await s.apply(enabledUsage(s))
  #expect(s.usageUpdatedAt == fetched)
  r.fail("usage", .timedOut)
  await s.refreshUsage()
  #expect(s.usageUpdatedAt == nil)
}

@Test @MainActor func launchRefreshAllRunsUsageWithNoEarlierAttempt() async {
  // start() goes through refreshAll; before the CLI is probed, enabling usage
  // makes no attempt, so the floor has no stamp to measure from.
  let r = readyRunner()
  let s = makeState(r)
  await s.apply(enabledUsage(s))
  #expect(r.calls == [])
  await s.relocate()
  await s.refreshAll()
  #expect(r.calls.last == ["usage", "--json"])
}

@Test @MainActor func usageRefreshWithinTheFloorIsSkipped() async {
  let clock = TestClock()
  let (s, r) = await readyState(clock: clock)
  r.fail("usage", .timedOut)
  await s.apply(enabledUsage(s))
  r.answer("usage", usageBoth)
  r.clearCalls()
  clock.now += 29
  await s.refreshAll()
  #expect(r.calls == [["list", "--json"]])
  #expect(s.usage.isEmpty)
  clock.now += 1
  await s.refreshAll()
  #expect(r.calls == [["list", "--json"], ["list", "--json"], ["usage", "--json"]])
  #expect(s.usage["beta"] != nil)
}
