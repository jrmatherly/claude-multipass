import MultipassCore
import SwiftUI

/// The signed-in account and its usage first, then the other saved accounts
/// in the tool's order. Nothing here ranks them: switching stays the user's call.
struct PopoverView: View {
  @ObservedObject var appState: AppState
  var openSettings: (SettingsPane?) -> Void
  var close: () -> Void
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
    // A confirm left open must not come back, armed for Return, after the accounts change.
    .onChange(of: appState.snapshot?.current) { expanded = nil }
  }

  private var current: Profile? {
    appState.snapshot?.profiles.first { $0.name == appState.snapshot?.current }
  }

  private var header: some View {
    let snapshot = appState.snapshot
    let name = snapshot?.current
    return VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(Format.displayName(name, signedIn: snapshot?.signedIn ?? false)).font(.headline)
        if appState.settings.usageEnabled, let plan = appState.currentUsage?.plan {
          Text(plan).font(.caption).foregroundStyle(.secondary)
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
          if entry?.isUltra == true {
            UltraIndicator()
          } else {
            UsageMeter(title: "5-hour", window: entry?.fiveHour, now: context.date)
          }
          let scoped = entry?.scoped ?? []
          UsageMeter(title: scoped.isEmpty ? "Weekly" : "Weekly · all models", window: entry?.sevenDay, now: context.date)
          ForEach(Array(scoped.enumerated()), id: \.offset) { _, limit in
            UsageMeter(title: "Weekly · \(limit.name)", window: limit.window, now: context.date)
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
            })
        }
      }
    }
  }
}

/// One usage window of the signed-in account: its name, figure and reset over a bar.
struct UsageMeter: View {
  let title: String
  let window: UsageWindow?
  let now: Date

  private var detail: String {
    guard let window else { return "–" }
    let reset = Format.reset(window.resetsAt, now: now)
    return reset == "–" ? Format.percent(window.utilization) : "\(Format.percent(window.utilization)) · resets \(reset)"
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

/// Stands in for the 5-hour meter on an Ultra account whose 5-hour window is missing or idle with no reset.
struct UltraIndicator: View {
  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Ultra").font(.subheadline.weight(.medium))
      Spacer()
      Text("no 5-hour limit").font(.subheadline).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}

struct UsageBar: View {
  let utilization: Double?
  let height: CGFloat
  var color: Color?

  var body: some View {
    Capsule()
      .fill(Color.primary.opacity(0.1))
      .overlay(alignment: .leading) {
        GeometryReader { geometry in
          Capsule()
            .fill(color ?? Format.level(utilization).color(normal: .accentColor))
            .frame(width: geometry.size.width * Format.fill(utilization))
        }
      }
      .frame(height: height)
  }
}
