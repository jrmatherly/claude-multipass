import AppKit
import Foundation
import MultipassCore
import SwiftUI
import Testing

@testable import ClaudeMultipass

@Suite @MainActor struct UpdateSectionTests {
  @Test(arguments: [
    (InstallStage.preparing, "Preparing…"),
    (.updatingHomebrew, "Updating Homebrew…"),
    (.upgrading, "Upgrading…"),
    (.downloading(0.4), "Downloading 40 %"),
    (.downloading(nil), "Downloading…"),
    (.extracting, "Extracting…"),
    (.installing, "Installing…"),
    (.relaunching, "Relaunching…"),
  ])
  func stageLine(stage: InstallStage, text: String) {
    #expect(stage.label == text)
  }

  @Test func aProgressTickIsNotANewAnnouncement() {
    #expect(InstallStage.downloading(0.4).spoken == InstallStage.downloading(0.5).spoken)
    #expect(InstallStage.extracting.spoken == "Extracting…")
  }

  private func menuTitles(_ updates: UpdateController, _ appState: AppState) -> [String] {
    StatusItemController(appState: appState, updates: updates).makeMenu().items.map(\.title)
  }

  @Test func theMenuOffersTheUpdateOnlyWhileAnOfferStands() async {
    let s = await state(FixtureRunner())
    let base = ["Refresh", "Settings…", "", "Quit Claude Multipass"]
    let current = updateController(s, feed: .success(nil))
    #expect(menuTitles(current, s) == base, "idle")
    await current.check()
    #expect(menuTitles(current, s) == base, "up to date")

    let available = updateController(s)
    await available.check()
    #expect(menuTitles(available, s).first == "Update to 0.19.0…")
  }

  @Test func thePopoverGrowsOnlyWhileAnOfferStands() async {
    let s = await state(FixtureRunner())
    let height = { (updates: UpdateController?) -> CGFloat in
      NSHostingView(rootView: PopoverView(appState: s, openSettings: { _ in }, close: {}, updates: updates)).fittingSize.height
    }
    let base = height(nil)
    let current = updateController(s, feed: .success(nil))
    await current.check()
    #expect(height(current) == base)
    let available = updateController(s)
    await available.check()
    #expect(height(available) > base)
  }
}
