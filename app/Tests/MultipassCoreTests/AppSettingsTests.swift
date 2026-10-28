import Foundation
import MultipassCore
import Testing

private func decode(_ json: String) throws -> AppSettings {
  try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
}

@Test func defaults() {
  let s = AppSettings()
  #expect(s.usageEnabled == false)
  #expect(s.usageIntervalMinutes == 15)
  #expect(s.stripStyle == .ringAndName)
  #expect(s.cliPathOverride == nil)
  #expect(AppSettings.snapshotInterval == 30)
}

@Test func emptyObjectDecodesToDefaults() throws {
  #expect(try decode("{}") == AppSettings())
}

@Test func partialObjectKeepsOtherDefaults() throws {
  var expected = AppSettings()
  expected.cliPathOverride = "/x"
  #expect(try decode(#"{"cliPathOverride":"/x"}"#) == expected)
}

@Test func intervalRoundsDownToAllowed() throws {
  #expect(try decode(#"{"usageIntervalMinutes":7}"#).usageIntervalMinutes == 5)
  #expect(try decode(#"{"usageIntervalMinutes":10}"#).usageIntervalMinutes == 5)
  #expect(try decode(#"{"usageIntervalMinutes":45}"#).usageIntervalMinutes == 30)
  #expect(try decode(#"{"usageIntervalMinutes":90}"#).usageIntervalMinutes == 60)
  #expect(try decode(#"{"usageIntervalMinutes":1}"#).usageIntervalMinutes == 5)
  #expect(try decode(#"{"usageIntervalMinutes":60}"#).usageIntervalMinutes == 60)
}

@Test func stripStyleDecodes() throws {
  #expect(try decode(#"{"stripStyle":"ringOnly"}"#).stripStyle == .ringOnly)
  #expect(try decode(#"{"stripStyle":"name"}"#).stripStyle == .name)
  #expect(try decode(#"{"stripStyle":"bogus"}"#).stripStyle == .ringAndName)
}

@Test func oldModuleListMapsToAStripStyle() throws {
  #expect(try decode(#"{"enabledModules":["account"]}"#).stripStyle == .name)
  #expect(try decode(#"{"enabledModules":[]}"#).stripStyle == .name)
  #expect(try decode(#"{"enabledModules":["account","bogus"]}"#).stripStyle == .name)
  #expect(try decode(#"{"enabledModules":["account","weeklyBar"]}"#).stripStyle == .ringAndName)
  #expect(try decode(#"{"enabledModules":["sessionReset"]}"#).stripStyle == .ringAndName)
  #expect(try decode(#"{"enabledModules":["account"],"stripStyle":"ringOnly"}"#).stripStyle == .ringOnly)
}

@Test func encodingDropsTheOldModuleList() throws {
  var s = try decode(#"{"enabledModules":["account"]}"#)
  s.usageEnabled = true
  let text = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
  #expect(!text.contains("enabledModules"))
  #expect(try decode(text) == s)
}

@Test func roundTripsThroughUserDefaults() throws {
  let suite = "net.matherly.claude-multipass.tests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let store = SettingsStore(defaults: defaults)
  #expect(store.load() == AppSettings())
  var s = AppSettings()
  s.usageEnabled = true
  s.usageIntervalMinutes = 30
  s.stripStyle = .name
  s.cliPathOverride = "/repo/bin/claude-multipass"
  store.save(s)
  #expect(store.load() == s)
  #expect(defaults.string(forKey: "settings") != nil)
}

@Test func stringWrittenByDefaultsCommandLoads() throws {
  let suite = "net.matherly.claude-multipass.tests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(#"{"cliPathOverride":"/repo/bin/claude-multipass"}"#, forKey: "settings")
  let s = SettingsStore(defaults: defaults).load()
  #expect(s.cliPathOverride == "/repo/bin/claude-multipass")
  #expect(s.usageIntervalMinutes == 15)
  defaults.set("not json", forKey: "settings")
  #expect(SettingsStore(defaults: defaults).load() == AppSettings())
}
