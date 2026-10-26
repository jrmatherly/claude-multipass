import AppKit
import MultipassCore
import SwiftUI

/// Hosts the SwiftUI strip inside the status item's button and keeps the
/// item's length equal to the strip's width, so the item follows its content.
@MainActor
final class StatusItemController: NSObject {
  private let appState: AppState
  private var statusItem: NSStatusItem?
  private var hosting: NSHostingController<StripView>?
  private var popover: PopoverController?

  init(appState: AppState) {
    self.appState = appState
  }

  func install() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let button = item.button else { return }
    let strip = StripView(appState: appState) { [weak self] width in
      // A zero arrives before the first layout; keep the item visible.
      guard width > 0 else { return }
      self?.statusItem?.length = width
    }
    let hosting = NSHostingController(rootView: strip)
    hosting.sizingOptions = [.intrinsicContentSize]
    let view = hosting.view
    view.translatesAutoresizingMaskIntoConstraints = false
    button.addSubview(view)
    NSLayoutConstraint.activate([
      view.centerXAnchor.constraint(equalTo: button.centerXAnchor),
      view.centerYAnchor.constraint(equalTo: button.centerYAnchor),
    ])
    item.length = max(view.fittingSize.width, 24)
    button.target = self
    button.action = #selector(clicked(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem = item
    self.hosting = hosting
    popover = PopoverController(appState: appState) { [weak self] in self?.openSettings() }
  }

  @objc private func clicked(_ sender: Any?) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showMenu()
    } else {
      togglePopover()
    }
  }

  func togglePopover() {
    guard let button = statusItem?.button else { return }
    popover?.toggle(relativeTo: button)
  }

  private func showMenu() {
    guard let item = statusItem else { return }
    let menu = NSMenu()
    menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
    menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Claude Multipass", action: #selector(quit), keyEquivalent: "q").target = self
    // The documented way to pop a menu from a status item that also handles
    // clicks: attach it for the click, detach it afterwards.
    item.menu = menu
    item.button?.performClick(nil)
    item.menu = nil
  }

  @objc private func refresh() {
    Task { await appState.refreshAll() }
  }

  @objc func openSettings() {}

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
