import Foundation

public enum Version {
  /// "0.10.1" → [0, 10, 1]; nil unless every dot-separated part is a number.
  public static func components(_ v: String) -> [Int]? {
    let parts = v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    return parts.contains(nil) ? nil : parts.compactMap { $0 }
  }

  /// Missing components count as 0. An unparseable side is never newer.
  public static func isNewer(_ a: String, than b: String) -> Bool {
    guard let a = components(a), let b = components(b) else { return false }
    let width = max(a.count, b.count)
    let padded = { (v: [Int]) in v + Array(repeating: 0, count: width - v.count) }
    return padded(b).lexicographicallyPrecedes(padded(a))
  }
}

/// One version's section of `CHANGELOG.md`.
public struct ReleaseNote: Equatable, Identifiable {
  public let version: String
  public let date: String
  public fileprivate(set) var lines: [String]
  public var id: String { version }

  public init(version: String, date: String, lines: [String]) {
    self.version = version
    self.date = date
    self.lines = lines
  }
}

public enum ChangeLog {
  /// The sections newer than `running`, in file order, which is newest first.
  public static func notes(in markdown: String, newerThan running: String) -> [ReleaseNote] {
    var all: [ReleaseNote] = []
    var inSection = false
    for raw in markdown.split(separator: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("## ") {
        let note = heading(line)
        inSection = note != nil
        if let note { all.append(note) }
      } else if inSection, !line.isEmpty {
        all[all.count - 1].lines.append(line.hasPrefix("- ") ? String(line.dropFirst(2)) : line)
      }
    }
    return all.filter { Version.isNewer($0.version, than: running) }
  }

  private static func heading(_ line: String) -> ReleaseNote? {
    guard line.range(of: #"^## \d+(\.\d+)+ \(\S+\)$"#, options: .regularExpression) != nil else { return nil }
    let parts = line.split(separator: " ")
    return ReleaseNote(version: String(parts[1]), date: String(parts[2].dropFirst().dropLast()), lines: [])
  }
}
