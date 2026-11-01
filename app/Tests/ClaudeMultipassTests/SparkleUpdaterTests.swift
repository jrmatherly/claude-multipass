import Foundation
import MultipassCore
import Testing

@testable import ClaudeMultipass

private let changelog = "## 0.11.0 (2026-11-02)"
private let offer = UpdateOffer(version: "0.11.0", notes: [ReleaseNote(version: "0.11.0", date: "2026-11-02", lines: [])])
private let item = FeedItem(version: "0.11.0", changelog: changelog)

private func sparkleError(_ code: Int) -> NSError {
  NSError(domain: "SUSparkleErrorDomain", code: code, userInfo: [NSLocalizedDescriptionKey: "raw \(code)"])
}

/// A Sparkle object built by class name and typed by inference, because only
/// SparkleUpdater.swift may import Sparkle, and some of these have no public init.
private func sparkle<T>(_ name: String, _ fields: [String: Any] = [:]) -> T {
  let object = class_createInstance(NSClassFromString(name), 0) as! NSObject
  object.setValuesForKeys(fields)
  return object as! T
}

/// A missing resume must fail its test in seconds, not hang the job to its timeout.
@MainActor
func soon(_ done: () -> Bool) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(5)
  while clock.now < deadline {
    if done() { return true }
    try? await Task.sleep(for: .milliseconds(2))
  }
  return false
}

/// A driver with its Sparkle calls replaced, driven the way Sparkle's callbacks drive it.
@MainActor
private final class Harness {
  var canCheck = true
  var probes = 0
  var installs = 0
  var stages: [InstallStage] = []
  var returned = false
  var problem: UpdateProblem?
  var probeResult: Result<FeedItem?, UpdateProblem>?
  lazy var updater = SparkleUpdater(
    calls: .init(
      canCheck: { [unowned self] in self.canCheck },
      probe: { [unowned self] in self.probes += 1 },
      install: { [unowned self] in self.installs += 1 }))

  func startInstall() async {
    Task { @MainActor in
      do {
        try await updater.install(offer) { self.stages.append($0) }
        returned = true
      } catch {
        problem = error as? UpdateProblem
      }
    }
    #expect(await soon { installs > 0 })
  }

  func startProbe() async {
    let before = probes
    probeResult = nil
    Task { @MainActor in
      do {
        probeResult = .success(try await updater.probe())
      } catch {
        probeResult = .failure(error as! UpdateProblem)
      }
    }
    #expect(await soon { probes > before })
  }

  func thrown() async -> UpdateProblem? {
    _ = await soon { problem != nil }
    return problem
  }

  func probed() async -> Result<FeedItem?, UpdateProblem>? {
    _ = await soon { probeResult != nil }
    return probeResult
  }

  func find() {
    updater.updater(sparkle("SPUUpdater"), didFindValidUpdate: sparkle("SUAppcastItem", ["displayVersionString": item.version, "itemDescription": item.changelog]))
  }

  func finishCycle(error: Error? = nil) {
    updater.updater(sparkle("SPUUpdater"), didFinishUpdateCycleFor: .updates, error: error)
  }

  func installingUpdate() {
    updater.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
  }
}

@Test @MainActor func aFoundItemIsTheProbesAnswer() async {
  let h = Harness()
  await h.startProbe()
  h.find()
  h.finishCycle()
  #expect(await h.probed() == .success(item))
}

@Test @MainActor func aLaterProbeThatFindsNothingForgetsTheEarlierItem() async {
  let h = Harness()
  await h.startProbe()
  h.find()
  h.finishCycle()
  #expect(await h.probed() == .success(item))
  await h.startProbe()
  h.finishCycle()
  #expect(await h.probed() == .success(nil))
}

// Sparkle reports "nothing newer" as an error, and a rollback arrives this way.
@Test @MainActor func nothingNewerIsNilAndNotAnError() async {
  let h = Harness()
  await h.startProbe()
  h.finishCycle(error: sparkleError(1001))
  #expect(await h.probed() == .success(nil))
}

@Test @MainActor func aReadOnlyVolumeSaysToMoveTheApp() async throws {
  let h = Harness()
  await h.startProbe()
  h.finishCycle(error: sparkleError(1003))
  guard case .failure(let problem) = await h.probed() else { throw CancellationError() }
  #expect(problem.message == "Move Claude Multipass to Applications to update.")
}

private func chain(_ errors: NSError...) -> NSError {
  errors.reversed().reduce(nil as NSError?) { under, error in
    var info = error.userInfo
    info[NSUnderlyingErrorKey] = under
    return NSError(domain: error.domain, code: error.code, userInfo: info)
  }!
}

private func described(_ domain: String, _ code: Int, _ text: String) -> NSError {
  NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: text])
}

private let generic = [
  described("SUSparkleErrorDomain", 2001, "An error occurred in retrieving update information. Please try again later."),
  described("SUSparkleErrorDomain", 2001, "An error occurred while downloading the update. Please try again later."),
]

// The chains Sparkle 2.10.1 gave a real SPUUpdater, measured against a local server on 2026-11-01.
@Test @MainActor func aFeedThatIsNotThereSaysNotFoundAndNotConnection() async throws {
  let h = Harness()
  await h.startProbe()
  let notFound = described("SUSparkleErrorDomain", 2001, "A network error occurred while downloading https://example.com/appcast.xml. not found (404)")
  h.finishCycle(error: chain(generic[0], generic[1], notFound))
  guard case .failure(let problem) = await h.probed() else { throw CancellationError() }
  #expect(problem.message == "The update could not be downloaded.")
  #expect(problem.detail == notFound.localizedDescription)
}

@Test @MainActor func aNetworkCauseKeepsTheConnectionAdvice() async throws {
  let h = Harness()
  await h.startProbe()
  let url = described(NSURLErrorDomain, -1004, "Could not connect to the server.")
  h.finishCycle(error: chain(generic[0], generic[1], described("SUSparkleErrorDomain", 2001, "Failed to download temporary data."), url, described("kCFErrorDomainCFNetwork", -1004, "noise")))
  guard case .failure(let problem) = await h.probed() else { throw CancellationError() }
  #expect(problem.message == "The update could not be reached. Check your connection.")
  #expect(problem.detail == url.localizedDescription)
}

@Test @MainActor func anInstallFailureCarriesItsCauseToo() async {
  let h = Harness()
  await h.startInstall()
  h.updater.showUpdaterError(chain(generic[1], described("SUSparkleErrorDomain", 2001, "not found (404)")), acknowledgement: {})
  let problem = await h.thrown()
  #expect(problem?.detail == "not found (404)")
  #expect(problem?.fallback == .download(UpdateController.releasePage))
}

@Test @MainActor func aSecondEndOfAProbeIsHarmless() async {
  let h = Harness()
  await h.startProbe()
  h.finishCycle()
  h.finishCycle(error: sparkleError(2001))
  #expect(await h.probed() == .success(nil))
}

@Test @MainActor func aSessionInProgressFailsRatherThanHangs() async {
  let h = Harness()
  h.canCheck = false
  await #expect(throws: UpdateProblem.self) { try await h.updater.probe() }
  await #expect(throws: UpdateProblem.self) { try await h.updater.install(offer) { _ in } }
  #expect(h.probes == 0 && h.installs == 0)
}

@Test @MainActor func stagesFollowTheDriverAndInstallNeverReturns() async {
  let h = Harness()
  await h.startInstall()
  h.updater.showDownloadInitiated(cancellation: {})
  h.updater.showDownloadDidReceiveExpectedContentLength(100)
  h.updater.showDownloadDidReceiveData(ofLength: 40)
  h.updater.showDownloadDidStartExtractingUpdate()
  var replied = false
  h.updater.showReady(toInstallAndRelaunch: { replied = $0 == .install })
  #expect(replied)
  h.installingUpdate()
  try? await Task.sleep(for: .milliseconds(50))
  #expect(h.stages == [.downloading(nil), .downloading(0), .downloading(0.4), .extracting, .installing, .relaunching])
  #expect(!h.returned)
  #expect(h.problem == nil)
}

// A double resume of a checked continuation traps, so reaching the end proves once.
@Test @MainActor func aLateErrorThrowsAndNothingReportsAfterIt() async {
  let h = Harness()
  await h.startInstall()
  h.installingUpdate()
  var acknowledged = 0
  h.updater.showUpdaterError(sparkleError(4005), acknowledgement: { acknowledged += 1 })
  let problem = await h.thrown()
  #expect(problem?.message == "raw 4005")
  #expect(problem?.fallback == .download(UpdateController.releasePage))
  let settled = h.stages
  h.updater.showDownloadDidStartExtractingUpdate()
  h.installingUpdate()
  h.updater.showUpdaterError(sparkleError(4005), acknowledgement: { acknowledged += 1 })
  h.updater.dismissUpdateInstallation()
  #expect(acknowledged == 2)
  #expect(h.stages == settled)
  #expect(!h.returned)
}

@Test @MainActor func aDismissAfterInstallingThrows() async {
  let h = Harness()
  await h.startInstall()
  h.installingUpdate()
  h.updater.dismissUpdateInstallation()
  #expect(await h.thrown()?.fallback == .download(UpdateController.releasePage))
  #expect(!h.returned)
}

// A failure that arrives after Sparkle's quit begins must still reach the user, with the phase released.
@Test @MainActor func aLateFailureReachesTheUserWithTheAppIdle() async {
  let suite = "net.matherly.claude-multipass.tests.sparkle-updater"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let appState = AppState(makeRunner: { _ in nil }, store: SettingsStore(defaults: defaults))
  let h = Harness()
  let updater = h.updater
  let controller = UpdateController(appState: appState, feed: updater, detect: { .direct }, installer: { _ in updater }, runningVersion: "0.9.0")

  Task { await controller.check() }
  #expect(await soon { h.probes > 0 })
  h.find()
  h.finishCycle()
  #expect(await soon { controller.state == .available(offer) })

  Task { await controller.install() }
  #expect(await soon { h.installs > 0 })
  h.installingUpdate()
  #expect(await soon { controller.state == .installing(offer, .relaunching) })
  #expect(appState.phase == .updating)
  #expect(!controller.state.blocksQuit)

  h.updater.showUpdaterError(sparkleError(4005), acknowledgement: {})
  let failed = UpdateState.failed(offer, UpdateProblem(message: "raw 4005", detail: nil, fallback: .download(UpdateController.releasePage)))
  #expect(await soon { controller.state == failed })
  #expect(await soon { appState.phase == .idle })
}

@Test @MainActor func aSecondCallWhileOneWaitsFailsAndLeavesTheFirst() async {
  let h = Harness()
  await h.startProbe()
  await #expect(throws: UpdateProblem.self) { try await h.updater.probe() }
  h.finishCycle()
  #expect(await h.probed() == .success(nil))
  await h.startInstall()
  await #expect(throws: UpdateProblem.self) { try await h.updater.install(offer) { _ in } }
  h.updater.showUpdaterError(sparkleError(4005), acknowledgement: {})
  #expect(await h.thrown()?.message == "raw 4005")
}

@Test @MainActor func anUpdaterErrorThrowsWithTheDownloadLinkAndStopsStages() async {
  let h = Harness()
  await h.startInstall()
  var acknowledged = false
  h.updater.showUpdaterError(sparkleError(4005), acknowledgement: { acknowledged = true })
  h.updater.dismissUpdateInstallation()
  let problem = await h.thrown()
  #expect(acknowledged)
  #expect(problem?.message == "raw 4005")
  #expect(problem?.fallback == .download(UpdateController.releasePage))
  h.updater.showDownloadDidStartExtractingUpdate()
  #expect(h.stages.isEmpty)
}

@Test @MainActor func aReleaseGoneAtTheClickSaysSo() async {
  let h = Harness()
  await h.startInstall()
  var acknowledged = false
  h.updater.showUpdateNotFoundWithError(sparkleError(1001), acknowledgement: { acknowledged = true })
  let problem = await h.thrown()
  #expect(acknowledged)
  #expect(problem == .noLongerOffered)
}

// Sparkle may tear the session down from inside the acknowledgement, and the real problem must win.
@Test @MainActor func aTeardownInsideTheAcknowledgementDoesNotHideTheProblem() async {
  let gone = Harness()
  await gone.startInstall()
  gone.updater.showUpdateNotFoundWithError(sparkleError(1001), acknowledgement: { gone.updater.dismissUpdateInstallation() })
  #expect(await gone.thrown() == .noLongerOffered)
  let failed = Harness()
  await failed.startInstall()
  failed.updater.showUpdaterError(sparkleError(4005), acknowledgement: { failed.updater.dismissUpdateInstallation() })
  #expect(await failed.thrown()?.message == "raw 4005")
}

// The phase must never stay held by a session Sparkle ended without an error.
@Test @MainActor func aDismissedInstallReleases() async {
  let h = Harness()
  await h.startInstall()
  h.updater.dismissUpdateInstallation()
  #expect(await h.thrown() != nil)
}

// Nothing installs without a click: a stray session is answered no.
@Test @MainActor func withNoInstallWaitingTheReadyReplyIsDismiss() {
  let h = Harness()
  var dismissed = false
  h.updater.showReady(toInstallAndRelaunch: { dismissed = $0 == .dismiss })
  #expect(dismissed)
}

@Test @MainActor func aFoundUpdateIsAnsweredByWhetherAnInstallWaits() async {
  let h = Harness()
  var replies = 0
  var dismissed = false
  h.updater.showUpdateFound(with: sparkle("SUAppcastItem"), state: sparkle("SPUUserUpdateState")) {
    replies += 1
    dismissed = $0 == .dismiss
  }
  #expect(replies == 1 && dismissed)
  await h.startInstall()
  var installs = false
  h.updater.showUpdateFound(with: sparkle("SUAppcastItem"), state: sparkle("SPUUserUpdateState")) {
    replies += 1
    installs = $0 == .install
  }
  #expect(replies == 2 && installs)
}

// Automatic checks stay ours, behind the toggle, and no profile leaves the Mac.
@Test @MainActor func thePermissionRequestTurnsOnNothing() {
  let h = Harness()
  var replied = false
  h.updater.show(.init(systemProfile: [])) {
    replied = true
    #expect(!$0.automaticUpdateChecks)
    #expect(!$0.sendSystemProfile)
  }
  #expect(replied)
}
