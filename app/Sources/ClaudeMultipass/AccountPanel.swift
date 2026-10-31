import AppKit
import MultipassCore
import SwiftUI

/// Which row the panel is for. The first row waits out a delay; moving to another
/// row while one is shown does not. The row may have no figures to show. SwiftUI may deliver the next row's enter before this row's
/// exit, so an exit counts only for the row the pointer last entered.
@MainActor
final class AccountHover {
  private(set) var shown: String? {
    didSet { if shown != oldValue { onChange(shown) } }
  }
  private var pointer: String?
  private var pending: Task<Void, Never>?
  private let showDelay: TimeInterval
  private let hideDelay: TimeInterval
  private let onChange: (String?) -> Void

  init(showDelay: TimeInterval = 0.35, hideDelay: TimeInterval = 0.12, onChange: @escaping (String?) -> Void) {
    self.showDelay = showDelay
    self.hideDelay = hideDelay
    self.onChange = onChange
  }

  func entered(_ name: String) {
    pointer = name
    pending?.cancel()
    if shown != nil {
      shown = name
    } else {
      schedule(name, after: showDelay)
    }
  }

  func left(_ name: String) {
    guard pointer == name else { return }
    pointer = nil
    pending?.cancel()
    if shown != nil { schedule(nil, after: hideDelay) }
  }

  func dismiss() {
    pointer = nil
    pending?.cancel()
    shown = nil
  }

  private func schedule(_ name: String?, after delay: TimeInterval) {
    pending = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.shown = name
    }
  }
}

/// One account's plan line and bars, from the same parts as the popover's. An error replaces the bars.
struct AccountDetail: View {
  let name: String
  let entry: UsageEntry
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(name).font(.headline).lineLimit(1).layoutPriority(1)
        if let line = entry.planLine(now: now) {
          Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      if let error = entry.error {
        Text(error).font(.caption).foregroundStyle(.red)
      } else {
        ForEach(Array(UsageMeter.meters(for: entry, now: now).enumerated()), id: \.offset) { _, meter in
          meter
        }
      }
    }
    .padding(12)
    .frame(width: 260, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
  }
}

/// The read-only panel beside the popover. It reads only `appState`, never the
/// network, the Keychain or the CLI. It never takes key or the mouse, so the
/// transient popover stays open. Not a child window: `performClose` does nothing
/// on a popover whose window has a child (measured).
@MainActor
final class AccountPanelController {
  /// The hosting view's own space: `.global` starts at the popover window, which holds the arrow margins.
  nonisolated static let space = "popover"
  weak var host: NSView?
  private let appState: AppState
  private let showDelay: TimeInterval
  private var rowFrames: [String: CGRect] = [:]
  private(set) var panel: NSPanel?
  private(set) lazy var hover = AccountHover(showDelay: showDelay) { [weak self] name in self?.update(name) }

  init(appState: AppState, showDelay: TimeInterval = 0.35) {
    self.appState = appState
    self.showDelay = showDelay
  }

  func rowHover(name: String, inside: Bool, frame: CGRect) {
    rowFrames[name] = frame
    if inside { hover.entered(name) } else { hover.left(name) }
  }

  func dismiss() {
    hover.dismiss()
  }

  /// A fetch that adds, changes or clears the figures while the panel's row stays the same.
  func refresh() {
    update(hover.shown)
  }

  /// Turning usage off leaves the last report in AppState, so this gate hides it.
  func detailEntry(for name: String) -> UsageEntry? {
    appState.settings.usageEnabled ? appState.usage[name] : nil
  }

  private func update(_ name: String?) {
    guard let name, let entry = detailEntry(for: name), let host, let window = host.window, window.isVisible else {
      hide()
      return
    }
    // shortcut: the countdown is fixed until the next fetch or row change, upgrade to a TimelineView if a long hover reads stale.
    let hosting = NSHostingView(rootView: AccountDetail(name: name, entry: entry, now: Date()))
    hosting.appearance = window.effectiveAppearance
    let size = hosting.fittingSize
    let panel = self.panel ?? makePanel()
    panel.contentView = hosting
    let popover = window.convertToScreen(host.convert(host.bounds, to: nil))
    let frame = rowFrames[name] ?? .zero
    let row = CGRect(x: popover.minX + frame.minX, y: popover.maxY - frame.maxY, width: frame.width, height: frame.height)
    let screen = window.screen?.visibleFrame ?? popover
    panel.setFrame(CGRect(origin: Self.origin(size: size, popover: popover, row: row, screen: screen), size: size), display: true)
    panel.orderFrontRegardless()
  }

  private func hide() {
    panel?.orderOut(nil)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = false
    // The popover opens on whichever Space is active, full-screen ones too.
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    self.panel = panel
    return panel
  }

  /// All in screen coordinates. `popover` is the hosting view's rect, since the
  /// popover window also holds the arrow margins.
  static func origin(size: CGSize, popover: CGRect, row: CGRect, screen: CGRect) -> CGPoint {
    var x = popover.minX - size.width - 8
    if x < screen.minX { x = popover.maxX + 8 }
    let y = min(max(row.maxY - size.height, screen.minY), screen.maxY - size.height)
    return CGPoint(x: x, y: y)
  }
}
