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

private let snapshotBeta = #"{"version":"0.2.0","signedIn":true,"desktopRunning":false,"current":"beta","profiles":[{"name":"alpha","account":"a","savedAt":"2026-01-01T00:00:00Z","sessions":1},{"name":"beta","account":"b","savedAt":"2026-01-01T00:00:00Z","sessions":4}]}"#
private let snapshotUnsaved = #"{"version":"0.2.0","signedIn":true,"desktopRunning":false,"current":null,"profiles":[{"name":"alpha","account":"a","savedAt":"2026-01-01T00:00:00Z","sessions":1}]}"#
private let usageBoth = #"{"profiles":[{"name":"alpha","fiveHour":{"utilization":10}},{"name":"beta","fiveHour":{"utilization":42.6,"resetsAt":"2026-10-23T19:45:00Z"},"sevenDay":{"utilization":18}}]}"#

@MainActor
private func makeState(_ runner: FakeRunner?, makeRunner: ((AppSettings) -> CommandRunner?)? = nil) -> AppState {
  let suite = "net.matherly.claude-multipass.tests.\(UUID().uuidString)"
  let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
  return AppState(makeRunner: makeRunner ?? { _ in runner }, store: store)
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

@MainActor
private func readyState() async -> (AppState, FakeRunner) {
  let r = readyRunner()
  let s = makeState(r)
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

@Test @MainActor func relocateTooOldWhenVersionFails() async {
  let r = FakeRunner()
  r.fail("--version", .failed(status: 2, stderr: "claude-multipass\nUsage: ..."))
  let s = makeState(r)
  await s.relocate()
  #expect(s.cliStatus == .tooOld)
  r.answer("--version", "claude-multipass 0.1.0\n")
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
  #expect(s.cliStatus == .tooOld)
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

@Test @MainActor func applyModuleToggleDoesNotFetchUsage() async {
  let (s, r) = await readyState()
  await s.apply(enabledUsage(s))
  r.clearCalls()
  var settings = s.settings
  settings.enabledModules = [.account, .weeklyBar]
  await s.apply(settings)
  settings.usageIntervalMinutes = 60
  await s.apply(settings)
  #expect(r.calls == [])
  #expect(s.isPollingUsage)
  #expect(s.settings.enabledModules == [.account, .weeklyBar])
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
  let (s, r) = await readyState()
  await s.refreshAll()
  #expect(r.calls == [["list", "--json"]])
  await s.apply(enabledUsage(s))
  r.clearCalls()
  await s.refreshAll()
  #expect(r.calls == [["list", "--json"], ["usage", "--json"]])
}

@Test @MainActor func currentUsageUsesSignedInKey() async {
  let (s, r) = await readyState()
  #expect(s.currentUsage == nil)
  await s.apply(enabledUsage(s))
  #expect(s.currentUsage?.name == "beta")
  r.answer("list", snapshotUnsaved)
  r.answer("usage", #"{"profiles":[{"name":"alpha","fiveHour":{"utilization":10}},{"name":"(signed in)","fiveHour":{"utilization":77}}]}"#)
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
