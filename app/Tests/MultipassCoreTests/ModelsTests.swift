import Foundation
import MultipassCore
import Testing

@Test func decodesSnapshot() throws {
  let json = #"{"version":"0.2.0","signedIn":true,"desktopRunning":false,"current":"beta","profiles":[{"name":"beta","account":"bbbbbbbb-2222","savedAt":"2026-01-01T00:00:00Z","sessions":4}]}"#
  let s = try MultipassJSON.decoder.decode(Snapshot.self, from: Data(json.utf8))
  #expect(s.current == "beta")
  #expect(s.profiles[0].sessions == 4)
  #expect(s.profiles[0].id == "beta")
  #expect(s.desktopRunning == false)
  #expect(s.profiles[0].savedAt == Date(timeIntervalSince1970: 1_767_225_600))
}

@Test func decodesCliSaved() throws {
  let json = #"{"version":"0.3.0","signedIn":true,"desktopRunning":false,"current":"beta","profiles":[{"name":"beta","account":"b","savedAt":"2026-01-01T00:00:00Z","sessions":4,"cliSaved":true}]}"#
  let s = try MultipassJSON.decoder.decode(Snapshot.self, from: Data(json.utf8))
  #expect(s.profiles[0].cliSaved == true)
}

@Test func cliSavedDefaultsToFalse() throws {
  let json = #"{"version":"0.2.0","signedIn":true,"desktopRunning":false,"current":"beta","profiles":[{"name":"beta","account":"b","savedAt":"2026-01-01T00:00:00Z","sessions":4}]}"#
  let s = try MultipassJSON.decoder.decode(Snapshot.self, from: Data(json.utf8))
  #expect(s.profiles[0].cliSaved == false)
}

@Test func decodesNullCurrent() throws {
  let json = #"{"version":"0.2.0","signedIn":true,"desktopRunning":true,"current":null,"profiles":[]}"#
  let s = try MultipassJSON.decoder.decode(Snapshot.self, from: Data(json.utf8))
  #expect(s.current == nil)
  #expect(s.signedIn)
  #expect(s.profiles.isEmpty)
}

@Test func decodesUsageEntries() throws {
  let json = #"{"profiles":[{"name":"usagey","fiveHour":{"utilization":42.6,"resetsAt":"2026-10-23T19:45:00Z"},"sevenDay":{"utilization":18}},{"name":"stale","error":"token expired, sign in and re-save"}]}"#
  let r = try MultipassJSON.decoder.decode(UsageReport.self, from: Data(json.utf8))
  #expect(r.profiles[0].fiveHour?.utilization == 42.6)
  #expect(r.profiles[0].fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_792_784_700))
  #expect(r.profiles[0].sevenDay?.resetsAt == nil)
  #expect(r.profiles[0].id == "usagey")
  #expect(r.profiles[1].error == "token expired, sign in and re-save")
  #expect(r.profiles[1].fiveHour == nil)
}

@Test func decodesPlanUltraAndScopedLimits() throws {
  let json = #"{"profiles":[{"name":"ultra","plan":"Ultra","ultra":true,"sevenDay":{"utilization":69},"scoped":[{"name":"Fable","utilization":96,"resetsAt":"2026-10-31T12:00:00Z"}]},{"name":"old","fiveHour":{"utilization":4}}]}"#
  let r = try MultipassJSON.decoder.decode(UsageReport.self, from: Data(json.utf8))
  #expect(r.profiles[0].plan == "Ultra")
  #expect(r.profiles[0].isUltra)
  #expect(r.profiles[0].fiveHour == nil)
  #expect(r.profiles[0].scoped == [ScopedWindow(name: "Fable", utilization: 96, resetsAt: Date(timeIntervalSince1970: 1_793_448_000))])
  // An older tool sends none of the new keys.
  #expect(r.profiles[1].plan == nil && !r.profiles[1].isUltra && r.profiles[1].scoped == nil)
}

@Test func anUnparsableScopedResetDropsOnlyThatReset() throws {
  let json = #"{"profiles":[{"name":"a","sevenDay":{"utilization":1},"scoped":[{"name":"Fable","utilization":5,"resetsAt":"2026-11-01T00:00:00+05:00"},{"name":"Fable","utilization":7}]}]}"#
  let r = try MultipassJSON.decoder.decode(UsageReport.self, from: Data(json.utf8))
  #expect(r.profiles[0].scoped == [ScopedWindow(name: "Fable", utilization: 5), ScopedWindow(name: "Fable", utilization: 7)])
}

@Test func decodesEmptyReport() throws {
  let r = try MultipassJSON.decoder.decode(UsageReport.self, from: Data(#"{"profiles":[]}"#.utf8))
  #expect(r.profiles == [])
}

@Test func rejectsOtherDateShapes() {
  let json = #"{"profiles":[{"name":"x","fiveHour":{"utilization":1,"resetsAt":"2026-10-23T19:45:00+00:00"}}]}"#
  #expect(throws: (any Error).self) {
    try MultipassJSON.decoder.decode(UsageReport.self, from: Data(json.utf8))
  }
}

@Test func savedAtIsLenient() throws {
  // A meta.json without savedAt reached the app as null, or as "null" from earlier tools.
  let json = #"{"version":"0.3.4","signedIn":true,"desktopRunning":false,"current":null,"profiles":[{"name":"a","account":"a","savedAt":null,"sessions":0},{"name":"b","account":"b","savedAt":"null","sessions":0},{"name":"c","account":"c","sessions":0}]}"#
  let s = try MultipassJSON.decoder.decode(Snapshot.self, from: Data(json.utf8))
  #expect(s.profiles.map(\.name) == ["a", "b", "c"])
  #expect(s.profiles.allSatisfy { $0.savedAt == nil })
}
