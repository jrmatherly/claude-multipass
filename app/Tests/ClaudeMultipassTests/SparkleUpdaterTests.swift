import Foundation
import MultipassCore
import Testing

@testable import ClaudeMultipass

private let offer = UpdateOffer(version: "0.11.0", notes: [])
private let item = FeedItem(version: "0.11.0", changelog: "## 0.11.0 (2026-11-02)")

private func sparkleError(_ code: Int) -> NSError {
  NSError(domain: "SUSparkleErrorDomain", code: code, userInfo: [NSLocalizedDescriptionKey: "raw \(code)"])
}

/// A driver with its Sparkle calls replaced, driven the way Sparkle's callbacks drive it.
@MainActor
private final class Harness {
  var canCheck = true
  var probes = 0
  var installs = 0
  var quits = 0
  var stages: [InstallStage] = []
  var returned = false
  var problem: UpdateProblem?
  lazy var updater = SparkleUpdater(
    calls: .init(
      canCheck: { [unowned self] in self.canCheck },
      probe: { [unowned self] in self.probes += 1 },
      install: { [unowned self] in self.installs += 1 },
      quit: { [unowned self] in self.quits += 1 }))

  func startInstall() async -> Task<Void, Never> {
    let task = Task { @MainActor in
      do {
        try await updater.install(offer) { [unowned self] in self.stages.append($0) }
        returned = true
      } catch {
        problem = error as? UpdateProblem
      }
    }
    while installs == 0 { await Task.yield() }
    return task
  }

  func startProbe() async -> Task<Result<FeedItem?, UpdateProblem>, Never> {
    let task = Task { @MainActor () -> Result<FeedItem?, UpdateProblem> in
      do {
        return .success(try await updater.probe())
      } catch {
        return .failure(error as! UpdateProblem)
      }
    }
    while probes == 0 { await Task.yield() }
    return task
  }
}

@Test @MainActor func aFoundItemIsTheProbesAnswer() async {
  let h = Harness()
  let probe = await h.startProbe()
  h.updater.found = item
  h.updater.finishCycle(error: nil)
  #expect(await probe.value == .success(item))
}

// Sparkle reports "nothing newer" as an error, and a rollback arrives this way.
@Test @MainActor func nothingNewerIsNilAndNotAnError() async {
  let h = Harness()
  let probe = await h.startProbe()
  h.updater.finishCycle(error: sparkleError(1001))
  #expect(await probe.value == .success(nil))
}

// Review focus 7
@Test @MainActor func aReadOnlyVolumeSaysToMoveTheApp() async throws {
  let h = Harness()
  let probe = await h.startProbe()
  h.updater.finishCycle(error: sparkleError(1003))
  guard case .failure(let problem) = await probe.value else { throw CancellationError() }
  #expect(problem.message == "Move Claude Multipass to Applications to update.")
}

@Test @MainActor func anUnreachableFeedIsAFailure() async throws {
  let h = Harness()
  let probe = await h.startProbe()
  h.updater.finishCycle(error: sparkleError(2001))
  guard case .failure(let problem) = await probe.value else { throw CancellationError() }
  #expect(problem.message.contains("could not be reached"))
}

@Test @MainActor func aSecondEndOfAProbeIsHarmless() async {
  let h = Harness()
  let probe = await h.startProbe()
  h.updater.finishCycle(error: nil)
  h.updater.finishCycle(error: sparkleError(2001))
  #expect(await probe.value == .success(nil))
}

@Test @MainActor func aSessionInProgressFailsRatherThanHangs() async {
  let h = Harness()
  h.canCheck = false
  await #expect(throws: UpdateProblem.self) { try await h.updater.probe() }
  await #expect(throws: UpdateProblem.self) { try await h.updater.install(offer) { _ in } }
  #expect(h.probes == 0 && h.installs == 0)
}

@Test @MainActor func stagesFollowTheDriverAndInstallReturnsAtRelaunch() async {
  let h = Harness()
  let install = await h.startInstall()
  h.updater.showDownloadInitiated(cancellation: {})
  h.updater.showDownloadDidReceiveExpectedContentLength(100)
  h.updater.showDownloadDidReceiveData(ofLength: 40)
  h.updater.showDownloadDidStartExtractingUpdate()
  var replied = false
  h.updater.showReady(toInstallAndRelaunch: { _ in replied = true })
  #expect(replied)
  h.updater.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
  await install.value
  #expect(h.stages == [.downloading(nil), .downloading(0), .downloading(0.4), .extracting, .installing, .relaunching])
  #expect(h.returned)
}

// A double resume of a checked continuation traps, so reaching the end proves once.
@Test @MainActor func callbacksAfterTheInstallResumedReportNothing() async {
  let h = Harness()
  let install = await h.startInstall()
  h.updater.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
  await install.value
  let settled = h.stages
  var acknowledged = false
  h.updater.showDownloadDidStartExtractingUpdate()
  h.updater.showUpdaterError(sparkleError(4005), acknowledgement: { acknowledged = true })
  h.updater.showInstallingUpdate(withApplicationTerminated: true, retryTerminatingApplication: {})
  h.updater.dismissUpdateInstallation()
  #expect(acknowledged)
  #expect(h.stages == settled)
  #expect(h.returned)
  #expect(h.problem == nil)
}

// The controller holds the phase once install returned, so a live process must not stay.
@Test @MainActor func aFailureAfterInstallReturnedQuits() async {
  let h = Harness()
  let install = await h.startInstall()
  h.updater.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
  await install.value
  #expect(h.quits == 0)
  h.updater.showUpdaterError(sparkleError(4005), acknowledgement: {})
  #expect(h.quits == 1)
}

@Test @MainActor func aFailureBeforeInstallReturnedNeverQuits() async {
  let h = Harness()
  let install = await h.startInstall()
  h.updater.showUpdaterError(sparkleError(4005), acknowledgement: {})
  h.updater.dismissUpdateInstallation()
  await install.value
  #expect(h.quits == 0)
  #expect(h.problem != nil)
}

@Test @MainActor func aSecondCallWhileOneWaitsFailsAndLeavesTheFirst() async {
  let h = Harness()
  let probe = await h.startProbe()
  await #expect(throws: UpdateProblem.self) { try await h.updater.probe() }
  h.updater.finishCycle(error: nil)
  #expect(await probe.value == .success(nil))
  let install = await h.startInstall()
  await #expect(throws: UpdateProblem.self) { try await h.updater.install(offer) { _ in } }
  h.updater.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
  await install.value
  #expect(h.returned)
}

@Test @MainActor func anUpdaterErrorThrowsWithTheDownloadLinkAndStopsStages() async {
  let h = Harness()
  let install = await h.startInstall()
  var acknowledged = false
  h.updater.showUpdaterError(sparkleError(4005), acknowledgement: { acknowledged = true })
  h.updater.dismissUpdateInstallation()
  await install.value
  #expect(acknowledged)
  #expect(h.problem?.message == "raw 4005")
  #expect(h.problem?.fallback == .download(UpdateController.releasePage))
  h.updater.showDownloadDidStartExtractingUpdate()
  #expect(h.stages.isEmpty)
}

@Test @MainActor func aReleaseGoneAtTheClickSaysSo() async {
  let h = Harness()
  let install = await h.startInstall()
  var acknowledged = false
  h.updater.showUpdateNotFoundWithError(sparkleError(1001), acknowledgement: { acknowledged = true })
  await install.value
  #expect(acknowledged)
  #expect(h.problem?.message == "This update is no longer offered.")
}

// The phase must never stay held by a session Sparkle ended without an error.
@Test @MainActor func aDismissedInstallReleases() async {
  let h = Harness()
  let install = await h.startInstall()
  h.updater.dismissUpdateInstallation()
  await install.value
  #expect(h.problem != nil)
}

// Nothing installs without a click: a stray session is answered no.
@Test @MainActor func withNoInstallWaitingTheReadyReplyIsDismiss() {
  let h = Harness()
  var install = false
  h.updater.showReady(toInstallAndRelaunch: { install = $0 == .install })
  #expect(!install)
}
