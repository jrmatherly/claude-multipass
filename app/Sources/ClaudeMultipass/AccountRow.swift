import AppKit
import MultipassCore
import SwiftUI

/// One saved account other than the signed-in one. Tapping the row grows it
/// inline into the confirm; a refusal or failure from the CLI replaces the
/// confirm with the message and "Switch anyway" or Retry.
struct AccountRow: View {
  @ObservedObject var appState: AppState
  let profile: Profile
  let isExpanded: Bool
  var onTap: () -> Void
  var onCancel: () -> Void
  var onSwitch: (Bool) -> Void
  @State private var isHovered = false

  private var isIdle: Bool { appState.phase == .idle }
  private var isSwitching: Bool { appState.phase == .switching(profile.name) }
  private var rowError: RowError? { appState.rowError?.name == profile.name ? appState.rowError : nil }
  private var rowNote: RowNote? { appState.rowNote?.name == profile.name ? appState.rowNote : nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: onTap) {
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 1) {
            Text(profile.name)
            Text(profile.cliSaved ? "Desktop and terminal login" : "Desktop login only")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          if isSwitching {
            ProgressView().controlSize(.small)
          } else if appState.settings.usageEnabled {
            weekly
          }
        }
        .padding(.vertical, 5)
        // The highlight runs into the popover margin so the text lines up with the header.
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isHovered && isIdle ? 0.08 : 0)).padding(.horizontal, -8))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { inside in
        isHovered = inside
        (inside && isIdle ? NSCursor.pointingHand : NSCursor.arrow).set()
      }
      // A row that leaves the list under the pointer (it just became the signed-in one) gets no exit.
      .onDisappear { if isHovered { NSCursor.arrow.set() } }
      detail
    }
    .disabled(!isIdle)
  }

  @ViewBuilder private var detail: some View {
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
        .controlSize(.small)
      }
    } else if isExpanded {
      VStack(alignment: .leading, spacing: 4) {
        Text("Switch to \(profile.name)? Claude Desktop quits and relaunches signed in as \(profile.name). Its Code tab will list every saved account's sessions. "
          + (profile.cliSaved ? "The terminal's claude login switches too." : "The terminal's claude login stays as it is (no CLI login saved)."))
          .font(.caption)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Switch") { onSwitch(false) }.keyboardShortcut(.defaultAction)
          Button("Cancel", action: onCancel)
        }
        .controlSize(.small)
      }
    } else if let rowNote {
      Text(rowNote.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
  }

  private var weekly: some View {
    let entry = appState.usage[profile.name]
    return HStack(spacing: 6) {
      Text(Format.percent(entry?.sevenDay?.utilization)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
      UsageBar(utilization: entry?.sevenDay?.utilization, height: 4).frame(width: 40)
    }
    .help(entry?.error ?? "Weekly usage")
  }
}
