import MultipassCore
import SwiftUI

/// The menu bar strip: a ring filled to the signed-in account's fullest usage
/// window, then its name and that percentage, as the strip style picks. The
/// ring stays an empty outline while usage is off or not fetched yet.
struct StripView: View {
  @ObservedObject var appState: AppState

  private var style: StripStyle { appState.settings.stripStyle }
  private var name: String { Format.displayName(appState.snapshot?.current, signedIn: appState.snapshot?.signedIn ?? false) }
  private var peak: (window: String, utilization: Double)? {
    appState.settings.usageEnabled ? appState.currentUsage?.peak : nil
  }

  var body: some View {
    HStack(spacing: 5) {
      if case .ready = appState.cliStatus {
        if style != .name {
          RingGauge(utilization: peak?.utilization)
        }
        if style != .ringOnly {
          Text(name)
          if style == .ringAndName, let peak {
            Text(Format.percent(peak.utilization)).monospacedDigit()
          }
        }
      } else {
        Text("CLI ?")
      }
    }
    .font(.system(size: 13))
    .padding(.horizontal, 4)
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .help(label)
  }

  private var label: String {
    if case .failed(let message) = appState.cliStatus { return "Claude Multipass: the command line tool failed: \(message)" }
    guard case .ready = appState.cliStatus else { return "Claude Multipass: the command line tool is not ready" }
    guard let peak else { return name }
    return "\(name), \(peak.window) \(Format.percent(peak.utilization))"
  }
}

struct RingGauge: View {
  let utilization: Double?

  var body: some View {
    ZStack {
      Circle().stroke(Color.primary.opacity(utilization == nil ? 0.6 : 0.25), lineWidth: 2)
      Circle()
        .trim(from: 0, to: Format.fill(utilization))
        .stroke(Format.level(utilization).color(normal: .primary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .frame(width: 14, height: 14)
    .padding(1)
  }
}

extension UsageLevel {
  /// `normal` differs by place: monochrome in the menu bar, the accent in the popover.
  func color(normal: Color) -> Color {
    switch self {
    case .normal: return normal
    case .warning: return .orange
    case .danger: return .red
    }
  }
}
