import AppKit
import MultipassCore
import Sparkle

/// The feed and the installer for a DMG install, through a driver with no
/// windows of its own. The only file that imports Sparkle.
@MainActor
final class SparkleUpdater: NSObject, SPUUserDriver, SPUUpdaterDelegate, UpdateFeed, Installer {
  /// Sparkle's entry points, apart so a test can drive the callbacks with no network.
  struct Calls {
    let canCheck: () -> Bool
    let probe: () -> Void
    let install: () -> Void
    var quit: () -> Void = { NSApp.terminate(nil) }
  }

  private var calls: Calls!
  /// Stored only: `didFindValidUpdate` also fires during an install.
  var found: FeedItem?
  private var probeWaiter: CheckedContinuation<FeedItem?, Error>?
  /// Nil once the install has resumed, which is what stops any later callback reporting a stage.
  private var installing: (waiter: CheckedContinuation<Void, Error>, report: @MainActor (InstallStage) -> Void)?
  /// Set once install has returned, which the controller reads as about to relaunch.
  private var returned = false
  private var expectedBytes: UInt64 = 0
  private var receivedBytes: UInt64 = 0

  init(bundle: Bundle) throws {
    super.init()
    let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
    try updater.start()
    calls = Calls(
      canCheck: { updater.canCheckForUpdates },
      probe: { updater.checkForUpdateInformation() },
      install: { updater.checkForUpdates() })
  }

  init(calls: Calls) {
    self.calls = calls
    super.init()
  }

  // MARK: UpdateFeed

  func probe() async throws -> FeedItem? {
    // Sparkle ignores a check during a session, which would leave this await hanging.
    guard calls.canCheck(), probeWaiter == nil else { throw Self.busy }
    found = nil
    return try await withCheckedThrowingContinuation {
      probeWaiter = $0
      calls.probe()
    }
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    found = FeedItem(version: item.displayVersionString, changelog: item.itemDescription ?? "")
  }

  /// The one end of a probe. `didAbortWithError` also fires for "nothing newer", so it stays unused.
  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
    finishCycle(error: error)
  }

  func finishCycle(error: Error?) {
    guard let waiter = probeWaiter else { return }
    probeWaiter = nil
    if let error, (error as NSError).code != Int(SUError.noUpdateError.rawValue) {
      waiter.resume(throwing: UpdateProblem(message: Self.message(for: error), detail: nil, fallback: nil))
    } else {
      waiter.resume(returning: found)
    }
  }

  // MARK: Installer

  func install(_ offer: UpdateOffer, report: @escaping @MainActor (InstallStage) -> Void) async throws {
    guard calls.canCheck(), installing == nil else { throw Self.busy }
    try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
      installing = (waiter, report)
      calls.install()
    }
  }

  private func finishInstall(_ result: Result<Void, Error>) {
    guard let waiter = installing?.waiter else { return }
    installing = nil
    waiter.resume(with: result)
  }

  private func failInstall(_ message: String) {
    finishInstall(.failure(UpdateProblem(message: message, detail: nil, fallback: .download(UpdateController.releasePage))))
  }

  /// Nothing installs without a click, so with no install waiting the answer is no.
  private var choice: SPUUserUpdateChoice { installing == nil ? .dismiss : .install }

  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
    reply(choice)
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    expectedBytes = 0
    receivedBytes = 0
    installing?.report(.downloading(nil))
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    expectedBytes = expectedContentLength
    reportDownload()
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    receivedBytes += length
    reportDownload()
  }

  private func reportDownload() {
    installing?.report(.downloading(expectedBytes == 0 ? nil : min(1, Double(receivedBytes) / Double(expectedBytes))))
  }

  func showDownloadDidStartExtractingUpdate() {
    installing?.report(.extracting)
  }

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    installing?.report(.installing)
    reply(choice)
  }

  /// Arrives after the ready reply, and Sparkle's quit event follows it.
  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
    installing?.report(.relaunching)
    returned = installing != nil
    finishInstall(.success(()))
  }

  /// Sparkle gave up after install returned, so the controller holds the phase until
  /// this process exits. Quit, as a failed relaunch does: the user reopens the app.
  private func quitIfReturned(_ reason: String) {
    guard returned else { return }
    NSLog("Claude Multipass: the update stopped after the relaunch began: %@", reason)
    calls.quit()
  }

  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
    failInstall(Self.message(for: error))
    quitIfReturned(error.localizedDescription)
  }

  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
    finishInstall(.failure(UpdateProblem(message: "This update is no longer offered.", detail: nil, fallback: nil)))
  }

  /// Sparkle's teardown: an install it ends with no error must still release the phase.
  func dismissUpdateInstallation() {
    failInstall("The update stopped before it finished.")
    quitIfReturned("dismissed")
  }

  private static let busy = UpdateProblem(message: "An update check is still running. Try again in a moment.", detail: nil, fallback: nil)

  private static func message(for error: Error) -> String {
    switch (error as NSError).code {
    case Int(SUError.runningFromDiskImageError.rawValue): return "Move Claude Multipass to Applications to update."
    case Int(SUError.downloadError.rawValue): return "The update could not be reached. Check your connection."
    default: return error.localizedDescription
    }
  }

  // MARK: Driver methods with nothing to do

  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
  func showExtractionReceivedProgress(_ progress: Double) {}

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }
}
