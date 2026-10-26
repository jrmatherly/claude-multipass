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
  public var savedAt: Date
  public var sessions: Int
  public var id: String { name }

  public init(name: String, account: String, savedAt: Date, sessions: Int) {
    self.name = name
    self.account = account
    self.savedAt = savedAt
    self.sessions = sessions
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

public struct UsageWindow: Decodable, Equatable {
  public var utilization: Double
  public var resetsAt: Date?

  public init(utilization: Double, resetsAt: Date? = nil) {
    self.utilization = utilization
    self.resetsAt = resetsAt
  }
}
