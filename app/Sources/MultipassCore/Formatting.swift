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

  public static func isDanger(_ utilization: Double?) -> Bool {
    guard let utilization else { return false }
    return utilization.rounded(.down) >= 90
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

/// The CLI's `valid_name` rule.
public func isValidProfileName(_ s: String) -> Bool {
  s != "." && s != ".." && s.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
}
