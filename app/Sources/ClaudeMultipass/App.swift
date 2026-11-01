import AppKit
import MultipassCore

/// No SwiftUI `App` scene: `LSUIElement` in the bundle keeps it out of the
/// Dock, and the status item is the whole UI.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static var delegate: AppDelegate?
  private var appState: AppState?
  private var statusItem: StatusItemController?
  private(set) var updates: UpdateController?

  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    Self.delegate = delegate
    app.delegate = delegate
    app.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let appState = AppState(
      makeRunner: { settings in CLI.locate(override: settings.cliPathOverride).map { CLI(executable: $0) } },
      store: SettingsStore(defaults: .standard))
    appState.start()
    let controller = StatusItemController(appState: appState)
    controller.install()
    self.appState = appState
    statusItem = controller
    updates = Self.makeUpdates(appState: appState)
    updates?.start()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    updates?.state.blocksQuit == true ? .terminateCancel : .terminateNow
  }

  func applicationWillTerminate(_ notification: Notification) {
    updates?.stop()
    appState?.stop()
  }

  @MainActor
  private static func makeUpdates(appState: AppState) -> UpdateController {
    let bundleURL = Bundle.main.bundleURL
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    let detect = { InstallKind.detect(bundleURL: bundleURL, version: version) }
    var sparkle: SparkleUpdater?
    if detect() != .development {
      do {
        sparkle = try SparkleUpdater(bundle: .main)
      } catch {
        NSLog("Claude Multipass: Sparkle did not start, so updates are off: %@", "\(error)")
      }
    }
    return UpdateController(
      appState: appState,
      feed: sparkle,
      detect: detect,
      installer: { [sparkle] kind in
        switch kind {
        case .homebrew(let brew):
          return BrewInstaller(
            runner: CLI(executable: brew, mutatingTimeout: BrewInstaller.timeout, extraEnvironment: BrewInstaller.environment),
            appURL: bundleURL,
            diskVersion: diskVersion,
            relaunch: relaunch)
        case .direct:
          return sparkle
        case .homebrewMissing, .development:
          return nil
        }
      },
      runningVersion: version)
  }

  /// Read from the file, because `Bundle` caches its Info.plist.
  private static func diskVersion(_ app: URL) -> String? {
    NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
  }

  /// Waits for this process to exit, because an `open` while it lives only reactivates it.
  /// The new version is on disk by now, so a failed spawn still quits: the user reopens it,
  /// and the phase is never left held in a live process.
  private static func relaunch(_ app: URL) {
    let waiter = Process()
    waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
    waiter.arguments = [
      "-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; open "$0""#,
      app.path, String(ProcessInfo.processInfo.processIdentifier),
    ]
    do {
      try waiter.run()
    } catch {
      NSLog("Claude Multipass: could not start the relaunch helper: %@", "\(error)")
    }
    NSApp.terminate(nil)
  }
}
