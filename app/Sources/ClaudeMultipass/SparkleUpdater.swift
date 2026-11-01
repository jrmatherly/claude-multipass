import MultipassCore
import Sparkle

/// The update feed for every real install and the installer for a DMG install, through a driver with no windows of its own. The only file that imports Sparkle.
@MainActor
final class SparkleUpdater: NSObject, SPUUserDriver, SPUUpdaterDelegate, UpdateFeed, Installer {
  /// Sparkle's entry points, apart so a test can drive the callbacks with no network.
  struct Calls {
    let canCheck: () -> Bool
    let probe: () -> Void
    let install: () -> Void
  }

  private var calls: Calls!
  /// Stored only: `didFindValidUpdate` also fires during an install.
  private var found: FeedItem?
  private var probeWaiter: CheckedContinuation<FeedItem?, Error>?
  /// Nil once the install has failed, which stops any later callback reporting a stage.
  private var installing: (waiter: CheckedContinuation<Void, Error>, report: @MainActor (InstallStage) -> Void)?
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
    guard let waiter = probeWaiter else { return }
    probeWaiter = nil
    if let error, (error as NSError).code != Int(SUError.noUpdateError.rawValue) {
      waiter.resume(throwing: Self.problem(for: error, fallback: nil))
    } else {
      waiter.resume(returning: found)
    }
  }

  // MARK: Installer

  /// Never returns on success: Sparkle's quit ends the process with the waiter pending,
  /// which leaves a late failure something to throw to.
  func install(_ offer: UpdateOffer, report: @escaping @MainActor (InstallStage) -> Void) async throws {
    guard calls.canCheck(), installing == nil else { throw Self.busy }
    try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
      installing = (waiter, report)
      calls.install()
    }
  }

  private func failInstall(_ problem: UpdateProblem) {
    guard let waiter = installing?.waiter else { return }
    installing = nil
    waiter.resume(throwing: problem)
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
  }

  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    failInstall(Self.problem(for: error, fallback: .download(UpdateController.releasePage)))
    acknowledgement()
  }

  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    failInstall(.noLongerOffered)
    acknowledgement()
  }

  /// Sparkle's teardown: an install it ends with no error must still release the phase.
  func dismissUpdateInstallation() {
    failInstall(UpdateProblem(message: "The update stopped before it finished.", detail: nil, fallback: .download(UpdateController.releasePage)))
  }

  private static let busy = UpdateProblem(message: "An update check is still running. Try again in a moment.", detail: nil, fallback: nil)

  /// Sparkle wraps the cause in generic errors two levels deep, and CFNetwork adds a useless one under a URL error.
  private static func problem(for error: Error, fallback: UpdateProblem.Fallback?) -> UpdateProblem {
    var chain = [error as NSError]
    while let under = chain.last?.userInfo[NSUnderlyingErrorKey] as? NSError { chain.append(under) }
    let network = chain.first { $0.domain == NSURLErrorDomain }
    let message: String
    switch chain[0].code {
    case Int(SUError.runningFromDiskImageError.rawValue): message = "Move Claude Multipass to Applications to update."
    case Int(SUError.downloadError.rawValue): message = network == nil ? "The update could not be downloaded." : "The update could not be reached. Check your connection."
    default: message = error.localizedDescription
    }
    let cause = chain.count > 1 ? network ?? chain.last : nil
    return UpdateProblem(message: message, detail: cause?.localizedDescription, fallback: fallback)
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
