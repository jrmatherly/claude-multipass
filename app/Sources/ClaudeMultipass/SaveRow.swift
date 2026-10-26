import MultipassCore
import SwiftUI

/// Shown when Desktop is signed in to a login no profile holds. Save is
/// enabled only for a name the CLI accepts that no profile uses yet, so the
/// CLI's "another account" refusal cannot be reached from here.
struct SaveRow: View {
  @ObservedObject var appState: AppState
  @State private var name = ""
  @State private var attempted = ""

  private var canSave: Bool {
    isValidProfileName(name) && !(appState.snapshot?.profiles.contains { $0.name == name } ?? false)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("This login is not saved yet.").font(.caption).foregroundStyle(.secondary)
      HStack {
        TextField("Save this login as…", text: $name)
          .textFieldStyle(.roundedBorder)
          .onSubmit { if canSave { save() } }
        Button("Save", action: save).disabled(!canSave)
      }
      if appState.phase == .saving(attempted) {
        Text("Saving as \(attempted)…").font(.caption).foregroundStyle(.secondary)
      } else if let error = appState.rowError, error.name == attempted {
        Text(error.message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
    }
    .disabled(appState.phase != .idle)
  }

  private func save() {
    let chosen = name
    attempted = chosen
    Task { await appState.saveCurrent(as: chosen) }
  }
}
