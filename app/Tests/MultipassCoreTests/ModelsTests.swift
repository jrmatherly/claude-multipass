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
