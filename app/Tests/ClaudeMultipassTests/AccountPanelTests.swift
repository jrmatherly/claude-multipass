import AppKit
import MultipassCore
import SwiftUI
import Testing

@testable import ClaudeMultipass

@MainActor private func settle(until done: () -> Bool) async {
  for _ in 0..<1000 where !done() {
    try? await Task.sleep(nanoseconds: 1_000_000)
  }
}

@MainActor struct AccountHoverTests {
  private final class Log {
    var changes: [String?] = []
  }

  private func hover(show: TimeInterval = 0, hide: TimeInterval = 0) -> (AccountHover, Log) {
    let log = Log()
    return (AccountHover(showDelay: show, hideDelay: hide) { log.changes.append($0) }, log)
  }

  private func shown(_ name: String, _ hover: AccountHover) async {
    hover.entered(name)
    await settle { hover.shown == name }
  }

  @Test func theFirstEnterShowsOnlyAfterTheDelay() async {
    let (hover, log) = hover()
    hover.entered("work")
    #expect(hover.shown == nil)
    await settle { hover.shown != nil }
    #expect(hover.shown == "work")
    #expect(log.changes == ["work"])
  }

  @Test func sweepingRowsDuringTheDelayShowsOnlyTheLast() async throws {
    let (hover, log) = hover(show: 0.02)
    hover.entered("work")
    hover.entered("max-plan")
    hover.left("work")
    try await Task.sleep(nanoseconds: 80_000_000)
    #expect(log.changes == ["max-plan"])
  }

  @Test func movingToAnotherRowWhileShownSwitchesAtOnce() async {
    let (hover, _) = hover(show: 0)
    await shown("work", hover)
    hover.entered("max-plan")
    #expect(hover.shown == "max-plan")
  }

  @Test func aStaleExitAfterTheNextRowsEnterDoesNotHide() async throws {
    let (hover, log) = hover()
    await shown("work", hover)
    hover.entered("max-plan")
    hover.left("work")
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(hover.shown == "max-plan")
    #expect(log.changes == ["work", "max-plan"])
  }

  @Test func leavingShownRowHidesAfterTheDelay() async {
    let (hover, log) = hover()
    await shown("work", hover)
    hover.left("work")
    #expect(hover.shown == "work")
    await settle { hover.shown == nil }
    #expect(hover.shown == nil)
    #expect(log.changes == ["work", nil])
  }

  @Test func reEnteringBeforeTheHideDelayKeepsThePanel() async throws {
    let (hover, log) = hover(hide: 0.02)
    await shown("work", hover)
    hover.left("work")
    hover.entered("work")
    try await Task.sleep(nanoseconds: 60_000_000)
    #expect(hover.shown == "work")
    #expect(log.changes == ["work"])
  }

  @Test func leavingBeforeTheShowDelayNeverShows() async throws {
    let (hover, log) = hover(show: 0.02)
    hover.entered("work")
    hover.left("work")
    #expect(hover.shown == nil)
    try await Task.sleep(nanoseconds: 60_000_000)
    #expect(hover.shown == nil)
    #expect(log.changes.isEmpty)
  }

  @Test func dismissClearsAndCancelsAPendingShow() async throws {
    let (hover, log) = hover(show: 0.02)
    hover.entered("work")
    hover.dismiss()
    try await Task.sleep(nanoseconds: 60_000_000)
    #expect(hover.shown == nil)
    #expect(log.changes.isEmpty)

    let (open, openLog) = self.hover()
    await shown("work", open)
    open.dismiss()
    #expect(open.shown == nil)
    #expect(openLog.changes == ["work", nil])
  }

  @Test func changeFiresOnlyOnAChange() async {
    let (hover, log) = hover()
    await shown("work", hover)
    hover.entered("work")
    hover.dismiss()
    hover.dismiss()
    #expect(log.changes == ["work", nil])
  }
}

@MainActor struct AccountPanelTests {
  private let screen = CGRect(x: 0, y: 25, width: 1000, height: 800)
  private let size = CGSize(width: 260, height: 200)
  private let popover = CGRect(x: 500, y: 300, width: 320, height: 500)

  @Test func thePanelSitsLeftOfThePopoverLevelWithTheRow() {
    let row = CGRect(x: 514, y: 500, width: 292, height: 40)
    #expect(AccountPanelController.origin(size: size, popover: popover, row: row, screen: screen) == CGPoint(x: 232, y: 340))
  }

  @Test func thePanelFlipsRightWithNoRoomOnTheLeft() {
    let near = CGRect(x: 100, y: 300, width: 320, height: 500)
    let row = CGRect(x: 114, y: 500, width: 292, height: 40)
    #expect(AccountPanelController.origin(size: size, popover: near, row: row, screen: screen).x == 428)
  }

  @Test func theFlipUsesTheEdgeOfADisplayThatIsNotAtZero() {
    let second = CGRect(x: 1440, y: 0, width: 1000, height: 800)
    let near = CGRect(x: 1500, y: 300, width: 320, height: 500)
    let row = CGRect(x: 1514, y: 500, width: 292, height: 40)
    #expect(AccountPanelController.origin(size: size, popover: near, row: row, screen: second).x == 1828)
  }

  @Test func thePanelStaysInsideTheScreen() {
    let low = CGRect(x: 514, y: 60, width: 292, height: 40)
    #expect(AccountPanelController.origin(size: size, popover: popover, row: low, screen: screen).y == 25)
    let high = CGRect(x: 514, y: 900, width: 292, height: 40)
    #expect(AccountPanelController.origin(size: size, popover: popover, row: high, screen: screen).y == 625)
  }

  @Test func thePlanLineJoinsWhicheverExist() throws {
    let now = Date()
    let at = now.addingTimeInterval(2 * 86400)
    let reset = try #require(Format.resetTime(at, now: now))
    let week = UsageWindow(utilization: 40, resetsAt: at)
    #expect(UsageEntry(name: "a", plan: "Max", sevenDay: week).planLine(now: now) == "Max · resets \(reset)")
    #expect(UsageEntry(name: "a", plan: "Max").planLine(now: now) == "Max")
    #expect(UsageEntry(name: "a", sevenDay: week).planLine(now: now) == "resets \(reset)")
    #expect(UsageEntry(name: "a", sevenDay: UsageWindow(utilization: 40)).planLine(now: now) == nil)
  }

  private func label(_ fields: String) async throws -> String {
    let s = await state(FixtureRunner(usage: #"{"profiles":[{"name":"work",\#(fields)}]}"#))
    let profile = try #require(s.snapshot?.profiles.first { $0.name == "work" })
    return AccountRow(appState: s, profile: profile, isExpanded: false, onTap: {}, onCancel: {}, onSwitch: { _ in }).usageLabel
  }

  @Test func theRowLabelCarriesTheResetsForVoiceOver() async throws {
    let iso = ISO8601DateFormatter()
    let fiveAt = Date().addingTimeInterval(3 * 3600 + 30)
    let weekAt = Date().addingTimeInterval(2 * 86400)
    let weekReset = try #require(Format.resetTime(weekAt, now: Date()))
    let five = #""fiveHour":{"utilization":17,"resetsAt":"\#(iso.string(from: fiveAt))"}"#
    let week = #""sevenDay":{"utilization":59,"resetsAt":"\#(iso.string(from: weekAt))"}"#
    #expect(try await label("\(five),\(week)") == "weekly 59%, 5-hour resets 3h 0m, weekly resets \(weekReset)")
    #expect(try await label(#""ultra":true,\#(week)"#) == "weekly 59%, weekly resets \(weekReset)")
    #expect(try await label(#""ultra":true,\#(five),\#(week)"#) == "weekly 59%, weekly resets \(weekReset)")
    #expect(try await label(#""fiveHour":{"utilization":17},"sevenDay":{"utilization":59}"#) == "weekly 59%")
    #expect(try await label(#"\#(five),\#(week),"error":"HTTP 429""#) == "HTTP 429")
  }

  @Test func anExpiredFiveHourResetIsNotRead() {
    let now = Date()
    let entry = UsageEntry(name: "a", fiveHour: UsageWindow(utilization: 17, resetsAt: now.addingTimeInterval(-60)))
    #expect(entry.resetLabels(now: now).isEmpty)
  }

  private let usage = #"{"profiles":[{"name":"work","plan":"Max","sevenDay":{"utilization":59}}]}"#

  @Test func thePanelOnlyHasFiguresWithUsageOnAndAnEntry() async {
    let s = await state(FixtureRunner(usage: usage))
    let controller = AccountPanelController(appState: s)
    await s.refreshUsage()
    #expect(controller.detailEntry(for: "work")?.plan == "Max")
    #expect(controller.detailEntry(for: "max-plan") == nil)
    var off = s.settings
    off.usageEnabled = false
    await s.apply(off)
    #expect(s.usage["work"] != nil)
    #expect(controller.detailEntry(for: "work") == nil)
  }

  /// Far off every screen, so the gate flashes nothing.
  private func offScreenHost() -> (NSView, NSWindow) {
    let frame = CGRect(x: -20000, y: 200, width: 320, height: 500)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSView(frame: CGRect(origin: .zero, size: frame.size))
    window.contentView = host
    return (host, window)
  }

  @Test func thePanelShowsLevelWithItsRowAndHidesWithoutFigures() async throws {
    let s = await state(FixtureRunner(usage: usage))
    await s.refreshUsage()
    let controller = AccountPanelController(appState: s, showDelay: 0)
    let (host, window) = offScreenHost()
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    controller.host = host
    let row = CGRect(x: 14, y: 100, width: 292, height: 40)

    controller.rowHover(name: "work", inside: true, frame: row)
    await settle { controller.panel?.isVisible == true }
    let panel = try #require(controller.panel)
    #expect(panel.isVisible)
    #expect(panel.ignoresMouseEvents)
    #expect(!panel.canBecomeKey)
    #expect(panel.parent == nil, "performClose does nothing on a popover whose window has a child")
    #expect(panel.frame.maxY == window.frame.maxY - row.minY)

    controller.rowHover(name: "max-plan", inside: true, frame: row)
    #expect(!panel.isVisible, "a row with no figures must not keep the last row's")
    controller.rowHover(name: "work", inside: true, frame: row)
    #expect(panel.isVisible)
    #expect(controller.panel === panel)

    controller.dismiss()
    #expect(!panel.isVisible)
  }

  @Test func noPanelOpensBesideAClosedPopover() async {
    let s = await state(FixtureRunner(usage: usage))
    await s.refreshUsage()
    let controller = AccountPanelController(appState: s, showDelay: 0)
    let (host, _) = offScreenHost()
    controller.host = host
    controller.rowHover(name: "work", inside: true, frame: .zero)
    await settle { controller.hover.shown != nil }
    #expect(controller.hover.shown == "work")
    #expect(controller.panel == nil)
  }

  @Test func aRefreshFollowsTheFigures() async throws {
    let s = await state(FixtureRunner(usage: usage))
    await s.refreshUsage()
    let controller = AccountPanelController(appState: s, showDelay: 0)
    let (host, window) = offScreenHost()
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    controller.host = host
    controller.rowHover(name: "work", inside: true, frame: .zero)
    await settle { controller.panel?.isVisible == true }
    let panel = try #require(controller.panel)

    var off = s.settings
    off.usageEnabled = false
    await s.apply(off)
    controller.refresh()
    #expect(!panel.isVisible, "figures that went away must leave the panel")

    off.usageEnabled = true
    await s.apply(off)
    controller.refresh()
    #expect(panel.isVisible, "figures that arrive must reach a row still hovered")
    controller.dismiss()
  }

  @Test func anLLMRRowShowsTheTerminalHintAndNoUsage() async throws {
    let s = await state(FixtureRunner(usage: usage))
    #expect(s.settings.usageEnabled)
    let llmr = Profile(name: "router", account: "", savedAt: nil, sessions: 0, kind: "llmr", llmrProfile: "router-p")
    let row = AccountRow(appState: s, profile: llmr, isExpanded: false, onTap: {}, onCancel: {}, onSwitch: { _ in })
    #expect(row.subtitle == "terminal: run llmr router-p")
    #expect(!row.showsUsage)
    #expect(!row.offersDetail)
    let work = try #require(s.snapshot?.profiles.first { $0.name == "work" })
    #expect(AccountRow(appState: s, profile: work, isExpanded: false, onTap: {}, onCancel: {}, onSwitch: { _ in }).showsUsage)
  }

  @Test func aRowOffersItsDetailOnlyWhenIdleWithNoConfirm() async throws {
    let s = await state(FixtureRunner(usage: usage, switchHangs: true))
    let profile = try #require(s.snapshot?.profiles.first { $0.name == "work" })
    func row(expanded: Bool) -> AccountRow {
      AccountRow(appState: s, profile: profile, isExpanded: expanded, onTap: {}, onCancel: {}, onSwitch: { _ in })
    }
    #expect(row(expanded: false).offersDetail)
    #expect(!row(expanded: true).offersDetail)
    let running = Task { await s.switchTo("work") }
    await settle { s.phase != .idle }
    #expect(!row(expanded: false).offersDetail)
    running.cancel()
  }
}
