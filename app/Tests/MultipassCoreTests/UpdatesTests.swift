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
