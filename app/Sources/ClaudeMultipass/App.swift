import AppKit
import MultipassCore

/// No SwiftUI `App` scene: `LSUIElement` in the bundle keeps it out of the
/// Dock, and the status item is the whole UI.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static var delegate: AppDelegate?
  private var appState: AppState?
  private var statusItem: StatusItemController?

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
  }

  func applicationWillTerminate(_ notification: Notification) {
    appState?.stop()
  }
}
