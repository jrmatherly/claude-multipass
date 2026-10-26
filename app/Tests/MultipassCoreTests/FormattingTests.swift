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

@Test func dangerStartsAtFlooredNinety() {
  #expect(!Format.isDanger(nil))
  #expect(!Format.isDanger(89.9))
  #expect(Format.isDanger(90.0))
  #expect(Format.isDanger(90.9))
  #expect(Format.isDanger(130))
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
  #expect(!isValidProfileName("a b"))
  #expect(!isValidProfileName("a/b"))
  #expect(!isValidProfileName("é"))
}
