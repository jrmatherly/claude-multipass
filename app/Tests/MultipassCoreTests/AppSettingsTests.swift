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
  #expect(s.enabledModules == [.account])
  #expect(s.cliPathOverride == nil)
  #expect(AppSettings.snapshotInterval == 30)
}

@Test func visibleModulesHideUsageWhenOff() {
  var s = AppSettings()
  s.enabledModules = Set(Module.allCases)
  #expect(s.visibleModules == [.account])
  s.usageEnabled = true
  #expect(s.visibleModules == Module.allCases)
  s.enabledModules = [.weeklyBar, .account]
  #expect(s.visibleModules == [.account, .weeklyBar])
}

@Test func moduleLabels() {
  #expect(Module.allCases.map(\.label) == ["@", "5H", "7D", "5H↻", "7D↻"])
  #expect(Module.allCases.map(\.needsUsage) == [false, true, true, true, true])
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

@Test func unknownModuleIsDropped() throws {
  #expect(try decode(#"{"enabledModules":["account","bogus","weeklyBar"]}"#).enabledModules == [.account, .weeklyBar])
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
  s.enabledModules = [.account, .sessionBar]
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
