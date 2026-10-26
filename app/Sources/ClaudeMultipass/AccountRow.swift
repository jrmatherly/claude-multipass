import MultipassCore
import SwiftUI

/// One saved account. Tapping a non-current row grows it inline into the
/// confirm; a refusal or failure from the CLI replaces the confirm with the
/// message and "Switch anyway" or Retry.
struct AccountRow: View {
  @ObservedObject var appState: AppState
  let profile: Profile
  let isExpanded: Bool
  var onTap: () -> Void
  var onCancel: () -> Void
  var onSwitch: (Bool) -> Void

  private var isCurrent: Bool { appState.snapshot?.current == profile.name }
  private var isSwitching: Bool { appState.phase == .switching(profile.name) }
  private var rowError: RowError? { appState.rowError?.name == profile.name ? appState.rowError : nil }
  private var rowNote: RowNote? { appState.rowNote?.name == profile.name ? appState.rowNote : nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: { if !isCurrent { onTap() } }) {
        HStack(spacing: 8) {
          Image(systemName: "checkmark").opacity(isCurrent ? 1 : 0).frame(width: 12)
          Text(profile.name).fontWeight(isCurrent ? .semibold : .regular)
          Text(profile.cliSaved ? "\(profile.sessions) sessions · CLI" : "\(profile.sessions) sessions").font(.caption).foregroundStyle(.secondary)
          Spacer()
          if appState.settings.usageEnabled {
            usageText
          }
          if isSwitching {
            ProgressView().controlSize(.small)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if isSwitching {
        Text("Switching to \(profile.name)…").font(.caption).foregroundStyle(.secondary)
      } else if let rowError {
        VStack(alignment: .leading, spacing: 4) {
          Text(rowError.message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
          HStack {
            if rowError.refused {
              Button("Switch anyway") { onSwitch(true) }
            } else {
              Button("Retry") { onSwitch(false) }
            }
            Button("Cancel", action: onCancel)
          }
        }
      } else if isExpanded {
        VStack(alignment: .leading, spacing: 4) {
          Text("Switch to \(profile.name)? Claude Desktop quits and relaunches signed in as \(profile.name). Its Code tab will list every saved account's sessions. "
            + (profile.cliSaved ? "The terminal's claude login switches too." : "The terminal's claude login stays as it is (no CLI login saved)."))
            .font(.caption)
          HStack {
            Button("Switch") { onSwitch(false) }.keyboardShortcut(.defaultAction)
            Button("Cancel", action: onCancel)
          }
        }
      } else if let rowNote {
        Text(rowNote.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }
    .padding(.vertical, 2)
    .disabled(appState.phase != .idle)
  }

  private var usageText: some View {
    let entry = appState.usage[profile.name]
    return Text("5h \(Format.percent(entry?.fiveHour?.utilization))  7d \(Format.percent(entry?.sevenDay?.utilization))")
      .font(.system(.caption, design: .monospaced))
      .foregroundStyle(.secondary)
      .help(entry?.error ?? "")
  }
}
