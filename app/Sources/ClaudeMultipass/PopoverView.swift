import MultipassCore
import SwiftUI

/// The signed-in account and its usage first, then the other saved accounts
/// in the tool's order. Nothing here ranks them: switching stays the user's call.
struct PopoverView: View {
  @ObservedObject var appState: AppState
  var openSettings: (SettingsPane?) -> Void
  var close: () -> Void
  var panel: AccountPanelController?
  var updates: UpdateController?
  @State private var expanded: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      switch appState.cliStatus {
      case .unknown:
        Text("Checking the CLI…").foregroundStyle(.secondary)
      case .missing:
        VStack(alignment: .leading, spacing: 6) {
          Text("The claude-multipass command line tool is not installed.")
          Text("brew install jrmatherly/tap/claude-multipass").font(.system(.body, design: .monospaced)).textSelection(.enabled)
          Text("Or set its path in Settings.").foregroundStyle(.secondary)
        }
      case .tooOld:
        VStack(alignment: .leading, spacing: 6) {
          Text("The installed claude-multipass is too old for this app (0.3.0 or newer is needed).")
          Text("brew upgrade claude-multipass").font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
      case .failed(let message):
        VStack(alignment: .leading, spacing: 6) {
          Text("The claude-multipass command line tool did not report its version.")
          Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
          Text("claude-multipass doctor").font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
      case .ready:
        header
        usage
        if let snapshot = appState.snapshot, snapshot.signedIn, snapshot.current == nil {
          SaveRow(appState: appState)
        }
        accounts
      }
      if let error = appState.lastError {
        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
      Divider()
      if let updates {
        UpdateNotice(updates: updates) {
          close()
          openSettings(.about)
        }
      }
      HStack(spacing: 16) {
        Button("Refresh") { Task { await appState.refreshAll() } }
        Button("Settings…") {
          close()
          openSettings(nil)
        }
      }
      .buttonStyle(.borderless)
    }
    .padding(14)
    .frame(width: 320)
    .coordinateSpace(.named(AccountPanelController.space))
    // A confirm left open must not come back, armed for Return, after the accounts change.
    .onChange(of: appState.snapshot?.current) { expanded = nil }
    // Return can start a switch or a save with the pointer resting on another row, which sends no hover event.
    .onChange(of: appState.phase) { panel?.dismiss() }
    .onChange(of: appState.usage) { panel?.refresh() }
  }

  private var current: Profile? {
    appState.snapshot?.profiles.first { $0.name == appState.snapshot?.current }
  }

  var planLine: String? {
    appState.settings.usageEnabled ? appState.currentUsage?.planLine(now: Date()) : nil
  }

  private var header: some View {
    let snapshot = appState.snapshot
    let name = snapshot?.current
    return VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(Format.displayName(name, signedIn: snapshot?.signedIn ?? false)).font(.headline)
        if let planLine {
          Text(planLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Text((snapshot?.desktopRunning == true ? "Desktop running" : "Desktop not running") + (current?.cliSaved == true ? " · terminal login too" : ""))
        .font(.caption).foregroundStyle(.secondary)
      // A switch's warning or failure stays visible once its target is the signed-in account.
      if let note = appState.rowNote, note.name == name {
        Text(note.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if let error = appState.rowError, error.name == name {
        Text(error.message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
    }
  }

  @ViewBuilder private var usage: some View {
    if appState.settings.usageEnabled {
      let entry = appState.currentUsage
      TimelineView(.periodic(from: .now, by: 30)) { context in
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(UsageMeter.meters(for: entry, now: context.date).enumerated()), id: \.offset) { _, meter in
            meter
          }
          if let error = entry?.error {
            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
          } else if let updated = appState.usageUpdatedAt {
            Text("updated \(Format.ago(updated, now: context.date))").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    } else {
      HStack(spacing: 4) {
        Text("Usage is off.").foregroundStyle(.secondary)
        Button("Turn it on in Settings") {
          close()
          openSettings(.usage)
        }
        .buttonStyle(.link)
      }
      .font(.caption)
    }
  }

  @ViewBuilder private var accounts: some View {
    let profiles = appState.snapshot?.profiles ?? []
    let others = profiles.filter { $0.name != appState.snapshot?.current }
    if profiles.isEmpty {
      Text("No saved accounts yet. Run claude-multipass save <name> for the signed-in one.")
        .font(.caption).foregroundStyle(.secondary)
    } else if !others.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        Text("Switch to").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        ForEach(others) { profile in
          AccountRow(
            appState: appState, profile: profile,
            isExpanded: expanded == profile.name,
            onTap: {
              panel?.dismiss()
              appState.dismissRowError()
              expanded = expanded == profile.name ? nil : profile.name
            },
            onCancel: {
              appState.dismissRowError()
              expanded = nil
            },
            onSwitch: { force in
              expanded = nil
              Task { await appState.switchTo(profile.name, force: force) }
            },
            onHover: { panel?.rowHover(name: profile.name, inside: $0, frame: $1) })
        }
      }
    }
  }
}

/// One usage window of the signed-in account: its name and figure over a bar.
/// Only the 5-hour window names a reset; the header has the weekly one, which
/// the Fable limit shares (measured in `.claude/rules/desktop-internals.md`).
struct UsageMeter: View {
  let title: String
  let window: UsageWindow?
  let now: Date
  var showsReset = false

  /// A verified Ultra account has no 5-hour limit to show.
  static func meters(for entry: UsageEntry?, now: Date) -> [UsageMeter] {
    let scoped = entry?.scoped ?? []
    var meters: [UsageMeter] = []
    if entry?.isUltra != true {
      meters.append(UsageMeter(title: "5-hour", window: entry?.fiveHour, now: now, showsReset: true))
    }
    meters.append(UsageMeter(title: scoped.isEmpty ? "Weekly" : "Weekly · all models", window: entry?.sevenDay, now: now))
    return meters + scoped.map { UsageMeter(title: "Weekly · \($0.name)", window: $0.window, now: now) }
  }

  var detail: String {
    guard let window else { return "–" }
    let reset = Format.countdown(to: window.resetsAt, now: now)
    return showsReset && reset != "–" ? "\(Format.percent(window.utilization)) · resets \(reset)" : Format.percent(window.utilization)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.subheadline.weight(.medium))
        Spacer()
        Text(detail).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
      }
      UsageBar(utilization: window?.utilization, height: 6)
    }
    .accessibilityElement(children: .combine)
  }
}

struct UsageBar: View {
  let utilization: Double?
  let height: CGFloat
  var color: Color?

  var fillColor: Color { color ?? Format.level(utilization).color(normal: .accentColor) }

  var body: some View {
    Capsule()
      .fill(Color.primary.opacity(0.1))
      .overlay(alignment: .leading) {
        GeometryReader { geometry in
          Capsule()
            .fill(fillColor)
            .frame(width: geometry.size.width * Format.fill(utilization))
        }
      }
      .frame(height: height)
  }
}
