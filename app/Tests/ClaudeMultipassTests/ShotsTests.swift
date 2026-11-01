import AppKit
import Foundation
import MultipassCore
import SwiftUI
import Testing

@testable import ClaudeMultipass

/// Renders the strip, the popover, the account panel and each settings tab to PNGs in light and
/// dark, from fixture state. Runs only with UI_SHOTS_DIR set:
/// `UI_SHOTS_DIR=/tmp/shots swift test --package-path app --filter Shots`.
private let shotsDir = ProcessInfo.processInfo.environment["UI_SHOTS_DIR"]

struct FixtureRunner: CommandRunner {
  var usage: String?
  var usageFails = false
  var versionFails = false
  var switchHangs = false
  var switchRefusal: String?
  var location: String? { "/opt/homebrew/bin/claude-multipass" }

  func runCapturing(_ args: [String]) async throws -> CommandOutput {
    func out(_ text: String) -> CommandOutput { CommandOutput(stdout: Data(text.utf8), stderr: "") }
    switch args[0] {
    case "--version":
      if versionFails { throw CLIError.failed(status: 127, stderr: "/opt/homebrew/bin/claude-multipass: line 12: jq: command not found") }
      return out("claude-multipass 0.4.0\n")
    case "list": return out(snapshot)
    case "usage":
      if usageFails { throw CLIError.timedOut }
      return out(usage ?? #"{"profiles":[]}"#)
    case "switch":
      if switchHangs { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
      if let switchRefusal { throw CLIError.refused(switchRefusal) }
      return out("")
    default: throw CLIError.failed(status: 1, stderr: "unscripted \(args)")
    }
  }
}

private let snapshot = #"{"version":"0.4.0","signedIn":true,"desktopRunning":true,"current":"matherly-gmail","profiles":[{"name":"matherly-gmail","account":"a","savedAt":null,"sessions":3,"cliSaved":true},{"name":"work","account":"b","savedAt":null,"sessions":9,"cliSaved":false},{"name":"max-plan","account":"c","savedAt":null,"sessions":1,"cliSaved":true}]}"#

private func usageJSON(five: Double, seven: Double) -> String {
  let iso = ISO8601DateFormatter()
  let fiveReset = iso.string(from: Date().addingTimeInterval(2 * 3600 + 14 * 60 + 30))
  let sevenReset = iso.string(from: Date().addingTimeInterval(3 * 86400 + 3600))
  return #"{"profiles":[{"name":"matherly-gmail","fiveHour":{"utilization":\#(five),"resetsAt":"\#(fiveReset)"},"sevenDay":{"utilization":\#(seven),"resetsAt":"\#(sevenReset)"}},{"name":"work","fiveHour":{"utilization":4},"sevenDay":{"utilization":12}},{"name":"max-plan","fiveHour":{"utilization":20},"sevenDay":{"utilization":81}}]}"#
}

/// The current account on Ultra: verified (no 5-hour limit), or still under
/// its temporary session limit with its Fable weekly limit reached.
private func planJSON(verified: Bool) -> String {
  let iso = ISO8601DateFormatter()
  let weekReset = iso.string(from: Date().addingTimeInterval(4 * 86400 + 3600))
  let session = verified ? #""ultra":true"# : #""fiveHour":{"utilization":17,"resetsAt":"\#(iso.string(from: Date().addingTimeInterval(4 * 3600)))"}"#
  let fable = verified ? 96 : 100
  return #"{"profiles":[{"name":"matherly-gmail","plan":"Ultra",\#(session),"sevenDay":{"utilization":59,"resetsAt":"\#(weekReset)"},"scoped":[{"name":"Fable","utilization":\#(fable),"resetsAt":"\#(weekReset)"}]},{"name":"work","plan":"Max","fiveHour":{"utilization":4},"sevenDay":{"utilization":12}}]}"#
}

func mixedJSON(five: Double, seven: Double, fable: Double) -> String {
  #"{"profiles":[{"name":"matherly-gmail","fiveHour":{"utilization":\#(five)},"sevenDay":{"utilization":\#(seven)},"scoped":[{"name":"Fable","utilization":\#(fable)}]}]}"#
}

private let usageLevels: [(String, String?)] = [
  ("normal", usageJSON(five: 38, seven: 52)),
  ("warning", usageJSON(five: 38, seven: 73.4)),
  ("danger", usageJSON(five: 94, seven: 73.4)),
  ("off", nil),
  ("ultra", planJSON(verified: true)),
  ("fable", planJSON(verified: false)),
  ("account-full", mixedJSON(five: 100, seven: 59, fable: 40)),
  ("fable-full", mixedJSON(five: 17, seven: 73, fable: 100)),
  ("both-full", mixedJSON(five: 100, seven: 59, fable: 100)),
  ("fable-warning", mixedJSON(five: 17, seven: 59, fable: 75)),
  ("rows", #"{"profiles":[{"name":"matherly-gmail","plan":"Ultra","ultra":true,"sevenDay":{"utilization":59},"scoped":[{"name":"Fable","utilization":48}]},{"name":"work","fiveHour":{"utilization":10},"sevenDay":{"utilization":59},"scoped":[{"name":"Fable","utilization":100}]},{"name":"max-plan","fiveHour":{"utilization":100},"sevenDay":{"utilization":81},"scoped":[{"name":"Fable","utilization":40}]}]}"#),
  ("model-only", #"{"profiles":[{"name":"matherly-gmail","scoped":[{"name":"Fable","utilization":40}]}]}"#),
]

/// One suite per test target, emptied before each AppState is made, so a run
/// leaves one plist in ~/Library/Preferences instead of one per test. AppState
/// reads the store only in its init, on the main actor with no await between
/// this clear and that read, so tests sharing the suite still start empty.
@MainActor
private func scratchDefaults() -> UserDefaults {
  let suite = "net.matherly.claude-multipass.shots"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@MainActor
func state(_ runner: FixtureRunner?, style: StripStyle = .ringAndName) async -> AppState {
  let store = SettingsStore(defaults: scratchDefaults())
  let s = AppState(makeRunner: { _ in runner }, store: store)
  await s.relocate()
  await s.refresh()
  var settings = s.settings
  settings.stripStyle = style
  settings.usageEnabled = runner?.usage != nil || runner?.usageFails == true
  await s.apply(settings)
  s.stop()
  return s
}

@MainActor
private func write(_ view: NSView, _ name: String) throws {
  view.layoutSubtreeIfNeeded()
  let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
  view.cacheDisplay(in: view.bounds, to: rep)
  let png = try #require(rep.representation(using: .png, properties: [:]))
  try png.write(to: URL(fileURLWithPath: shotsDir!).appendingPathComponent(name + ".png"))
}

@MainActor
private func render(_ view: some View, _ name: String, background: NSColor = .windowBackgroundColor) throws {
  for dark in [false, true] {
    let host = NSHostingView(rootView: view.background(Color(nsColor: background)))
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.appearance = appearance
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    try write(host, name + (dark ? "-dark" : "-light"))
  }
}

@MainActor
final class FixtureFeed: UpdateFeed {
  private let result: Result<FeedItem?, Error>
  init(_ result: Result<FeedItem?, Error>) { self.result = result }
  func probe() async throws -> FeedItem? { try result.get() }
}

/// Reports `stage` and then never finishes, or throws `error`.
@MainActor
final class FixtureInstaller: Installer {
  private let stage: InstallStage?
  private let error: Error?
  init(stage: InstallStage? = nil, error: Error? = nil) {
    self.stage = stage
    self.error = error
  }

  func install(_ offer: UpdateOffer, report: @escaping @MainActor (InstallStage) -> Void) async throws {
    if let stage {
      report(stage)
      try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
    if let error { throw error }
  }
}

/// Far more than fits the change log's fixed height, with the inline Markdown the file uses.
let fixtureChangelog = (0..<9).map { i in
  "## 0.\(19 - i).0 (2026-11-\(10 + i))\n\n- The menu bar app shows **a long line** that has to wrap, with `some code` in it, and a [link](https://example.com).\n- A short line.\n"
}.joined(separator: "\n")

@MainActor
func updateController(
  _ appState: AppState,
  feed: Result<FeedItem?, Error> = .success(FeedItem(version: "0.19.0", changelog: fixtureChangelog)),
  kind: InstallKind = .direct,
  installer: FixtureInstaller? = nil
) -> UpdateController {
  let installer = installer ?? FixtureInstaller()
  return UpdateController(
    appState: appState,
    feed: FixtureFeed(feed),
    detect: { kind },
    installer: { kind in kind == .homebrewMissing ? nil : installer },
    runningVersion: "0.9.0")
}

/// Each named state, reached through `check()` and `install()` as the real app reaches it.
@MainActor
func updateFixture(_ name: String) async -> (AppState, UpdateController) {
  let appState = await state(FixtureRunner())
  let brew = InstallKind.homebrew(brew: URL(fileURLWithPath: "/opt/homebrew/bin/brew"))
  let controller: UpdateController
  switch name {
  case "idle":
    return (appState, updateController(appState))
  case "upToDate":
    controller = updateController(appState, feed: .success(nil))
  case "available":
    controller = updateController(appState)
  case "availableBrew":
    controller = updateController(appState, kind: brew)
  case "noBrew":
    controller = updateController(appState, kind: .homebrewMissing)
  case "failedCheck":
    controller = updateController(appState, feed: .failure(UpdateProblem(message: "The update server could not be reached.", detail: nil, fallback: nil)))
  case "installing":
    controller = updateController(appState, kind: brew, installer: FixtureInstaller(stage: .downloading(0.4)))
  case "failedBrew":
    let output = (1...20).map { "Error: line \($0) of what brew printed, long enough that it has to wrap in the output area" }.joined(separator: "\n")
    let problem = UpdateProblem(message: "Homebrew could not update the app. macOS may be blocking this. Check System Settings, Privacy and Security, App Management.", detail: output, fallback: .command(BrewInstaller.command))
    controller = updateController(appState, kind: brew, installer: FixtureInstaller(error: problem))
  case "failedSparkle":
    let problem = UpdateProblem(message: "The update could not be installed.", detail: nil, fallback: .download(UpdateController.releasePage))
    controller = updateController(appState, installer: FixtureInstaller(error: problem))
  default:
    preconditionFailure("no update fixture named \(name)")
  }
  await controller.check()
  switch name {
  case "installing":
    Task { await controller.install() }
    while true {
      if case .installing(_, .downloading) = controller.state { break }
      await Task.yield()
    }
  case "failedBrew", "failedSparkle":
    await controller.install()
  default:
    break
  }
  return (appState, controller)
}

@MainActor
private func menuBar(_ view: some View) -> some View {
  view.padding(.horizontal, 10).padding(.vertical, 3).background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
}

@Suite(.enabled(if: shotsDir != nil)) @MainActor struct Shots {
  @Test func strip() async throws {
    for style in StripStyle.allCases {
      for (level, usage) in usageLevels {
        let s = await state(FixtureRunner(usage: usage), style: style)
        try render(menuBar(StripView(appState: s)), "strip-\(style.rawValue)-\(level)")
      }
    }
    try render(menuBar(StripView(appState: await state(nil))), "strip-cli-missing")
  }

  @Test func popover() async throws {
    for (level, usage) in usageLevels where level != "warning" {
      let s = await state(FixtureRunner(usage: usage))
      try render(PopoverView(appState: s, openSettings: { _ in }, close: {}), "popover-usage-\(level)")
    }

    let switching = await state(FixtureRunner(usage: usageLevels[0].1, switchHangs: true))
    Task { await switching.switchTo("work") }
    while switching.phase == .idle { await Task.yield() }
    try render(PopoverView(appState: switching, openSettings: { _ in }, close: {}), "popover-switching")

    let refused = await state(FixtureRunner(usage: usageLevels[0].1, usageFails: true, switchRefusal: "refusing to switch: the signed-in login was never saved (claude-multipass save <name>), or --force"))
    await refused.switchTo("work")
    try render(PopoverView(appState: refused, openSettings: { _ in }, close: {}), "popover-error")

    try render(PopoverView(appState: await state(nil), openSettings: { _ in }, close: {}), "popover-cli-missing")
    try render(PopoverView(appState: await state(FixtureRunner(versionFails: true)), openSettings: { _ in }, close: {}), "popover-cli-failed")
  }

  @Test func popoverUpdate() async throws {
    let s = await state(FixtureRunner(usage: usageLevels[0].1))
    let available = updateController(s)
    await available.check()
    try render(PopoverView(appState: s, openSettings: { _ in }, close: {}, updates: available), "popover-update-available")
    let current = updateController(s, feed: .success(nil))
    await current.check()
    try render(PopoverView(appState: s, openSettings: { _ in }, close: {}, updates: current), "popover-update-none")
  }

  @Test func aboutUpdate() async throws {
    _ = NSApplication.shared
    let height = { (appState: AppState, updates: UpdateController?, name: String) async throws -> CGFloat in
      var height: CGFloat = 0
      for dark in [false, true] {
        let controller = SettingsWindowController(appState: appState, updates: updates)
        controller.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        controller.show(pane: .about)
        try await Task.sleep(nanoseconds: 500_000_000)
        try write(try #require(controller.window.contentView?.superview), "\(name)-\(dark ? "dark" : "light")")
        height = controller.window.frame.height
        controller.window.close()
      }
      return height
    }
    let base = try await height(await state(FixtureRunner()), nil, "about-update-none")
    var heights: [String: CGFloat] = [:]
    for name in ["idle", "upToDate", "available", "availableBrew", "noBrew", "failedCheck", "installing", "failedBrew", "failedSparkle"] {
      let (appState, updates) = await updateFixture(name)
      let grown = try await height(appState, updates, "about-update-\(name)")
      heights[name] = grown
      #expect(grown > base, "\(name) did not grow the About tab")
      #expect(grown < 800, "\(name) can push the window off a laptop screen")
    }
    #expect(heights["available"]! >= heights["upToDate"]! + 100, "the change log collapsed")
  }

  @Test func turningTheDailyCheckOnChecks() async throws {
    _ = NSApplication.shared
    let s = await state(FixtureRunner())
    var settings = s.settings
    settings.updateChecksEnabled = false
    await s.apply(settings)
    let updates = updateController(s)
    let controller = SettingsWindowController(appState: s, updates: updates)
    controller.show(pane: .about)
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(updates.state == .idle)
    settings.updateChecksEnabled = true
    await s.apply(settings)
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(updates.state.offer != nil, "turning the toggle on did not check")
    updates.stop()
    controller.window.close()
  }

  @Test func accountDetail() throws {
    let now = Date()
    let five = UsageWindow(utilization: 77, resetsAt: now.addingTimeInterval(2 * 3600 + 24 * 60))
    let week = UsageWindow(utilization: 40, resetsAt: now.addingTimeInterval(3 * 86400 + 3600))
    let fable = { ScopedWindow(name: "Fable", utilization: $0, resetsAt: week.resetsAt) }
    let cases = [
      ("max", UsageEntry(name: "work", plan: "Max", fiveHour: five, sevenDay: week)),
      ("ultra", UsageEntry(name: "matherly", plan: "Ultra", ultra: true, sevenDay: week, scoped: [fable(4)])),
      ("fable-full", UsageEntry(name: "matherly-gmail", plan: "Max", fiveHour: five, sevenDay: week, scoped: [fable(100)])),
      ("error", UsageEntry(name: "max-plan", plan: "Max", error: "HTTP 429")),
    ]
    for (label, entry) in cases {
      try render(AccountDetail(name: entry.name, entry: entry, now: now), "account-detail-\(label)")
    }
  }

  @Test func settings() async throws {
    _ = NSApplication.shared
    let s = await state(FixtureRunner(usage: usageLevels[1].1))
    var custom = s.settings
    custom.cliPathOverride = "/Users/me/dev/claude-multipass/bin/claude-multipass"
    for (suffix, settings) in [("", s.settings), ("-custom", custom)] {
      await s.apply(settings)
      for dark in [false, true] {
        let controller = SettingsWindowController(appState: s)
        controller.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for pane in SettingsPane.allCases where suffix.isEmpty || pane == .general {
          controller.show(pane: pane)
          try await Task.sleep(nanoseconds: 400_000_000)
          #expect(!(controller.window.firstResponder is NSText), "the path field took focus on open")
          let frame = try #require(controller.window.contentView?.superview)
          try write(frame, "settings-\(pane.title.lowercased().replacingOccurrences(of: " ", with: "-"))\(suffix)-\(dark ? "dark" : "light")")
        }
        if !suffix.isEmpty {
          let tabs = try #require(controller.window.contentViewController as? NSTabViewController)
          controller.show(pane: .usage)
          tabs.selectedTabViewItemIndex = SettingsPane.general.rawValue
          try await Task.sleep(nanoseconds: 400_000_000)
          #expect(!(controller.window.firstResponder is NSText), "the path field took focus on a tab switch")
        }
        controller.window.close()
      }
    }

    await s.apply(AppSettings())
    let controller = SettingsWindowController(appState: s)
    controller.window.appearance = NSAppearance(named: .aqua)
    controller.show(pane: .general)
    try await Task.sleep(nanoseconds: 400_000_000)
    let before = controller.window.frame.height
    await s.apply(custom)
    try await Task.sleep(nanoseconds: 400_000_000)
    #expect(controller.window.frame.height > before, "the General tab did not grow for the path field")
    try write(try #require(controller.window.contentView?.superview), "settings-general-grown-light")
    controller.window.close()
  }
}
