import AppKit
import MultipassCore
import SwiftUI

/// The transient popover under the status item. Opening it refreshes the
/// snapshot and, when usage is on, the usage figures.
@MainActor
final class PopoverController {
  private let appState: AppState
  private let popover = NSPopover()

  init(appState: AppState, openSettings: @escaping (SettingsPane?) -> Void) {
    self.appState = appState
    popover.behavior = .transient
    popover.animates = false
    let hosting = NSHostingController(
      rootView: PopoverView(appState: appState, openSettings: openSettings, close: { [popover] in popover.performClose(nil) }))
    // The popover sizes itself from preferredContentSize; without this it
    // keeps the 320x320 default, lays out for that height and then shrinks
    // from the top, leaving a gap under the status item.
    hosting.sizingOptions = [.preferredContentSize]
    popover.contentViewController = hosting
  }

  func toggle(relativeTo button: NSView) {
    if popover.isShown {
      popover.performClose(nil)
      return
    }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    // The snapshot only: usage runs on its own timer, at most every 5 minutes.
    Task { await appState.refresh() }
  }
}
