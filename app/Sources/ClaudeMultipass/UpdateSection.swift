import AppKit
import MultipassCore
import SwiftUI

extension InstallStage {
  var label: String {
    switch self {
    case .preparing: return "Preparing…"
    case .updatingHomebrew: return "Updating Homebrew…"
    case .upgrading: return "Upgrading…"
    case .downloading(let fraction): return fraction.map { "Downloading \(Int($0 * 100)) %" } ?? "Downloading…"
    case .extracting: return "Extracting…"
    case .installing: return "Installing…"
    case .relaunching: return "Relaunching…"
    }
  }

  /// Without the percent, so VoiceOver says the stage once and not at every progress tick.
  var spoken: String {
    if case .downloading = self { return "Downloading…" }
    return label
  }
}

/// Beside the version in About, while an offer stands.
struct UpdateBadge: View {
  @ObservedObject var updates: UpdateController

  var body: some View {
    if let offer = updates.state.offer {
      Text("\(offer.version) available")
        .font(.caption)
        .foregroundStyle(.primary)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
        .accessibilityLabel("Version \(offer.version) available")
    }
  }
}

/// The popover's footer line, while an offer stands.
struct UpdateNotice: View {
  @ObservedObject var updates: UpdateController
  let open: () -> Void

  var body: some View {
    if let offer = updates.state.offer {
      Button("Update available", action: open)
        .buttonStyle(.borderless)
        .accessibilityHint("Version \(offer.version). Opens Settings, About.")
    }
  }
}

/// Equatable, because a download publishes state at every tick and parsing each
/// line's Markdown again each time is wasted on the main thread.
private struct ReleaseNotes: View, Equatable {
  let notes: [ReleaseNote]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(notes) { note in
        VStack(alignment: .leading, spacing: 3) {
          Text("\(note.version) (\(note.date))").fontWeight(.semibold)
          ForEach(Array(note.lines.enumerated()), id: \.offset) { _, line in
            Text((try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .font(.callout)
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The rows of About between the version and the documentation link.
struct UpdateSection: View {
  @ObservedObject var updates: UpdateController
  @ObservedObject var appState: AppState
  @Binding var checksEnabled: Bool

  var body: some View {
    switch updates.state {
    case .idle, .checking, .upToDate:
      EmptyView()
    case .available(let offer):
      whatsNew(offer)
      updateRow(offer)
    case .installing(let offer, let stage):
      whatsNew(offer)
      stageLine(stage)
    case .failed(let offer, let problem):
      if let offer {
        whatsNew(offer)
        updateRow(offer)
      }
      problemRow(problem)
    }
    LabeledContent("Updates") {
      HStack {
        TimelineView(.periodic(from: .now, by: 60)) { Text(status(now: $0.date)) }
          .fixedSize()
        Button("Check now") { Task { await updates.check() } }
          .disabled(updates.state == .checking || appState.phase != .idle)
      }
    }
    Toggle("Check for updates once a day", isOn: $checksEnabled)
      // The schedule reads the setting only after its daily sleep.
      .onChange(of: checksEnabled) { _, on in
        if on { updates.start() }
      }
  }

  private func status(now: Date) -> String {
    switch updates.state {
    case .checking: return "Checking…"
    case .upToDate(let checked): return "Up to date. Checked \(Format.ago(checked, now: now))"
    case .idle, .available, .installing, .failed: return updates.checkedAt.map { "Checked \(Format.ago($0, now: now))" } ?? "Not checked yet"
    }
  }

  @ViewBuilder private func whatsNew(_ offer: UpdateOffer) -> some View {
    if !offer.notes.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("What's new")
        scrollBox(height: 160, label: "Change log") {
          ReleaseNotes(notes: offer.notes).equatable()
        }
      }
    }
  }

  /// A fixed height, because a maxHeight scroll view can collapse in the form's
  /// fixedSize, and scrolling back on, because the form turns it off.
  private func scrollBox(height: CGFloat, label: String, @ViewBuilder content: () -> some View) -> some View {
    ScrollView { content() }
      .frame(height: height)
      .scrollDisabled(false)
      .accessibilityLabel(label)
  }

  @ViewBuilder private func updateRow(_ offer: UpdateOffer) -> some View {
    switch updates.installKind {
    case .homebrew:
      updateButton(offer, caption: "Updates with Homebrew")
    case .direct, .development:
      updateButton(offer, caption: nil)
    case .homebrewMissing:
      VStack(alignment: .leading, spacing: 4) {
        Text("Homebrew installed this app, but brew was not found.")
        Link("Download the update", destination: UpdateController.releasePage)
      }
    }
  }

  private func updateButton(_ offer: UpdateOffer, caption: String?) -> some View {
    HStack {
      Button("Update and relaunch") { Task { await updates.install() } }
        .disabled(appState.phase != .idle)
        .accessibilityHint("Installs version \(offer.version).")
      if let caption {
        Text(caption).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func stageLine(_ stage: InstallStage) -> some View {
    HStack(spacing: 6) {
      ProgressView().controlSize(.small).accessibilityHidden(true)
      Text(stage.label)
    }
    .task(id: stage.spoken) { AccessibilityNotification.Announcement(stage.spoken).post() }
  }

  private func problemRow(_ problem: UpdateProblem) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(problem.message)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      fallbackRow(problem.fallback)
      if let detail = problem.detail {
        scrollBox(height: 72, label: "Output") {
          Text(detail)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .task(id: problem.message) { AccessibilityNotification.Announcement(problem.message).post() }
  }

  @ViewBuilder private func fallbackRow(_ fallback: UpdateProblem.Fallback?) -> some View {
    switch fallback {
    case .command(let command):
      HStack(alignment: .top) {
        Text(command)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("Command to run in Terminal: \(command)")
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(command, forType: .string)
        }
        .accessibilityLabel("Copy command")
      }
    case .download(let url):
      Link("Download the update", destination: url)
    case nil:
      EmptyView()
    }
  }
}
