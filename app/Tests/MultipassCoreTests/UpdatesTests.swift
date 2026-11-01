import Foundation
import MultipassCore
import Testing

@Test func versionsCompareNumerically() {
  #expect(Version.isNewer("0.10.0", than: "0.9.1"))
  #expect(!Version.isNewer("0.9.1", than: "0.10.0"))
  #expect(!Version.isNewer("0.10", than: "0.10.0"))
  #expect(Version.isNewer("0.10.1", than: "0.10"))
  #expect(!Version.isNewer("garbage", than: "0.1.0"))
  #expect(!Version.isNewer("0.1.0", than: "garbage"))
}

@Test func emptyVersionPartsAreDropped() {
  #expect(Version.components("1.0.") == [1, 0])
  #expect(Version.components(".3.0") == [3, 0])
  #expect(Version.components("1..0") == [1, 0])
  #expect(CLI.isSupported("1.0."))
  #expect(CLI.isSupported(".3.0"))
  #expect(CLI.isSupported("1..0"))
  #expect(!CLI.isSupported("1."))
}

@Test func aVersionWithNoNumbersIsNoVersion() {
  #expect(Version.components("") == nil)
  #expect(Version.components("...") == nil)
  #expect(!Version.isNewer("0.1.0", than: ""))
  #expect(!Version.isNewer("", than: "0.1.0"))
}

@Test func signedPartsAreNotVersions() {
  #expect(Version.components("+9.0") == nil)
  #expect(Version.components("-1.0") == nil)
  #expect(Version.components("1.+2") == nil)
  #expect(!Version.isNewer("+9.0", than: "0.9.0"))
  #expect(!Version.isNewer("0.9.0", than: "-1.0"))
}

@Test func notesHandleEveryLineEnding() {
  let md = "## 0.3.0 (2026-11-03)\n\n- three\n\n## 0.2.0 (2026-11-02)\n\n- two\n\n## 0.1.0 (2026-11-01)\n\n- one\n"
  let expected = [
    ReleaseNote(version: "0.3.0", date: "2026-11-03", lines: ["three"]),
    ReleaseNote(version: "0.2.0", date: "2026-11-02", lines: ["two"]),
    ReleaseNote(version: "0.1.0", date: "2026-11-01", lines: ["one"]),
  ]
  #expect(ChangeLog.notes(in: md, newerThan: "0.0.1") == expected)
  #expect(ChangeLog.notes(in: md.replacingOccurrences(of: "\n", with: "\r\n"), newerThan: "0.0.1") == expected)
  #expect(ChangeLog.notes(in: md.replacingOccurrences(of: "\n", with: "\r"), newerThan: "0.0.1") == expected)
}

@Test func notesKeepOnlyNewerSectionsNewestFirst() {
  let md = "# Changelog\n\n## Unreleased\n\n- soon\n\n## 0.11.0 (2026-11-02)\n\n- two\n- `three`\n\n## 0.10.0 (2026-11-01)\n\n- one\n\n## 0.9.0 (2026-10-31)\n\n- old\n"
  let notes = ChangeLog.notes(in: md, newerThan: "0.9.0")
  #expect(notes.map(\.version) == ["0.11.0", "0.10.0"])
  #expect(notes[0].date == "2026-11-02")
  #expect(notes[0].lines == ["two", "`three`"])
}

@Test func notesSurviveAFeedWithNoUsableHeadings() {
  #expect(ChangeLog.notes(in: "no headings here", newerThan: "0.1.0").isEmpty)
}

@Test func notesFollowTheRealChangelogShape() {
  let md = """
    # Changelog

    ## Unreleased

    - not released yet

    ## 0.2.1 (2026-10-26)

    ## 0.2.0 (2026-10-25)

    - A bullet that wraps
      onto a second source line.
    - Another bullet.

    ## Notes

    - under a heading that is not a version

    ## 0.1.0 (2026-10-24)

    - first
    """
  let notes = ChangeLog.notes(in: md, newerThan: "0.1.0")
  #expect(notes.map(\.id) == ["0.2.1", "0.2.0"])
  #expect(notes[0].lines.isEmpty)
  #expect(notes[1].lines == ["A bullet that wraps", "onto a second source line.", "Another bullet."])
}

/// A Homebrew prefix and an installed bundle under one temp folder.
private func installFixture() throws -> (prefix: URL, bundle: URL) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("install-kind-\(UUID().uuidString)")
  let bundle = root.appendingPathComponent("Applications/Claude Multipass.app")
  try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
  return (root.appendingPathComponent("prefix"), bundle)
}

private func linkCask(in prefix: URL, to target: URL) throws {
  let dir = prefix.appendingPathComponent("Caskroom/claude-multipass-app/0.9.0")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("Claude Multipass.app"), withDestinationURL: target)
}

private func addBrew(to prefix: URL) throws -> URL {
  let bin = prefix.appendingPathComponent("bin")
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  let brew = bin.appendingPathComponent("brew")
  try "#!/bin/sh\n".write(to: brew, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
  return brew
}

@Test func caskSymlinkToThisBundleIsHomebrew() throws {
  let (prefix, bundle) = try installFixture()
  try linkCask(in: prefix, to: bundle)
  let brew = try addBrew(to: prefix)
  #expect(InstallKind.detect(bundleURL: bundle, version: "0.9.0", prefixes: [prefix]) == .homebrew(brew: brew))
  // Bundle.main.bundleURL ends in a slash, and the temp folder is itself behind a /private link.
  let asBundleMainGivesIt = URL(fileURLWithPath: bundle.path, isDirectory: true)
  #expect(InstallKind.detect(bundleURL: asBundleMainGivesIt, version: "0.9.0", prefixes: [prefix]) == .homebrew(brew: brew))
  let realPath = URL(fileURLWithPath: "/private" + bundle.path)
  #expect(InstallKind.detect(bundleURL: realPath, version: "0.9.0", prefixes: [prefix]) == .homebrew(brew: brew))
}

@Test func caskSymlinkToAnotherBundleIsDirect() throws {
  let (prefix, bundle) = try installFixture()
  let other = bundle.deletingLastPathComponent().appendingPathComponent("Other/Claude Multipass.app")
  try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
  try linkCask(in: prefix, to: other)
  _ = try addBrew(to: prefix)
  #expect(InstallKind.detect(bundleURL: bundle, version: "0.9.0", prefixes: [prefix]) == .direct)
}

@Test func caskroomWithoutBrewIsHomebrewMissing() throws {
  let (prefix, bundle) = try installFixture()
  try linkCask(in: prefix, to: bundle)
  #expect(InstallKind.detect(bundleURL: bundle, version: "0.9.0", prefixes: [prefix]) == .homebrewMissing)
}

// brew owns this install, so a click must not hand it to Sparkle because the bundle went away.
@Test func aCaskInstallWhoseBundleIsGoneIsHomebrewMissing() throws {
  let (prefix, bundle) = try installFixture()
  try linkCask(in: prefix, to: bundle)
  _ = try addBrew(to: prefix)
  try FileManager.default.removeItem(at: bundle)
  #expect(InstallKind.detect(bundleURL: bundle, version: "0.9.0", prefixes: [prefix]) == .homebrewMissing)
}

@Test func aGoneCopyBesideACaskInstallIsStillDirect() throws {
  let (prefix, bundle) = try installFixture()
  let other = bundle.deletingLastPathComponent().appendingPathComponent("Other/Claude Multipass.app")
  try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
  try linkCask(in: prefix, to: other)
  _ = try addBrew(to: prefix)
  try FileManager.default.removeItem(at: bundle)
  #expect(InstallKind.detect(bundleURL: bundle, version: "0.9.0", prefixes: [prefix]) == .direct)
}

@Test func noCaskroomIsDirect() throws {
  let (prefix, bundle) = try installFixture()
  _ = try addBrew(to: prefix)
  #expect(InstallKind.detect(bundleURL: bundle, version: "0.9.0", prefixes: [prefix]) == .direct)
}

@Test func missingVersionOrNonAppBundleIsDevelopment() throws {
  let (prefix, bundle) = try installFixture()
  try linkCask(in: prefix, to: bundle)
  _ = try addBrew(to: prefix)
  #expect(InstallKind.detect(bundleURL: bundle, version: nil, prefixes: [prefix]) == .development)
  let debug = bundle.deletingLastPathComponent().appendingPathComponent("debug")
  #expect(InstallKind.detect(bundleURL: debug, version: "0.9.0", prefixes: [prefix]) == .development)
}
