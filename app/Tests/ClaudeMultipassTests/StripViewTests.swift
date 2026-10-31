import AppKit
import MultipassCore
import SwiftUI
import Testing

@testable import ClaudeMultipass

/// What the strip shows from a usage report. These run in the gate; Shots only draws.
@MainActor struct StripViewTests {
  private let name = "matherly-gmail"
  private let fableFull = mixedJSON(five: 17, seven: 59, fable: 100)

  @Test func aFullModelLimitDoesNotReadAsAFullAccount() async {
    let strip = StripView(appState: await state(FixtureRunner(usage: fableFull)))
    #expect(strip.percentText == "59%")
    #expect(strip.gauge.account == 59)
    #expect(strip.gauge.model == 100)
    #expect(!strip.gauge.accountIsFull)
    #expect(strip.label == "\(name), weekly 59%, Fable weekly 100%")
  }

  @Test func aModelLimitAloneShowsNoAccountFigure() async {
    let usage = #"{"profiles":[{"name":"matherly-gmail","scoped":[{"name":"Fable","utilization":40}]}]}"#
    let strip = StripView(appState: await state(FixtureRunner(usage: usage)))
    #expect(strip.percentText == nil)
    #expect(strip.gauge.account == nil)
    #expect(strip.gauge.model == 40)
  }

  @Test func onlyTheRingAndNameStyleShowsThePercentage() async {
    for style in [StripStyle.ringOnly, .name] {
      let strip = StripView(appState: await state(FixtureRunner(usage: fableFull), style: style))
      #expect(strip.percentText == nil)
    }
  }

  // Turning usage off leaves the last report in AppState, so only the strip's gate hides it.
  @Test func turningUsageOffHidesTheFigures() async {
    let s = await state(FixtureRunner(usage: fableFull))
    var off = s.settings
    off.usageEnabled = false
    await s.apply(off)
    let strip = StripView(appState: s)
    #expect(s.currentUsage != nil)
    #expect(strip.percentText == nil)
    #expect(strip.gauge.account == nil)
    #expect(strip.gauge.model == nil)
    #expect(strip.label == name)
  }

  @Test func theInnerRingGoesGrayOnlyOnAFullAccount() {
    #expect(RingGauge(account: 100, model: 100, accountIsFull: true).modelColor == Color.primary.opacity(0.6))
    #expect(RingGauge(account: 59, model: 100, accountIsFull: false).modelColor == .red)
    #expect(RingGauge(account: 59, model: 75, accountIsFull: false).modelColor == .orange)
    #expect(RingGauge(account: 59, model: 40, accountIsFull: false).modelColor == .primary)
  }

  // A status item button is 22 pt tall (NSStatusBar.system.thickness, measured 2026-10-31).
  @Test func theStripFitsAStatusItemButton() async {
    for style in StripStyle.allCases {
      let s = await state(FixtureRunner(usage: fableFull), style: style)
      #expect(NSHostingView(rootView: StripView(appState: s)).fittingSize.height <= 22)
    }
  }

  private func row(_ usage: String, for account: String = "matherly-gmail") async throws -> AccountRow {
    let s = await state(FixtureRunner(usage: usage))
    let profile = try #require(s.snapshot?.profiles.first { $0.name == account })
    return AccountRow(appState: s, profile: profile, isExpanded: false, onTap: {}, onCancel: {}, onSwitch: { _ in })
  }

  @Test func aSwitchRowShowsTheAccountThenTheModelFigure() async throws {
    let row = try await row(fableFull)
    #expect(row.accountFigure == 59)
    #expect(row.modelFigure == 100)
    #expect(row.modelBarColor == .red)
    #expect(row.usageLabel == "weekly 59%, Fable weekly 100%")
  }

  @Test func aSwitchRowReadsItsOwnAccount() async throws {
    let usage = #"{"profiles":[{"name":"matherly-gmail","sevenDay":{"utilization":12}},{"name":"work","fiveHour":{"utilization":10},"sevenDay":{"utilization":59},"scoped":[{"name":"Fable","utilization":75}]}]}"#
    let row = try await row(usage, for: "work")
    #expect(row.accountFigure == 59)
    #expect(row.modelFigure == 75)
    #expect(row.modelBarColor == .orange)
    #expect(row.usageLabel == "weekly 59%, Fable weekly 75%")
  }

  @Test func aSwitchRowModelBarUsesTheAccentBelowTheWarning() async throws {
    #expect(try await row(mixedJSON(five: 17, seven: 59, fable: 40)).modelBarColor == .accentColor)
  }

  @Test func aUsageBarFillsWithItsColorOrItsLevel() {
    #expect(UsageBar(utilization: 100, height: 4).fillColor == .red)
    #expect(UsageBar(utilization: 100, height: 4, color: .gray).fillColor == .gray)
  }

  @Test func aSwitchRowShowsAFullFiveHourLimit() async throws {
    let row = try await row(mixedJSON(five: 100, seven: 59, fable: 40))
    #expect(row.accountFigure == 100)
    #expect(row.modelBarColor == Color.primary.opacity(0.6))
  }

  @Test func aSwitchRowWithoutAModelLimitHasOneFigure() async throws {
    let row = try await row(#"{"profiles":[{"name":"matherly-gmail","sevenDay":{"utilization":52}}]}"#)
    #expect(row.accountFigure == 52)
    #expect(row.modelFigure == nil)
  }

  @Test func aSwitchRowWithNoEntrySaysSo() async throws {
    let row = try await row(#"{"profiles":[]}"#)
    #expect(row.accountFigure == nil)
    #expect(row.usageLabel == "No usage figures yet")
  }

  @Test func aSwitchRowLabelPrefersTheFetchError() async throws {
    let row = try await row(#"{"profiles":[{"name":"matherly-gmail","sevenDay":{"utilization":59},"error":"HTTP 429"}]}"#)
    #expect(row.usageLabel == "HTTP 429")
  }

  @Test func theHeaderJoinsThePlanAndTheWeeklyReset() async throws {
    let at = Date().addingTimeInterval(2 * 86400)
    let reset = ISO8601DateFormatter().string(from: at)
    let expected = try #require(Format.resetTime(at, now: Date()))
    func popover(_ fields: String) async -> PopoverView {
      let usage = #"{"profiles":[{"name":"matherly-gmail",\#(fields)}]}"#
      return PopoverView(appState: await state(FixtureRunner(usage: usage)), openSettings: { _ in }, close: {})
    }
    let week = #""sevenDay":{"utilization":59,"resetsAt":"\#(reset)"}"#
    #expect(await popover(#""plan":"Ultra",\#(week)"#).planLine == "Ultra · resets \(expected)")
    #expect(await popover(week).planLine == "resets \(expected)")
    let five = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
    #expect(await popover(#""fiveHour":{"utilization":17,"resetsAt":"\#(five)"},\#(week)"#).planLine == "resets \(expected)")
    #expect(await popover(#""plan":"Ultra","sevenDay":{"utilization":59}"#).planLine == "Ultra")
    #expect(await popover(#""sevenDay":{"utilization":59}"#).planLine == nil)
  }

  @Test func theHeaderHidesThePlanLineWithUsageOff() async {
    let s = await state(FixtureRunner(usage: #"{"profiles":[{"name":"matherly-gmail","plan":"Ultra"}]}"#))
    let popover = PopoverView(appState: s, openSettings: { _ in }, close: {})
    #expect(popover.planLine == "Ultra")
    var off = s.settings
    off.usageEnabled = false
    await s.apply(off)
    #expect(popover.planLine == nil)
  }

  @Test func onlyTheFiveHourMeterNamesAReset() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let window = UsageWindow(utilization: 17, resetsAt: now.addingTimeInterval(3 * 3600))
    #expect(UsageMeter(title: "5-hour", window: window, now: now, showsReset: true).detail == "17% · resets 3h 0m")
    #expect(UsageMeter(title: "5-hour", window: UsageWindow(utilization: 17), now: now, showsReset: true).detail == "17%")
    #expect(UsageMeter(title: "Weekly", window: window, now: now).detail == "17%")
    #expect(UsageMeter(title: "Weekly", window: nil, now: now).detail == "–")
  }

  @Test func thePopoverListsMetersInOrderAndOnlyFiveHourNamesAReset() async {
    let s = await state(FixtureRunner(usage: fableFull))
    let popover = PopoverView(appState: s, openSettings: { _ in }, close: {})
    let fable = [ScopedWindow(name: "Fable", utilization: 100)]
    let now = Date()
    let max = popover.meters(for: UsageEntry(name: "a", scoped: fable), now: now)
    #expect(max.map(\.title) == ["5-hour", "Weekly · all models", "Weekly · Fable"])
    #expect(max.map(\.showsReset) == [true, false, false])
    let ultra = popover.meters(for: UsageEntry(name: "a", ultra: true, scoped: fable), now: now)
    #expect(ultra.map(\.title) == ["Weekly · all models", "Weekly · Fable"])
    let plain = popover.meters(for: UsageEntry(name: "a"), now: now)
    #expect(plain.map(\.title) == ["5-hour", "Weekly"])
  }
}
