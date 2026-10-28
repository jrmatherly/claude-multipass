import Foundation

/// The CLI's JSON, decoded strictly: dates are `YYYY-MM-DDTHH:MM:SSZ` only,
/// the shape `usage --json` normalises to.
public enum MultipassJSON {
  public static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    iso.timeZone = TimeZone(identifier: "UTC")
    d.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard text.hasSuffix("Z"), let date = iso.date(from: text) else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected YYYY-MM-DDTHH:MM:SSZ, got \(text)")
      }
      return date
    }
    return d
  }()
}

public struct Snapshot: Decodable, Equatable {
  public var version: String
  public var signedIn: Bool
  public var desktopRunning: Bool
  public var current: String?
  public var profiles: [Profile]

  public init(version: String, signedIn: Bool, desktopRunning: Bool, current: String?, profiles: [Profile]) {
    self.version = version
    self.signedIn = signedIn
    self.desktopRunning = desktopRunning
    self.current = current
    self.profiles = profiles
  }
}

public struct Profile: Decodable, Equatable, Identifiable {
  public var name: String
  public var account: String
  /// nil when the profile's meta.json has no readable save time.
  public var savedAt: Date?
  public var sessions: Int
  /// Whether the profile holds the terminal's claude login (tool 0.3.0+).
  public var cliSaved: Bool
  public var id: String { name }

  public init(name: String, account: String, savedAt: Date?, sessions: Int, cliSaved: Bool = false) {
    self.name = name
    self.account = account
    self.savedAt = savedAt
    self.sessions = sessions
    self.cliSaved = cliSaved
  }

  private enum CodingKeys: String, CodingKey { case name, account, savedAt, sessions, cliSaved }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    account = try c.decode(String.self, forKey: .account)
    // Lenient: one bad row must not fail the whole snapshot (earlier tools sent "null").
    savedAt = try? c.decodeIfPresent(Date.self, forKey: .savedAt)
    sessions = try c.decode(Int.self, forKey: .sessions)
    cliSaved = try c.decodeIfPresent(Bool.self, forKey: .cliSaved) ?? false
  }
}

public struct UsageReport: Decodable, Equatable {
  public var profiles: [UsageEntry]

  public init(profiles: [UsageEntry]) {
    self.profiles = profiles
  }
}

public struct UsageEntry: Decodable, Equatable, Identifiable {
  public var name: String
  public var fiveHour: UsageWindow?
  public var sevenDay: UsageWindow?
  public var error: String?
  public var id: String { name }

  public init(name: String, fiveHour: UsageWindow? = nil, sevenDay: UsageWindow? = nil, error: String? = nil) {
    self.name = name
    self.fiveHour = fiveHour
    self.sevenDay = sevenDay
    self.error = error
  }
}

extension UsageEntry {
  /// The fuller window, named for display; the weekly one on a tie, since it takes longer to clear.
  public var peak: (window: String, utilization: Double)? {
    switch (fiveHour?.utilization, sevenDay?.utilization) {
    case let (five?, seven?): return five > seven ? ("5-hour", five) : ("weekly", seven)
    case let (five?, nil): return ("5-hour", five)
    case let (nil, seven?): return ("weekly", seven)
    case (nil, nil): return nil
    }
  }
}

public struct UsageWindow: Decodable, Equatable {
  public var utilization: Double
  public var resetsAt: Date?

  public init(utilization: Double, resetsAt: Date? = nil) {
    self.utilization = utilization
    self.resetsAt = resetsAt
  }
}
