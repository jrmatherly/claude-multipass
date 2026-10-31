import MultipassCore
import SwiftUI

/// The menu bar strip: two rings for the signed-in account, then its name and
/// the account's percentage, as the strip style picks. The outer ring fills to
/// the fuller of the 5-hour and weekly limits, which cover every model; the inner
/// ring, drawn only with a per-model limit, to the fullest of those. The outer
/// ring stays an empty outline while there is no account figure.
struct StripView: View {
  @ObservedObject var appState: AppState

  private var style: StripStyle { appState.settings.stripStyle }
  private var name: String { Format.displayName(appState.snapshot?.current, signedIn: appState.snapshot?.signedIn ?? false) }
  private var usage: UsageEntry? { appState.settings.usageEnabled ? appState.currentUsage : nil }

  var body: some View {
    HStack(spacing: 5) {
      if case .ready = appState.cliStatus {
        if style != .name {
          gauge
        }
        if style != .ringOnly {
          Text(name)
          if let percentText {
            Text(percentText).monospacedDigit()
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

  var gauge: RingGauge {
    RingGauge(account: usage?.accountPeak?.utilization, model: usage?.modelPeak, accountIsFull: usage?.accountIsFull ?? false)
  }

  var percentText: String? {
    guard style == .ringAndName else { return nil }
    return usage?.accountPeak.map { Format.percent($0.utilization) }
  }

  var label: String {
    if case .failed(let message) = appState.cliStatus { return "Claude Multipass: the command line tool failed: \(message)" }
    guard case .ready = appState.cliStatus else { return "Claude Multipass: the command line tool is not ready" }
    guard let summary = usage?.limitsSummary else { return name }
    return "\(name), \(summary)"
  }
}

struct RingGauge: View {
  let account: Double?
  let model: Double?
  let accountIsFull: Bool

  /// The full account limit now covers this model too, and a bright arc would suggest it has room.
  var modelColor: Color {
    accountIsFull ? Color.primary.opacity(0.6) : Format.level(model).color(normal: .primary)
  }

  var body: some View {
    ZStack {
      Ring(utilization: account, color: Format.level(account).color(normal: .primary))
        .frame(width: 16, height: 16)
      if let model {
        Ring(utilization: model, color: modelColor)
          .frame(width: 9, height: 9)
      }
    }
    .padding(1)
  }
}

private struct Ring: View {
  let utilization: Double?
  let color: Color

  var body: some View {
    ZStack {
      Circle().stroke(Color.primary.opacity(utilization == nil ? 0.6 : 0.25), lineWidth: 2)
      Circle()
        .trim(from: 0, to: Format.fill(utilization))
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
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
