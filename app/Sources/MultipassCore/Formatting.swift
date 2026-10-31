import Foundation

/// Text for the strip and the popover. Percentages floor, as the CLI's text
/// output does, so the red bar and the shown number agree.
public enum Format {
  public static func percent(_ utilization: Double?) -> String {
    guard let utilization else { return "–" }
    return "\(Int(utilization.rounded(.down)))%"
  }

  public static func fill(_ utilization: Double?) -> Double {
    guard let utilization else { return 0 }
    return min(max(utilization / 100, 0), 1)
  }

  public static func level(_ utilization: Double?) -> UsageLevel {
    guard let utilization else { return .normal }
    switch utilization.rounded(.down) {
    case 90...: return .danger
    case 70...: return .warning
    default: return .normal
    }
  }

  /// The short weekday, fixed English like the countdown, and the time in the
  /// user's 12 or 24 hour clock. Today's weekday a week on would read as today,
  /// so that one is a countdown instead.
  public static func resetTime(_ date: Date?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
    guard let date, date > now else { return nil }
    let day = calendar.component(.weekday, from: date)
    if date.timeIntervalSince(now) >= 86400, day == calendar.component(.weekday, from: now) { return countdown(to: date, now: now) }
    let clock = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    return "\(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][day - 1]) \(date.formatted(clock))"
  }

  public static func ago(_ date: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(date)) / 60
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min ago" }
    return "\(minutes / 60) h ago"
  }

  /// Integer division of seconds, not DateComponentsFormatter, whose output
  /// follows the locale.
  public static func countdown(to date: Date?, now: Date) -> String {
    guard let date else { return "–" }
    let seconds = Int(date.timeIntervalSince(now))
    guard seconds > 0 else { return "–" }
    let minutes = seconds / 60
    let hours = minutes / 60
    let days = hours / 24
    if hours < 1 { return "\(minutes)m" }
    if days < 1 { return "\(hours)h \(minutes % 60)m" }
    return "\(days)d \(hours % 24)h"
  }

  public static func displayName(_ name: String?, signedIn: Bool) -> String {
    guard let name else { return signedIn ? "not saved" : "signed out" }
    return name.count > 16 ? String(name.prefix(15)) + "…" : name
  }
}

/// Warning from 70 %, danger from 90 %, on the floored figure the text shows.
public enum UsageLevel: Equatable {
  case normal, warning, danger
}

/// The CLI's `valid_name` rule.
public func isValidProfileName(_ s: String) -> Bool {
  s.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
}
