import MultipassCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
  @ObservedObject var appState: AppState
  @State private var draft: AppSettings
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var loginItemError: String?

  init(appState: AppState) {
    self.appState = appState
    _draft = State(initialValue: appState.settings)
  }

  var body: some View {
    Form {
      Section("Usage") {
        Toggle(isOn: $draft.usageEnabled) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Show usage")
            Text("Reads the saved tokens through the Keychain and Anthropic's usage endpoint, outside the app. Opt-in; read the caution first.")
              .font(.caption).foregroundStyle(.secondary)
            Link("Usage headroom caution", destination: URL(string: "https://github.com/jrmatherly/claude-multipass/blob/main/docs/claude-multipass.md#usage-headroom")!)
              .font(.caption)
          }
        }
        Picker("Refresh every", selection: $draft.usageIntervalMinutes) {
          ForEach(AppSettings.allowedIntervals, id: \.self) { Text("\($0) min").tag($0) }
        }
        .disabled(!draft.usageEnabled)
      }
      Section("Menu bar") {
        ForEach(Module.allCases, id: \.self) { module in
          Toggle(moduleTitle(module), isOn: moduleBinding(module))
            .disabled(module.needsUsage && !draft.usageEnabled)
        }
      }
      Section("General") {
        Toggle("Launch at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        if let loginItemError {
          Text(loginItemError).font(.caption).foregroundStyle(.red)
        }
        LabeledContent("CLI path") {
          VStack(alignment: .trailing, spacing: 2) {
            TextField("auto-detected", text: cliPathBinding).textFieldStyle(.roundedBorder)
            Text(cliStatusText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .onChange(of: draft) { _, new in Task { await appState.apply(new) } }
    .onReceive(appState.$settings) { settings in
      if settings != draft { draft = settings }
    }
  }

  private var cliPathBinding: Binding<String> {
    Binding(
      get: { draft.cliPathOverride ?? "" },
      set: { draft.cliPathOverride = $0.isEmpty ? nil : $0 })
  }

  private var cliStatusText: String {
    switch appState.cliStatus {
    case .unknown: return "checking…"
    case .ready(let version): return "claude-multipass \(version)" + (appState.cliLocation.map { " at \($0)" } ?? "")
    case .missing: return "not found"
    case .tooOld: return "too old (0.2.0 or newer is needed)"
    }
  }

  private func moduleTitle(_ module: Module) -> String {
    switch module {
    case .account: return "Account (@)"
    case .sessionBar: return "5-hour bar (5H)"
    case .weeklyBar: return "Weekly bar (7D)"
    case .sessionReset: return "5-hour reset countdown (5H↻)"
    case .weeklyReset: return "Weekly reset countdown (7D↻)"
    }
  }

  private func moduleBinding(_ module: Module) -> Binding<Bool> {
    Binding(
      get: { draft.enabledModules.contains(module) },
      set: { on in
        if on { draft.enabledModules.insert(module) } else { draft.enabledModules.remove(module) }
      })
  }

  private func setLaunchAtLogin(_ enabled: Bool) {
    let service = SMAppService.mainApp
    guard enabled != (service.status == .enabled) else { return }
    do {
      if enabled { try service.register() } else { try service.unregister() }
      loginItemError = nil
    } catch {
      loginItemError = error.localizedDescription
      launchAtLogin = service.status == .enabled
    }
  }
}
