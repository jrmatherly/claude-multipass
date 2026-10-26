import MultipassCore
import SwiftUI

/// The menu bar strip: icon, then one two-line cell per visible module, or a
/// `CLI` over `?` cell while the CLI is not ready. Re-reads state on a 3 s
/// tick, which also recomputes the countdowns.
struct StripView: View {
  @ObservedObject var appState: AppState
  var onWidth: (CGFloat) -> Void
  @State private var now = Date()
  private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "person.crop.circle")
        .font(.system(size: 15))
      if case .ready = appState.cliStatus {
        ForEach(appState.settings.visibleModules, id: \.self) { module in
          ModuleView(module: module, snapshot: appState.snapshot, usage: appState.currentUsage, now: now)
        }
      } else {
        ModuleView.cell(label: "CLI", text: "?")
      }
    }
    .padding(.horizontal, 6)
    .fixedSize()
    .onReceive(tick) { now = $0 }
    .background(
      GeometryReader { proxy in
        Color.clear.preference(key: StripWidthKey.self, value: proxy.size.width)
      }
    )
    .onPreferenceChange(StripWidthKey.self) { onWidth($0) }
  }
}

private struct StripWidthKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
