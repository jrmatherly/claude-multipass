import MultipassCore
import ServiceManagement
import SwiftUI

enum SettingsPane: Int, CaseIterable {
  case general, menuBar, usage, about

  var title: String {
    switch self {
    case .general: return "General"
    case .menuBar: return "Menu Bar"
    case .usage: return "Usage"
    case .about: return "About"
    }
  }

  var symbol: String {
    switch self {
    case .general: return "gearshape"
    case .menuBar: return "menubar.rectangle"
    case .usage: return "gauge.with.dots.needle.33percent"
    case .about: return "info.circle"
    }
  }
}

/// One settings tab. `draft` mirrors the settings for display, so a field
/// shows its new value before the apply stores it. An edit applies only the
/// field it changed, onto the settings current when it runs, so the four
/// tabs never write back each other's stale copies.
struct SettingsView: View {
  @ObservedObject var appState: AppState
  let pane: SettingsPane
  @State private var draft: AppSettings
  @State private var customLocation: Bool
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var loginItemError: String?

  private static let docs = URL(string: "https://github.com/jrmatherly/claude-multipass/blob/main/docs/claude-multipass.md")!

  init(appState: AppState, pane: SettingsPane) {
    self.appState = appState
    self.pane = pane
    _draft = State(initialValue: appState.settings)
    _customLocation = State(initialValue: appState.settings.cliPathOverride != nil)
  }

  var body: some View {
    Form {
      switch pane {
      case .general: general
      case .menuBar: menuBar
      case .usage: usage
      case .about: about
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
    .onReceive(appState.$settings) { settings in
      draft = settings
      if settings.cliPathOverride != nil { customLocation = true }
    }
  }

  @ViewBuilder private var general: some View {
    Section {
      Toggle("Launch at login", isOn: $launchAtLogin)
        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
      if let loginItemError {
        Text(loginItemError).font(.caption).foregroundStyle(.red)
      }
    }
    Section {
      LabeledContent("Tool") {
        Text(cliStatusText).multilineTextAlignment(.trailing).textSelection(.enabled)
      }
      Picker("Tool location", selection: $customLocation) {
        Text("Automatic").tag(false)
        Text("Custom").tag(true)
      }
      .onChange(of: customLocation) { _, custom in
        if !custom { update(\.cliPathOverride, nil) }
      }
      if customLocation {
        TextField("Path", text: cliPathBinding, prompt: Text("/path/to/claude-multipass"))
      }
    } footer: {
      Text(customLocation
        ? "A path that is empty or not executable falls back to the automatic one."
        : "Looked up in /opt/homebrew/bin, then /usr/local/bin.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var menuBar: some View {
    Section {
      Picker("Show", selection: binding(\.stripStyle)) {
        Text("Ring, name and percentage").tag(StripStyle.ringAndName)
        Text("Ring only").tag(StripStyle.ringOnly)
        Text("Name only").tag(StripStyle.name)
      }
      .pickerStyle(.radioGroup)
      LabeledContent("Preview") {
        StripView(appState: appState)
          .padding(.vertical, 3)
          .padding(.horizontal, 4)
          .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
      }
    } footer: {
      Text(draft.usageEnabled
        ? "The ring fills to the fuller of the 5-hour and weekly windows: orange from 70 %, red from 90 %."
        : "Usage is off, so the ring stays an empty outline.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var usage: some View {
    Section {
      Toggle(isOn: binding(\.usageEnabled)) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Show usage")
          Text("Reads the saved tokens through the Keychain and Anthropic's usage endpoint, outside the app. Opt-in; read the caution first.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Link("Usage headroom caution", destination: URL(string: "#usage-headroom", relativeTo: Self.docs)!.absoluteURL)
            .font(.caption)
        }
      }
      Picker("Refresh every", selection: binding(\.usageIntervalMinutes)) {
        ForEach(AppSettings.allowedIntervals, id: \.self) { Text("\($0) min").tag($0) }
      }
      .disabled(!draft.usageEnabled)
    }
  }

  @ViewBuilder private var about: some View {
    Section {
      LabeledContent("Claude Multipass", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build")
      LabeledContent("Documentation") {
        Link(destination: Self.docs) {
          HStack(spacing: 3) {
            Text("Open on GitHub")
            Image(systemName: "arrow.up.right").imageScale(.small)
          }
        }
      }
    } footer: {
      Text("Switching is always manual; usage is opt-in and read-only.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var cliPathBinding: Binding<String> {
    Binding(
      get: { draft.cliPathOverride ?? "" },
      set: { update(\.cliPathOverride, $0.isEmpty ? nil : $0) })
  }

  private func binding<Value>(_ key: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
    Binding(get: { draft[keyPath: key] }, set: { update(key, $0) })
  }

  private func update<Value>(_ key: WritableKeyPath<AppSettings, Value>, _ value: Value) {
    draft[keyPath: key] = value
    Task {
      var settings = appState.settings
      settings[keyPath: key] = value
      await appState.apply(settings)
    }
  }

  private var cliStatusText: String {
    switch appState.cliStatus {
    case .unknown: return "checking…"
    case .ready(let version): return "claude-multipass \(version)" + (appState.cliLocation.map { "\n\($0)" } ?? "")
    case .missing: return "not found"
    case .tooOld: return "too old (0.3.0 or newer is needed)"
    }
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
