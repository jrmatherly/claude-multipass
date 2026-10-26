import MultipassCore
import SwiftUI

/// One iStats-style cell: a short label over a value or a capsule bar.
struct ModuleView: View {
  let module: Module
  let snapshot: Snapshot?
  let usage: UsageEntry?
  let now: Date

  var body: some View {
    switch module {
    case .account:
      Self.cell(label: module.label, text: Format.displayName(snapshot?.current, signedIn: snapshot?.signedIn ?? false))
    case .sessionBar:
      Self.bar(label: module.label, utilization: usage?.fiveHour?.utilization)
    case .weeklyBar:
      Self.bar(label: module.label, utilization: usage?.sevenDay?.utilization)
    case .sessionReset:
      Self.cell(label: module.label, text: Format.countdown(to: usage?.fiveHour?.resetsAt, now: now))
    case .weeklyReset:
      Self.cell(label: module.label, text: Format.countdown(to: usage?.sevenDay?.resetsAt, now: now))
    }
  }

  static func cell(label: String, text: String) -> some View {
    VStack(spacing: 0) {
      Self.labelText(label)
      Text(text).font(.system(size: 11, design: .monospaced))
    }
  }

  static func bar(label: String, utilization: Double?) -> some View {
    VStack(spacing: 1) {
      Self.labelText(label)
      HStack(spacing: 3) {
        Capsule()
          .fill(Format.isDanger(utilization) ? Color.red : Color.primary)
          .frame(width: 28 * Format.fill(utilization), height: 8)
          .frame(width: 28, alignment: .leading)
          .background(Capsule().strokeBorder(Color.primary.opacity(0.5), lineWidth: 1))
        Text(Format.percent(utilization)).font(.system(size: 11, design: .monospaced))
      }
    }
  }

  private static func labelText(_ label: String) -> some View {
    Text(label).font(.system(size: 9, weight: .semibold))
  }
}
