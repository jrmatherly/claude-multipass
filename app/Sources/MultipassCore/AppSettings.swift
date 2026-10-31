import Foundation

/// What the menu bar strip shows: a ring gauge of the signed-in account's
/// usage beside its name and percentage, the ring alone, or the name alone.
public enum StripStyle: String, CaseIterable, Codable {
  case name, ringAndName, ringOnly
}

public struct AppSettings: Equatable, Codable {
  public var usageEnabled = false
  public var usageIntervalMinutes = 15
  public var stripStyle = StripStyle.ringAndName
  public var cliPathOverride: String? = nil

  public static let snapshotInterval: TimeInterval = 30
  /// A Refresh click runs `usage` at once; a burst of clicks costs one run.
  public static let usageRefreshFloor: TimeInterval = 30
  public static let allowedIntervals = [5, 15, 30, 60]

  public init() {}

  private enum Keys: String, CodingKey { case usageEnabled, usageIntervalMinutes, stripStyle, enabledModules, cliPathOverride }

  /// Every key optional, so a partial blob seeded with `defaults write` loads.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    usageEnabled = try c.decodeIfPresent(Bool.self, forKey: .usageEnabled) ?? usageEnabled
    if let minutes = try c.decodeIfPresent(Int.self, forKey: .usageIntervalMinutes) {
      usageIntervalMinutes = Self.allowedIntervals.last(where: { $0 <= minutes }) ?? Self.allowedIntervals[0]
    }
    if let style = try? c.decodeIfPresent(StripStyle.self, forKey: .stripStyle) {
      stripStyle = style
    } else if let modules = try? c.decodeIfPresent([String].self, forKey: .enabledModules) {
      // The module list an earlier build saved: any usage cell meant a usage strip.
      stripStyle = modules.contains(where: Self.oldUsageModules.contains) ? .ringAndName : .name
    }
    cliPathOverride = try c.decodeIfPresent(String.self, forKey: .cliPathOverride)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(usageEnabled, forKey: .usageEnabled)
    try c.encode(usageIntervalMinutes, forKey: .usageIntervalMinutes)
    try c.encode(stripStyle, forKey: .stripStyle)
    try c.encodeIfPresent(cliPathOverride, forKey: .cliPathOverride)
  }

  private static let oldUsageModules: Set<String> = ["sessionBar", "weeklyBar", "sessionReset", "weeklyReset"]
}

/// One JSON string under the key "settings", so a partial value can be
/// seeded with `defaults write <bundle id> settings -string '{...}'`.
public final class SettingsStore {
  private let defaults: UserDefaults
  private static let key = "settings"

  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  public func load() -> AppSettings {
    guard let text = defaults.string(forKey: Self.key),
      let settings = try? JSONDecoder().decode(AppSettings.self, from: Data(text.utf8))
    else { return AppSettings() }
    return settings
  }

  public func save(_ settings: AppSettings) {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.key)
  }
}
