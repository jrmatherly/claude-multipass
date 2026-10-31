import Foundation
import MultipassCore
import Testing

@Test func percentFloorsAndDashesNil() {
  #expect(Format.percent(nil) == "–")
  #expect(Format.percent(42.6) == "42%")
  #expect(Format.percent(0) == "0%")
  #expect(Format.percent(130) == "130%")
}

@Test func fillClamps() {
  #expect(Format.fill(nil) == 0)
  #expect(Format.fill(50) == 0.5)
  #expect(Format.fill(130) == 1)
  #expect(Format.fill(-5) == 0)
}

@Test func levelsFloorAtSeventyAndNinety() {
  #expect(Format.level(nil) == .normal)
  #expect(Format.level(0) == .normal)
  #expect(Format.level(69.9) == .normal)
  #expect(Format.level(70) == .warning)
  #expect(Format.level(89.9) == .warning)
  #expect(Format.level(90.0) == .danger)
  #expect(Format.level(90.9) == .danger)
  #expect(Format.level(130) == .danger)
}

@Test func resetTimeIsTheWeekdayAndClockTime() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
  let locale = Locale(identifier: "en_GB")
  // 2026-10-27 is a Tuesday.
  let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12)))
  func at(_ seconds: TimeInterval) -> String? { Format.resetTime(now.addingTimeInterval(seconds), now: now, calendar: calendar, locale: locale) }
  #expect(Format.resetTime(nil, now: now, calendar: calendar, locale: locale) == nil)
  #expect(at(-60) == nil)
  #expect(at(0) == nil)
  #expect(at(3600) == "Tue 13:00")
  #expect(at(2 * 86400 + 1800) == "Thu 12:30")
  // A week on shares today's weekday, so it must not read as today.
  #expect(at(7 * 86400) == "7d 0h")
  #expect(at(6 * 86400 + 23 * 3600) == "6d 23h")
  #expect(Format.resetTime(now.addingTimeInterval(3600), now: now, calendar: calendar, locale: Locale(identifier: "en_US")) == "Tue 1:00\u{202F}PM")
  // The weekday and the clock both follow the calendar's time zone.
  calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
  #expect(Format.resetTime(now.addingTimeInterval(2 * 86400), now: now, calendar: calendar, locale: locale) == "Fri 2:00")
}

@Test func agoBuckets() {
  let now = Date(timeIntervalSince1970: 1_000_000)
  #expect(Format.ago(now, now: now) == "just now")
  #expect(Format.ago(now.addingTimeInterval(-59), now: now) == "just now")
  #expect(Format.ago(now.addingTimeInterval(-60), now: now) == "1 min ago")
  #expect(Format.ago(now.addingTimeInterval(-59 * 60), now: now) == "59 min ago")
  #expect(Format.ago(now.addingTimeInterval(-2 * 3600 - 60), now: now) == "2 h ago")
}

@Test func accountPeakPicksTheFullerAccountWindow() {
  #expect(UsageEntry(name: "a").accountPeak == nil)
  let five = UsageEntry(name: "a", fiveHour: UsageWindow(utilization: 38)).accountPeak
  #expect(five?.window == "5-hour" && five?.utilization == 38)
  let seven = UsageEntry(name: "a", sevenDay: UsageWindow(utilization: 73)).accountPeak
  #expect(seven?.window == "weekly" && seven?.utilization == 73)
  let both = UsageEntry(name: "a", fiveHour: UsageWindow(utilization: 91), sevenDay: UsageWindow(utilization: 73)).accountPeak
  #expect(both?.window == "5-hour" && both?.utilization == 91)
  let tie = UsageEntry(name: "a", fiveHour: UsageWindow(utilization: 50), sevenDay: UsageWindow(utilization: 50)).accountPeak
  #expect(tie?.window == "weekly")
}

@Test func accountPeakIgnoresScopedLimits() {
  let entry = UsageEntry(
    name: "a", fiveHour: UsageWindow(utilization: 17), sevenDay: UsageWindow(utilization: 59),
    scoped: [ScopedWindow(name: "Fable", utilization: 100)])
  #expect(entry.accountPeak?.window == "weekly" && entry.accountPeak?.utilization == 59)
  #expect(UsageEntry(name: "a", scoped: [ScopedWindow(name: "Fable", utilization: 100)]).accountPeak == nil)
}

@Test func accountPeakIgnoresAnUltraFiveHourFigure() {
  let weekly = UsageEntry(name: "a", ultra: true, fiveHour: UsageWindow(utilization: 90), sevenDay: UsageWindow(utilization: 10)).accountPeak
  #expect(weekly?.window == "weekly" && weekly?.utilization == 10)
  #expect(UsageEntry(name: "a", ultra: true, fiveHour: UsageWindow(utilization: 90)).accountPeak == nil)
}

@Test func modelPeakPicksTheFullestScopedLimit() {
  #expect(UsageEntry(name: "a", sevenDay: UsageWindow(utilization: 59)).modelPeak == nil)
  #expect(UsageEntry(name: "a", scoped: []).modelPeak == nil)
  let entry = UsageEntry(
    name: "a", sevenDay: UsageWindow(utilization: 99),
    scoped: [ScopedWindow(name: "Fable", utilization: 40), ScopedWindow(name: "Opus", utilization: 73), ScopedWindow(name: "Sonnet", utilization: 12)])
  #expect(entry.modelPeak == 73)
}

@Test func accountIsFullFloorsTheAccountFigure() {
  #expect(!UsageEntry(name: "a").accountIsFull)
  #expect(!UsageEntry(name: "a", sevenDay: UsageWindow(utilization: 99.9)).accountIsFull)
  #expect(UsageEntry(name: "a", sevenDay: UsageWindow(utilization: 100)).accountIsFull)
  #expect(UsageEntry(name: "a", fiveHour: UsageWindow(utilization: 100), sevenDay: UsageWindow(utilization: 59)).accountIsFull)
  #expect(!UsageEntry(name: "a", ultra: true, fiveHour: UsageWindow(utilization: 100), sevenDay: UsageWindow(utilization: 59)).accountIsFull)
  #expect(!UsageEntry(name: "a", sevenDay: UsageWindow(utilization: 59), scoped: [ScopedWindow(name: "Fable", utilization: 100)]).accountIsFull)
}

@Test func limitsSummaryListsTheAccountThenEveryScopedLimit() {
  #expect(UsageEntry(name: "a").limitsSummary == nil)
  #expect(UsageEntry(name: "a", sevenDay: UsageWindow(utilization: 73.4)).limitsSummary == "weekly 73%")
  let all = UsageEntry(
    name: "a", fiveHour: UsageWindow(utilization: 17), sevenDay: UsageWindow(utilization: 59),
    scoped: [ScopedWindow(name: "Opus", utilization: 12), ScopedWindow(name: "Fable", utilization: 100)])
  #expect(all.limitsSummary == "weekly 59%, Opus weekly 12%, Fable weekly 100%")
  #expect(UsageEntry(name: "a", scoped: [ScopedWindow(name: "Fable", utilization: 40)]).limitsSummary == "Fable weekly 40%")
}

@Test func countdownBuckets() {
  let now = Date(timeIntervalSince1970: 1_000_000)
  func at(_ seconds: TimeInterval) -> String { Format.countdown(to: now.addingTimeInterval(seconds), now: now) }
  #expect(Format.countdown(to: nil, now: now) == "–")
  #expect(at(-1) == "–")
  #expect(at(0) == "–")
  #expect(at(30) == "0m")
  #expect(at(14 * 60) == "14m")
  #expect(at(59 * 60) == "59m")
  #expect(at(60 * 60) == "1h 0m")
  #expect(at(2 * 3600 + 14 * 60) == "2h 14m")
  #expect(at(23 * 3600 + 59 * 60) == "23h 59m")
  #expect(at(24 * 3600) == "1d 0h")
  #expect(at(4 * 86400 + 6 * 3600 + 59 * 60) == "4d 6h")
}

@Test func displayNameStates() {
  #expect(Format.displayName(nil, signedIn: false) == "signed out")
  #expect(Format.displayName(nil, signedIn: true) == "not saved")
  #expect(Format.displayName("work", signedIn: true) == "work")
  #expect(Format.displayName("sixteen-chars-ab", signedIn: true) == "sixteen-chars-ab")
  #expect(Format.displayName("seventeen-chars-a", signedIn: true) == "seventeen-chars…")
  #expect(Format.displayName("seventeen-chars-a", signedIn: true).count == 16)
}

@Test func profileNameRule() {
  #expect(isValidProfileName("work-2"))
  #expect(isValidProfileName("a.b_c"))
  #expect(!isValidProfileName(""))
  #expect(!isValidProfileName("."))
  #expect(!isValidProfileName(".."))
  #expect(!isValidProfileName(".foo"))
  #expect(!isValidProfileName("a b"))
  #expect(!isValidProfileName("a/b"))
  #expect(!isValidProfileName("é"))
}
