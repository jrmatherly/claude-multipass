import MultipassCore
import SwiftUI

struct PopoverView: View {
  @ObservedObject var appState: AppState
  var openSettings: () -> Void
  var close: () -> Void
  @State private var expanded: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
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
          Text("The installed claude-multipass is too old for this app (0.2.0 or newer is needed).")
          Text("brew upgrade claude-multipass").font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
      case .ready:
        header
        accounts
        if let snapshot = appState.snapshot, snapshot.signedIn, snapshot.current == nil {
          SaveRow(appState: appState)
        }
      }
      if let error = appState.lastError {
        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
      Divider()
      HStack {
        Button("Refresh") { Task { await appState.refreshAll() } }
        Button("Settings…") {
          close()
          openSettings()
        }
        Spacer()
        Button("Quit") { NSApp.terminate(nil) }
      }
    }
    .padding(12)
    .frame(width: 320)
  }

  private var header: some View {
    let snapshot = appState.snapshot
    return VStack(alignment: .leading, spacing: 2) {
      Text(Format.displayName(snapshot?.current, signedIn: snapshot?.signedIn ?? false)).font(.headline)
      Text(snapshot?.desktopRunning == true ? "Claude Desktop is running" : "Claude Desktop is not running")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var accounts: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let profiles = appState.snapshot?.profiles, !profiles.isEmpty {
        ForEach(profiles) { profile in
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
      } else {
        Text("No saved accounts yet. Run claude-multipass save <name> for the signed-in one.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
