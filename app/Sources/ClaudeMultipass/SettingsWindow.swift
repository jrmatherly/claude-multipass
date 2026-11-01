import AppKit
import MultipassCore
import SwiftUI

/// One settings window, kept alive across closes, brought to the front on
/// show. AppKit's toolbar-style tab controller gives the system Settings
/// look, which SwiftUI's `TabView` has only inside a `Settings` scene; the
/// window takes each tab's own height.
@MainActor
final class SettingsWindowController {
  let window: NSWindow
  private let tabs = NSTabViewController()

  init(appState: AppState, updates: UpdateController? = nil) {
    tabs.tabStyle = .toolbar
    for pane in SettingsPane.allCases {
      let hosting = NSHostingController(rootView: SettingsView(appState: appState, pane: pane, updates: updates))
      hosting.sizingOptions = [.preferredContentSize]
      hosting.title = pane.title
      let item = NSTabViewItem(viewController: hosting)
      item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
      tabs.addTabViewItem(item)
    }
    window = NSWindow(contentViewController: tabs)
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
  }

  func show(pane: SettingsPane? = nil) {
    if let pane { tabs.selectedTabViewItemIndex = pane.rawValue }
    if !window.isVisible { window.center() }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    // The path field would otherwise take focus and select its text on open.
    window.makeFirstResponder(nil)
  }
}
