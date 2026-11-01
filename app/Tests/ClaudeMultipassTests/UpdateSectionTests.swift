import AppKit
import Foundation
import MultipassCore
import SwiftUI
import Testing

@testable import ClaudeMultipass

private let offer = UpdateOffer(version: "0.19.0", notes: [])
private let problem = UpdateProblem(message: "no", detail: nil, fallback: nil)

@MainActor
private func aboutHeight(_ appState: AppState, _ updates: UpdateController?) -> CGFloat {
  NSHostingView(rootView: SettingsView(appState: appState, pane: .about, updates: updates)).fittingSize.height
}

@MainActor
private func ink(_ view: some View) throws -> CGFloat {
  let host = NSHostingView(rootView: view)
  host.frame = CGRect(origin: .zero, size: host.fittingSize)
  let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
  window.contentView = host
  host.layoutSubtreeIfNeeded()
  let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
  host.cacheDisplay(in: host.bounds, to: rep)
  var total: CGFloat = 0
  for x in 0..<rep.pixelsWide {
    for y in 0..<rep.pixelsHigh {
      total += rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }
  }
  return total
}

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

  @Test(arguments: [
    "[x](file:///etc/passwd)",
    "<file:///etc/passwd>",
    "[x](javascript:alert(1))",
    "[x](x-apple.systempreferences:com.apple.preference.security)",
    "[x](//example.com/a)",
    "[x](/etc/passwd)",
  ])
  func aFeedLinkThatIsNotHttpsIsNotALink(line: String) {
    #expect(releaseNoteText(line).runs.allSatisfy { $0.link == nil })
  }

  @Test func aFeedLineKeepsItsHttpsLinkAndItsEmphasis() {
    let text = releaseNoteText("**bold** `code` [x](https://example.com) [y](file:///etc/passwd)")
    #expect(String(text.characters) == "bold code x y")
    #expect(text.runs.compactMap(\.link) == [URL(string: "https://example.com")!])
    let intents = text.runs.compactMap(\.inlinePresentationIntent)
    #expect(intents.contains(.stronglyEmphasized))
    #expect(intents.contains(.code))
  }

  @Test func onlyACheckNowResultIsSpoken() {
    #expect(UpdateState.upToDate(Date(timeIntervalSince1970: 1)).spoken(after: .checking) == "Up to date")
    #expect(UpdateState.available(offer).spoken(after: .checking) == "Version 0.19.0 available")
    #expect(UpdateState.failed(offer, problem).spoken(after: .checking) == nil, "a failure announces from its own row")
    // A scheduled result: the settings hosts live on with no window, and a closed one must not speak.
    #expect(UpdateState.upToDate(Date(timeIntervalSince1970: 2)).spoken(after: .idle) == nil)
    #expect(UpdateState.upToDate(Date(timeIntervalSince1970: 2)).spoken(after: .upToDate(Date(timeIntervalSince1970: 1))) == nil)
    #expect(UpdateState.available(offer).spoken(after: .upToDate(Date(timeIntervalSince1970: 1))) == nil)
  }

  @Test func theNoticeSaysWhatIsHappening() {
    let failed = UpdateProblem(message: "no", detail: nil, fallback: .download(UpdateController.releasePage))
    #expect(UpdateState.available(offer).noticeOverride == nil)
    #expect(UpdateState.installing(offer, .upgrading).noticeOverride == "Updating…")
    #expect(UpdateState.installing(offer, .preparing).noticeOverride == "Updating…")
    #expect(UpdateState.failed(offer, failed).noticeOverride == "Update failed")
    #expect(UpdateState.failed(offer, problem).noticeOverride == nil, "a failed check keeps the offer standing")
  }

  private func menuTitles(_ updates: UpdateController, _ appState: AppState) -> [String] {
    StatusItemController(appState: appState, updates: updates).makeMenu().items.map(\.title)
  }

  private let baseMenu = ["Refresh", "Settings…", "", "Quit Claude Multipass"]

  @Test func theMenuOffersTheUpdateOnlyWhileAnOfferStands() async {
    let s = await state(FixtureRunner())
    let current = updateController(s, feed: .success(nil))
    #expect(menuTitles(current, s) == baseMenu, "idle")
    await current.check()
    #expect(menuTitles(current, s) == baseMenu, "up to date")

    let available = updateController(s)
    await available.check()
    let controller = StatusItemController(appState: s, updates: available)
    let menu = controller.makeMenu()
    #expect(menu.items[0].title == "Update to 0.19.0…")
    #expect(menu.items[0].target === controller)
    #expect(menu.items[0].action == Selector(("openAbout")))
    #expect(menu.items[1].isSeparatorItem)
    #expect(menu.items.dropFirst(2).map(\.title) == baseMenu)
  }

  @Test func theMenuLineFollowsAnInstallAndAFailure() async {
    let (upgradingState, upgrading) = await updateFixture("upgrading")
    #expect(menuTitles(upgrading, upgradingState).first == "Updating…")
    #expect(UpdateNotice(updates: upgrading, open: {}).title == "Updating…")
    let (failedState, failed) = await updateFixture("failedSparkle")
    #expect(menuTitles(failed, failedState).first == "Update failed")
    #expect(UpdateNotice(updates: failed, open: {}).title == "Update failed")
    let (_, available) = await updateFixture("available")
    #expect(UpdateNotice(updates: available, open: {}).title == "Update available")
  }

  @Test func quitIsDisabledAndSaysWhyOnlyWhileBrewRuns() async {
    let (blockedState, blocked) = await updateFixture("upgrading")
    let blockedController = StatusItemController(appState: blockedState, updates: blocked)
    let blockedMenu = blockedController.makeMenu()
    blockedMenu.update()
    let refused = blockedMenu.items.last
    #expect(refused?.title == "Quit (updating…)")
    #expect(refused?.isEnabled == false)

    let (freeState, free) = await updateFixture("installing")
    let freeController = StatusItemController(appState: freeState, updates: free)
    let freeMenu = freeController.makeMenu()
    freeMenu.update()
    #expect(freeMenu.items.last?.title == "Quit Claude Multipass")
    #expect(freeMenu.items.last?.isEnabled == true)
    #expect(freeMenu.items.first?.isEnabled == true)
  }

  @Test func theAppRefusesToQuitOnlyWhileBrewRuns() {
    #expect(AppDelegate.terminateReply(for: .installing(offer, .upgrading)) == .terminateCancel)
    #expect(AppDelegate.terminateReply(for: .installing(offer, .updatingHomebrew)) == .terminateCancel)
    #expect(AppDelegate.terminateReply(for: .installing(offer, .relaunching)) == .terminateNow)
    #expect(AppDelegate.terminateReply(for: .installing(offer, .downloading(0.4))) == .terminateNow)
    #expect(AppDelegate.terminateReply(for: .failed(offer, problem)) == .terminateNow)
    #expect(AppDelegate.terminateReply(for: nil) == .terminateNow)
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

  @Test func theAboutTabTakesTheHeightEachStateNeeds() async {
    var heights: [String: CGFloat] = [:]
    for name in updateFixtureNames {
      let (appState, updates) = await updateFixture(name)
      heights[name] = aboutHeight(appState, updates)
    }
    let base = aboutHeight(await state(FixtureRunner()), nil)
    for (name, height) in heights {
      #expect(height > base, "\(name) did not grow the About tab")
    }
    #expect(heights["available"]! >= heights["upToDate"]! + 200, "the change log collapsed")
    #expect(heights["failedBrew"]! > heights["available"]!, "no room for the failure")
    #expect(heights["failedSparkle"]! > heights["available"]!, "no room for the failure")
    #expect(heights["noBrew"]! > heights["available"]!, "no room for the brew-missing row")
    #expect(heights["failedNoBrew"]! <= heights["noBrew"]! + 20, "brew's absence is said twice")
    #expect(heights["startFailed"]! < heights["upToDate"]!, "more than the one row")
  }

  @Test func aDevelopmentBuildAddsNothingToAbout() async {
    let s = await state(FixtureRunner())
    let development = UpdateController(appState: s, feed: nil, detect: { .development }, installer: { _ in nil }, runningVersion: "0.9.0")
    #expect(aboutHeight(s, development) == aboutHeight(s, nil))
  }

  @Test func anUpdatingPhaseDrawsAccountRowsDimmer() async throws {
    let s = await state(FixtureRunner())
    let profile = try #require(s.snapshot?.profiles.first { $0.name == "work" })
    let row = AccountRow(appState: s, profile: profile, isExpanded: false, onTap: {}, onCancel: {}, onSwitch: { _ in })
    let idle = try ink(row)
    #expect(idle > 0)
    #expect(await s.beginUpdate())
    #expect(try ink(row) < idle * 0.7)
    await s.endUpdate()
    #expect(try ink(row) == idle)
  }

  @Test func copyPutsTheCommandOnThePasteboard() {
    let pasteboard = NSPasteboard(name: .init("net.matherly.claude-multipass.tests.copy"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("stale", forType: .string)
    UpdateSection.copy(BrewInstaller.command, to: pasteboard)
    #expect(pasteboard.string(forType: .string) == BrewInstaller.command)
    #expect(pasteboard.pasteboardItems?.count == 1)
  }

  @Test func turningTheDailyCheckOnChecks() async {
    let s = await state(FixtureRunner())
    var settings = s.settings
    settings.updateChecksEnabled = false
    await s.apply(settings)
    let updates = updateController(s)
    defer { updates.stop() }
    let host = NSHostingView(rootView: SettingsView(appState: s, pane: .about, updates: updates))
    host.layoutSubtreeIfNeeded()
    await Task.yield()
    #expect(updates.state == .idle)
    settings.updateChecksEnabled = true
    await s.apply(settings)
    #expect(await soon {
      host.layoutSubtreeIfNeeded()
      return updates.state.offer != nil
    }, "turning the toggle on did not check")
  }

  @Test func theRelaunchHelperOutlivesThePidThenOpensAPathWithASpace() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relaunch helper \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let opened = dir.appendingPathComponent("opened")
    let stub = dir.appendingPathComponent("open")
    try "#!/bin/sh\nprintf '%s' \"$1\" > '\(opened.path)'\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

    let dummy = Process()
    dummy.executableURL = URL(fileURLWithPath: "/bin/sleep")
    dummy.arguments = ["60"]
    try dummy.run()
    let app = dir.appendingPathComponent("Claude Multipass.app")
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = AppDelegate.relaunchArguments(app: app, pid: dummy.processIdentifier)
    helper.environment = ["PATH": "\(dir.path):/bin:/usr/bin"]
    try helper.run()
    defer { helper.terminate() }

    try await Task.sleep(for: .milliseconds(500))
    #expect(!FileManager.default.fileExists(atPath: opened.path), "opened while the process still lived")
    dummy.terminate()
    dummy.waitUntilExit()
    #expect(await soon { (try? String(contentsOf: opened, encoding: .utf8)) == app.path })
  }
}

