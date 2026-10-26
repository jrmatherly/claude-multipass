import Foundation

/// One cell of the menu bar strip, in display order.
public enum Module: String, CaseIterable, Codable {
  case account, sessionBar, weeklyBar, sessionReset, weeklyReset

  public var label: String {
    switch self {
    case .account: return "@"
    case .sessionBar: return "5H"
    case .weeklyBar: return "7D"
    case .sessionReset: return "5H↻"
    case .weeklyReset: return "7D↻"
    }
  }

  public var needsUsage: Bool { self != .account }
}

public struct AppSettings: Equatable, Codable {
  public var usageEnabled = false
  public var usageIntervalMinutes = 15
  public var enabledModules: Set<Module> = [.account]
  public var cliPathOverride: String? = nil

  public static let snapshotInterval: TimeInterval = 30
  public static let allowedIntervals = [5, 15, 30, 60]

  public init() {}

  private enum Keys: String, CodingKey { case usageEnabled, usageIntervalMinutes, enabledModules, cliPathOverride }

  /// Every key optional, so a partial blob seeded with `defaults write` loads.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    usageEnabled = try c.decodeIfPresent(Bool.self, forKey: .usageEnabled) ?? usageEnabled
    if let minutes = try c.decodeIfPresent(Int.self, forKey: .usageIntervalMinutes) {
      usageIntervalMinutes = Self.allowedIntervals.last(where: { $0 <= minutes }) ?? Self.allowedIntervals[0]
    }
    if let names = try c.decodeIfPresent([String].self, forKey: .enabledModules) {
      enabledModules = Set(names.compactMap(Module.init(rawValue:)))
    }
    cliPathOverride = try c.decodeIfPresent(String.self, forKey: .cliPathOverride)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(usageEnabled, forKey: .usageEnabled)
    try c.encode(usageIntervalMinutes, forKey: .usageIntervalMinutes)
    try c.encode(Module.allCases.filter(enabledModules.contains).map(\.rawValue), forKey: .enabledModules)
    try c.encodeIfPresent(cliPathOverride, forKey: .cliPathOverride)
  }

  /// `Module.allCases` order, usage cells only while usage is on.
  public var visibleModules: [Module] {
    Module.allCases.filter { enabledModules.contains($0) && (usageEnabled || !$0.needsUsage) }
  }
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
