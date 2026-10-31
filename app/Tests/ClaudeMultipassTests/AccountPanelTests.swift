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

  @Test func noPanelIsMadeWithoutFigures() async {
    let controller = AccountPanelController(appState: await state(FixtureRunner(usage: usage)), showDelay: 0)
    controller.rowHover(name: "max-plan", inside: true, frame: .zero)
    await settle { controller.hover.shown != nil }
    #expect(controller.hover.shown == "max-plan")
    #expect(controller.panel == nil)
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
    while s.phase == .idle { await Task.yield() }
    #expect(!row(expanded: false).offersDetail)
    running.cancel()
  }
}
