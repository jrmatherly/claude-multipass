import AppKit
import MultipassCore
import SwiftUI

/// One settings window, kept alive across closes, brought to the front on show.
@MainActor
final class SettingsWindowController {
  private let window: NSWindow

  init(appState: AppState) {
    let hosting = NSHostingController(rootView: SettingsView(appState: appState))
    window = NSWindow(contentViewController: hosting)
    window.title = "Claude Multipass Settings"
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 420, height: 440))
  }

  func show() {
    window.center()
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }
}
