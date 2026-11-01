import AppKit
import MultipassCore
import SwiftUI

/// The transient popover under the status item. Opening it refreshes the
/// snapshot and, when usage is on, the usage figures.
@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
  private let appState: AppState
  private let popover = NSPopover()
  private let panel: AccountPanelController
  private var noteAtOpen = 0

  init(appState: AppState, updates: UpdateController, openSettings: @escaping (SettingsPane?) -> Void) {
    self.appState = appState
    panel = AccountPanelController(appState: appState)
    super.init()
    popover.delegate = self
    popover.behavior = .transient
    popover.animates = false
    let hosting = NSHostingController(
      rootView: PopoverView(appState: appState, openSettings: openSettings, close: { [popover] in popover.performClose(nil) }, panel: panel, updates: updates))
    // The popover sizes itself from preferredContentSize; without this it
    // keeps the 320x320 default, lays out for that height and then shrinks
    // from the top, leaving a gap under the status item.
    hosting.sizingOptions = [.preferredContentSize]
    popover.contentViewController = hosting
    panel.host = hosting.view
  }

  func toggle(relativeTo button: NSView) {
    if popover.isShown {
      popover.performClose(nil)
      return
    }
    noteAtOpen = appState.noteSerial
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    // The snapshot only: usage runs on its own timer, at most every 5 minutes.
    Task { await appState.refresh() }
  }

  func popoverWillClose(_ notification: Notification) {
    panel.dismiss()
    appState.clearRowNote(seen: noteAtOpen)
  }
}
