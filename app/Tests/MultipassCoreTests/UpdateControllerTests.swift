import Foundation
import MultipassCore
import Testing

private struct Offline: Error {}

/// Answers each probe from `results` in order; the last one repeats.
@MainActor
private final class FakeFeed: UpdateFeed {
  var results: [Result<FeedItem?, Error>]
  var gate: Gate?
  /// Runs once the gate opens, in the job that goes on to finish the probe.
  var afterGate: (@MainActor () -> Void)?
  private(set) var calls = 0

  init(_ results: [Result<FeedItem?, Error>]) {
    self.results = results
  }

  func probe() async throws -> FeedItem? {
    calls += 1
    let result = results.count > 1 ? results.removeFirst() : results[0]
    await gate?.wait()
    afterGate?()
    return try result.get()
  }
}

@MainActor
private final class FakeInstaller: Installer {
  var stage: InstallStage?
  var gate: Gate?
  var error: Error?
  private(set) var calls = 0
  private(set) var report: (@MainActor (InstallStage) -> Void)?

  func install(_ offer: UpdateOffer, report: @escaping @MainActor (InstallStage) -> Void) async throws {
    calls += 1
    self.report = report
    if let stage { report(stage) }
    await gate?.wait()
    if let error { throw error }
  }
}

/// For the scheduled loop, whose sleep a yield loop would not outlast.
@MainActor
private func untilSlept(_ condition: () -> Bool) async {
  for _ in 0..<500 {
    if condition() { break }
    try? await Task.sleep(nanoseconds: 2_000_000)
  }
  #expect(condition())
}

private let changelog = "## 0.11.0 (2026-11-02)\n\n- two\n\n## 0.10.0 (2026-11-01)\n\n- one\n\n## 0.9.0 (2026-10-31)\n\n- old\n"
private let newer = FeedItem(version: "0.11.0", changelog: changelog)
private let same = FeedItem(version: "0.9.0", changelog: changelog)
private let notes = [
  ReleaseNote(version: "0.11.0", date: "2026-11-02", lines: ["two"]),
  ReleaseNote(version: "0.10.0", date: "2026-11-01", lines: ["one"]),
]
private let offer = UpdateOffer(version: "0.11.0", notes: notes)
private let clock = Date(timeIntervalSince1970: 1_000_000)

private struct Fixture {
  let controller: UpdateController
  let appState: AppState
  let runner: FakeRunner
  let installer: FakeInstaller
}

@MainActor
private func fixture(
  feed: UpdateFeed?,
  usesInstaller: Bool = true,
  kind: InstallKind = .direct,
  checkInterval: TimeInterval = 86_400
) async -> Fixture {
  let suite = "net.matherly.claude-multipass.tests.update-controller"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let runner = FakeRunner()
  runner.answer("--version", "claude-multipass 0.3.0\n")
  runner.answer("switch", "")
  runner.answer("list", #"{"version":"0.2.0","signedIn":false,"desktopRunning":false,"current":null,"profiles":[]}"#)
  let appState = AppState(makeRunner: { _ in runner }, store: SettingsStore(defaults: defaults))
  await appState.relocate()
  let installer = FakeInstaller()
  let controller = UpdateController(
    appState: appState,
    feed: feed,
    detect: { kind },
    installer: { _ in usesInstaller ? installer : nil },
    runningVersion: "0.9.0",
    checkInterval: checkInterval,
    now: { clock }
  )
  return Fixture(controller: controller, appState: appState, runner: runner, installer: installer)
}

@Test @MainActor func aNewerFeedItemBecomesAnOfferWithFilteredNotes() async {
  let f = await fixture(feed: FakeFeed([.success(newer)]))
  await f.controller.check()
  #expect(f.controller.state == .available(offer))
  #expect(f.controller.checkedAt == clock)
}

@Test @MainActor func nothingNewerIsUpToDateAndStampsCheckedAt() async {
  let f = await fixture(feed: FakeFeed([.success(nil)]))
  await f.controller.check()
  #expect(f.controller.state == .upToDate(clock))
  #expect(f.controller.checkedAt == clock)
}

@Test @MainActor func anOlderFeedItemIsNoOffer() async {
  let f = await fixture(feed: FakeFeed([.success(FeedItem(version: "0.8.0", changelog: changelog))]))
  await f.controller.check()
  #expect(f.controller.state == .upToDate(clock))
}

@Test @MainActor func aFeedItemThatIsNotNewerIsUpToDate() async {
  let f = await fixture(feed: FakeFeed([.success(same)]))
  await f.controller.check()
  #expect(f.controller.state == .upToDate(clock))
}

@Test @MainActor func aRolledBackReleaseClearsTheOffer() async {
  let f = await fixture(feed: FakeFeed([.success(newer), .success(nil)]))
  await f.controller.check()
  #expect(f.controller.state.offer?.version == "0.11.0")
  await f.controller.check()
  #expect(f.controller.state == .upToDate(clock))
  #expect(f.controller.state.offer == nil)
}

@Test @MainActor func aScheduledFailureChangesNothing() async {
  let feed = FakeFeed([.success(newer), .failure(Offline())])
  let f = await fixture(feed: feed, checkInterval: 0.001)
  await f.controller.check()
  f.controller.start()
  await untilSlept { feed.calls >= 3 }
  f.controller.stop()
  #expect(f.controller.state == .available(offer))
}

@Test @MainActor func aScheduledFailureBeforeAnyOfferStaysIdle() async {
  let feed = FakeFeed([.failure(Offline())])
  let f = await fixture(feed: feed, checkInterval: 0.001)
  f.controller.start()
  await untilSlept { feed.calls >= 2 }
  f.controller.stop()
  #expect(f.controller.state == .idle)
  #expect(f.controller.checkedAt == nil)
}

@Test @MainActor func aManualFailureReportsAndKeepsTheOffer() async {
  let f = await fixture(feed: FakeFeed([.success(newer), .failure(UpdateProblem(message: "no network", detail: nil, fallback: nil))]))
  await f.controller.check()
  await f.controller.check()
  #expect(f.controller.state == .failed(offer, UpdateProblem(message: "no network", detail: nil, fallback: nil)))
  #expect(f.controller.state.offer == offer)
}

@Test @MainActor func aManualFailureWithNoOfferHasNone() async {
  let f = await fixture(feed: FakeFeed([.failure(Offline())]))
  await f.controller.check()
  guard case .failed(nil, let problem) = f.controller.state else {
    Issue.record("expected a failure with no offer, got \(f.controller.state)")
    return
  }
  #expect(!problem.message.isEmpty)
  #expect(f.controller.checkedAt == nil)
}

@Test @MainActor func aManualCheckShowsChecking() async {
  let gate = Gate()
  let feed = FakeFeed([.success(nil)])
  feed.gate = gate
  let f = await fixture(feed: feed)
  let check = Task { await f.controller.check() }
  await until { feed.calls == 1 }
  #expect(f.controller.state == .checking)
  gate.open()
  await check.value
}

@Test @MainActor func overlappingChecksProbeOnce() async {
  let gate = Gate()
  let feed = FakeFeed([.success(newer)])
  feed.gate = gate
  let f = await fixture(feed: feed)
  let first = Task { await f.controller.check() }
  await until { feed.calls == 1 }
  // In a task, so a second probe waiting on the gate fails the count and cannot hang the run.
  let second = Task { await f.controller.check() }
  for _ in 0..<100 { await Task.yield() }
  #expect(feed.calls == 1)
  gate.open()
  await first.value
  await second.value
  #expect(f.controller.state == .available(offer))
}

@Test @MainActor func aProbeIsSkippedWhileAnActionRuns() async {
  let feed = FakeFeed([.success(newer)])
  let f = await fixture(feed: feed)
  #expect(await f.appState.beginUpdate())
  await f.controller.check()
  #expect(feed.calls == 0)
}

@Test @MainActor func installWaitsForAProbeInFlight() async {
  let gate = Gate()
  let feed = FakeFeed([.success(newer)])
  let f = await fixture(feed: feed)
  await f.controller.check()
  feed.gate = gate
  let check = Task { await f.controller.check() }
  await until { feed.calls == 2 }
  let install = Task { await f.controller.install() }
  for _ in 0..<100 { await Task.yield() }
  #expect(f.installer.calls == 0)
  #expect(f.appState.phase == .idle)
  gate.open()
  await check.value
  await install.value
  #expect(f.installer.calls == 1)
  #expect(f.controller.state == .installing(offer, .relaunching))
}

@Test @MainActor func installWaitsForAScheduledProbeWithTheOfferShowing() async {
  let gate = Gate()
  let feed = FakeFeed([.success(newer)])
  let f = await fixture(feed: feed)
  await f.controller.check()
  feed.gate = gate
  f.controller.start()
  await until { feed.calls == 2 }
  #expect(f.controller.state == .available(offer))
  let install = Task { await f.controller.install() }
  for _ in 0..<100 { await Task.yield() }
  #expect(f.installer.calls == 0)
  #expect(f.appState.phase == .idle)
  gate.open()
  await install.value
  f.controller.stop()
  #expect(f.installer.calls == 1)
}

@Test @MainActor func installWaitsOutACheckThatStartsAsTheFirstEnds() async {
  let first = Gate()
  let second = Gate()
  let feed = FakeFeed([.success(newer)])
  let f = await fixture(feed: feed)
  await f.controller.check()
  feed.gate = first
  let firstCheck = Task { await f.controller.check() }
  await until { feed.calls == 2 }
  let install = Task { await f.controller.install() }
  for _ in 0..<100 { await Task.yield() }
  // This task is queued before the probe's job ends, so it runs ahead of the install's wake.
  feed.afterGate = {
    feed.afterGate = nil
    feed.gate = second
    Task { await f.controller.check() }
  }
  first.open()
  await firstCheck.value
  await until { feed.calls == 3 }
  for _ in 0..<100 { await Task.yield() }
  #expect(f.installer.calls == 0)
  #expect(f.appState.phase == .idle)
  second.open()
  await install.value
  #expect(f.installer.calls == 1)
  #expect(f.controller.state == .installing(offer, .relaunching))
}

@Test @MainActor func aRollbackSeenWhileWaitingCancelsTheInstall() async {
  let gate = Gate()
  let feed = FakeFeed([.success(newer), .success(nil)])
  let f = await fixture(feed: feed)
  await f.controller.check()
  feed.gate = gate
  f.controller.start()
  await until { feed.calls == 2 }
  let install = Task { await f.controller.install() }
  for _ in 0..<100 { await Task.yield() }
  gate.open()
  await install.value
  f.controller.stop()
  #expect(f.installer.calls == 0)
  #expect(f.controller.state == .upToDate(clock))
  #expect(f.appState.phase == .idle)
}

@Test @MainActor func aSecondClickInstallsOnce() async {
  let gate = Gate()
  let f = await fixture(feed: FakeFeed([.success(newer)]))
  f.installer.stage = .upgrading
  f.installer.gate = gate
  await f.controller.check()
  let first = Task { await f.controller.install() }
  await until { f.installer.calls == 1 }
  await f.controller.install()
  #expect(f.controller.state == .installing(offer, .upgrading))
  #expect(f.controller.state.blocksQuit)
  gate.open()
  await first.value
  #expect(f.installer.calls == 1)
}

@Test @MainActor func homebrewMissingReportsAndNeverInstalls() async {
  let f = await fixture(feed: FakeFeed([.success(newer)]), usesInstaller: false, kind: .homebrewMissing)
  await f.controller.check()
  await f.controller.install()
  guard case .failed(offer, let problem) = f.controller.state else {
    Issue.record("expected a failure keeping the offer, got \(f.controller.state)")
    return
  }
  guard case .download = problem.fallback else {
    Issue.record("expected a download fallback, got \(String(describing: problem.fallback))")
    return
  }
  #expect(f.installer.calls == 0)
  #expect(f.appState.phase == .idle)
}

@Test @MainActor func startNeverInstalls() async {
  let feed = FakeFeed([.success(newer)])
  let f = await fixture(feed: feed, checkInterval: 0.001)
  f.controller.start()
  await untilSlept { feed.calls >= 3 }
  f.controller.stop()
  #expect(f.installer.calls == 0)
  #expect(f.controller.state == .available(offer))
}

@Test @MainActor func theScheduleNeverProbesThroughAnInstall() async {
  let gate = Gate()
  let feed = FakeFeed([.success(newer), .success(nil)])
  let f = await fixture(feed: feed, checkInterval: 0.001)
  f.installer.gate = gate
  await f.controller.check()
  let install = Task { await f.controller.install() }
  await until { f.installer.calls == 1 }
  f.controller.start()
  try? await Task.sleep(nanoseconds: 30_000_000)
  #expect(feed.calls == 1)
  #expect(f.controller.state == .installing(offer, .preparing))
  gate.open()
  await install.value
  try? await Task.sleep(nanoseconds: 30_000_000)
  f.controller.stop()
  #expect(feed.calls == 1)
  #expect(f.controller.state == .installing(offer, .relaunching))
}

@Test @MainActor func aSecondStartLeavesOneTimer() async {
  let feed = FakeFeed([.success(nil)])
  let f = await fixture(feed: feed, checkInterval: 0.001)
  f.controller.start()
  await untilSlept { feed.calls >= 1 }
  f.controller.start()
  await untilSlept { feed.calls >= 3 }
  f.controller.stop()
  try? await Task.sleep(nanoseconds: 5_000_000)
  let settled = feed.calls
  try? await Task.sleep(nanoseconds: 30_000_000)
  #expect(feed.calls == settled)
}

@Test @MainActor func checksOffMeansStartDoesNotProbe() async {
  let feed = FakeFeed([.success(newer)])
  let f = await fixture(feed: feed, checkInterval: 0.001)
  var settings = f.appState.settings
  settings.updateChecksEnabled = false
  await f.appState.apply(settings)
  f.controller.start()
  try? await Task.sleep(nanoseconds: 30_000_000)
  #expect(feed.calls == 0)
  settings.updateChecksEnabled = true
  await f.appState.apply(settings)
  await untilSlept { feed.calls >= 1 }
  f.controller.stop()
}

@Test @MainActor func stopEndsTheSchedule() async {
  let feed = FakeFeed([.success(newer)])
  let f = await fixture(feed: feed, checkInterval: 0.001)
  f.controller.start()
  await untilSlept { feed.calls >= 1 }
  f.controller.stop()
  try? await Task.sleep(nanoseconds: 5_000_000)
  let settled = feed.calls
  try? await Task.sleep(nanoseconds: 30_000_000)
  #expect(feed.calls == settled)
}

@Test @MainActor func installHoldsThePhaseWhileRunning() async {
  let gate = Gate()
  let f = await fixture(feed: FakeFeed([.success(newer)]))
  f.installer.gate = gate
  await f.controller.check()
  let install = Task { await f.controller.install() }
  await until { f.installer.calls == 1 }
  #expect(f.appState.phase == .updating)
  #expect(f.controller.state == .installing(offer, .preparing))
  gate.open()
  await install.value
  // Held until the process exits: nothing may start in the app about to relaunch.
  #expect(f.appState.phase == .updating)
  #expect(f.controller.state == .installing(offer, .relaunching))
}

@Test @MainActor func preparingShowsWhileTheLockWaitsOutAUsageRun() async {
  let gate = Gate()
  let f = await fixture(feed: FakeFeed([.success(newer)]))
  await f.controller.check()
  f.runner.onCall = { args in if args[0] == "usage" { await gate.wait() } }
  var settings = f.appState.settings
  settings.usageEnabled = true
  let usage = Task { await f.appState.apply(settings) }
  await until { f.runner.calls.contains(["usage", "--json"]) }
  let install = Task { await f.controller.install() }
  await until { f.appState.phase == .updating }
  for _ in 0..<100 { await Task.yield() }
  #expect(f.installer.calls == 0)
  #expect(f.controller.state == .installing(offer, .preparing))
  gate.open()
  await install.value
  await usage.value
  f.appState.stop()
}

@Test @MainActor func aFailedInstallReleasesThePhase() async {
  let problem = UpdateProblem(message: "brew failed", detail: "tail", fallback: .command("brew upgrade"))
  let f = await fixture(feed: FakeFeed([.success(newer)]))
  f.installer.error = problem
  await f.controller.check()
  f.runner.clearCalls()
  await f.controller.install()
  #expect(f.controller.state == .failed(offer, problem))
  #expect(f.appState.phase == .idle)
  #expect(f.runner.calls.contains(["--version"]))
}

@Test @MainActor func aForeignErrorBecomesAProblem() async {
  let f = await fixture(feed: FakeFeed([.success(newer)]))
  f.installer.error = Offline()
  await f.controller.check()
  await f.controller.install()
  guard case .failed(offer, let problem) = f.controller.state else {
    Issue.record("expected a failure keeping the offer, got \(f.controller.state)")
    return
  }
  #expect(problem.message == Offline().localizedDescription)
}

@Test @MainActor func aFailedInstallCanBeRetried() async {
  let f = await fixture(feed: FakeFeed([.success(newer)]))
  f.installer.error = Offline()
  await f.controller.check()
  await f.controller.install()
  f.installer.error = nil
  await f.controller.install()
  #expect(f.installer.calls == 2)
  #expect(f.controller.state == .installing(offer, .relaunching))
}

@Test @MainActor func installDuringASwitchDoesNothing() async {
  let gate = Gate()
  let f = await fixture(feed: FakeFeed([.success(newer)]))
  await f.controller.check()
  f.runner.onCall = { args in if args[0] == "switch" { await gate.wait() } }
  f.runner.clearCalls()
  let switching = Task { await f.appState.switchTo("alpha") }
  await until { f.runner.calls.count == 1 }
  await f.controller.install()
  #expect(f.controller.state == .available(offer))
  #expect(f.installer.calls == 0)
  #expect(f.appState.phase == .switching("alpha"))
  gate.open()
  await switching.value
}

@Test @MainActor func stagesReachTheState() async {
  let gate = Gate()
  let f = await fixture(feed: FakeFeed([.success(newer)]))
  f.installer.stage = .upgrading
  f.installer.gate = gate
  await f.controller.check()
  let install = Task { await f.controller.install() }
  await until { f.installer.calls == 1 }
  #expect(f.controller.state == .installing(offer, .upgrading))
  gate.open()
  await install.value
}

@Test @MainActor func aStageAfterAFailureLeavesTheFailure() async {
  let problem = UpdateProblem(message: "brew failed", detail: nil, fallback: nil)
  let f = await fixture(feed: FakeFeed([.success(newer)]))
  f.installer.error = problem
  await f.controller.check()
  await f.controller.install()
  f.installer.report?(.upgrading)
  #expect(f.controller.state == .failed(offer, problem))
}

@Test @MainActor func aStageAfterTheInstallerReturnedStaysRelaunching() async {
  let f = await fixture(feed: FakeFeed([.success(newer)]))
  await f.controller.check()
  await f.controller.install()
  f.installer.report?(.upgrading)
  #expect(f.controller.state == .installing(offer, .relaunching))
  #expect(!f.controller.state.blocksQuit)
}

@Test @MainActor func aDevelopmentBuildHasNoUpdates() async {
  let f = await fixture(feed: nil)
  #expect(!f.controller.isAvailable)
  f.controller.start()
  await f.controller.check()
  await f.controller.install()
  f.controller.stop()
  #expect(f.controller.state == .idle)
  #expect(f.controller.checkedAt == nil)
}

@Test @MainActor func anInstalledBuildHasUpdatesAndReadsItsKindFromDisk() async {
  let f = await fixture(feed: FakeFeed([.success(nil)]), kind: .homebrewMissing)
  #expect(f.controller.isAvailable)
  #expect(f.controller.installKind == .homebrewMissing)
}

@Test func onlyBrewStagesBlockQuit() {
  #expect(UpdateState.installing(offer, .upgrading).blocksQuit)
  #expect(UpdateState.installing(offer, .updatingHomebrew).blocksQuit)
  #expect(!UpdateState.installing(offer, .preparing).blocksQuit)
  #expect(!UpdateState.installing(offer, .downloading(0.4)).blocksQuit)
  #expect(!UpdateState.installing(offer, .extracting).blocksQuit)
  #expect(!UpdateState.installing(offer, .installing).blocksQuit)
  #expect(!UpdateState.installing(offer, .relaunching).blocksQuit)
  #expect(!UpdateState.available(offer).blocksQuit)
  #expect(!UpdateState.idle.blocksQuit)
}

@Test func onlyOfferStatesCarryAnOffer() {
  let problem = UpdateProblem(message: "m", detail: nil, fallback: nil)
  #expect(UpdateState.available(offer).offer == offer)
  #expect(UpdateState.installing(offer, .preparing).offer == offer)
  #expect(UpdateState.failed(offer, problem).offer == offer)
  #expect(UpdateState.failed(nil, problem).offer == nil)
  #expect(UpdateState.checking.offer == nil)
  #expect(UpdateState.upToDate(clock).offer == nil)
}
