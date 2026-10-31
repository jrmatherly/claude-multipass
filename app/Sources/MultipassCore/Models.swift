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
  /// The server's plan label (`Ultra`), shown verbatim.
  public var plan: String?
  /// An Ultra account whose 5-hour window is missing or idle with no reset, which is how
  /// a verified one (no 5-hour limit) reports; the tool then sends no `fiveHour`.
  public var ultra: Bool?
  public var fiveHour: UsageWindow?
  public var sevenDay: UsageWindow?
  /// Weekly limits of one model or surface, such as Fable, beside the all-models one.
  public var scoped: [ScopedWindow]?
  public var error: String?
  public var id: String { name }

  public init(
    name: String, plan: String? = nil, ultra: Bool? = nil, fiveHour: UsageWindow? = nil, sevenDay: UsageWindow? = nil,
    scoped: [ScopedWindow]? = nil, error: String? = nil
  ) {
    self.name = name
    self.plan = plan
    self.ultra = ultra
    self.fiveHour = fiveHour
    self.sevenDay = sevenDay
    self.scoped = scoped
    self.error = error
  }
}

extension UsageEntry {
  public var isUltra: Bool { ultra == true }

  /// The fuller of the limits that cover every model. On a tie weekly wins,
  /// since it takes longer to clear.
  public var accountPeak: (window: String, utilization: Double)? {
    // An Ultra entry shows no 5-hour meter, so the account figure must not count one either.
    let windows = [("5-hour", isUltra ? nil : fiveHour), ("weekly", sevenDay)]
    var best: (window: String, utilization: Double)?
    for case let (label, window?) in windows where window.utilization >= (best?.utilization ?? -.infinity) {
      best = (label, window.utilization)
    }
    return best
  }

  /// The fullest of the limits scoped to one model or surface.
  public var modelPeak: Double? { scoped?.map(\.utilization).max() }

  public var accountIsFull: Bool {
    guard let accountPeak else { return false }
    return accountPeak.utilization.rounded(.down) >= 100
  }

  /// Figures only: the tool does not read usage credits, so it cannot say a
  /// full limit has stopped anything.
  public var limitsSummary: String? {
    let account = accountPeak.map { ["\($0.window) \(Format.percent($0.utilization))"] } ?? []
    let parts = account + (scoped ?? []).map { "\($0.name) weekly \(Format.percent($0.utilization))" }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }
}

/// One model's or surface's weekly limit, named by the server (`Fable`). Names may repeat,
/// so lists of these are keyed by position.
public struct ScopedWindow: Decodable, Equatable {
  public var name: String
  public var utilization: Double
  public var resetsAt: Date?
  public var window: UsageWindow { UsageWindow(utilization: utilization, resetsAt: resetsAt) }

  public init(name: String, utilization: Double, resetsAt: Date? = nil) {
    self.name = name
    self.utilization = utilization
    self.resetsAt = resetsAt
  }

  private enum CodingKeys: String, CodingKey { case name, utilization, resetsAt }

  /// A reset time that will not parse drops only that reset, never the whole report.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    utilization = try c.decode(Double.self, forKey: .utilization)
    resetsAt = try? c.decodeIfPresent(Date.self, forKey: .resetsAt)
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
