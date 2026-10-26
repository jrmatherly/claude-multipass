import AppKit
import MultipassCore
import SwiftUI

/// The transient popover under the status item. Opening it refreshes the
/// snapshot and, when usage is on, the usage figures.
@MainActor
final class PopoverController {
  private let appState: AppState
  private let popover = NSPopover()

  init(appState: AppState, openSettings: @escaping () -> Void) {
    self.appState = appState
    popover.behavior = .transient
    popover.animates = false
    popover.contentViewController = NSHostingController(
      rootView: PopoverView(appState: appState, openSettings: openSettings, close: { [popover] in popover.performClose(nil) }))
  }

  func toggle(relativeTo button: NSView) {
    if popover.isShown {
      popover.performClose(nil)
      return
    }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    Task { await appState.refreshAll() }
  }
}
