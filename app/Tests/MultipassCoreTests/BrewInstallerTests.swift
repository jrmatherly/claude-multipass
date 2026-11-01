import Foundation
import MultipassCore
import Testing

private let offer = UpdateOffer(version: "0.11.0", notes: [])
private let appURL = URL(fileURLWithPath: "/Applications/Claude Multipass.app")

/// `disk` answers each read in order; the last one repeats.
@MainActor
private final class Harness {
  let runner = FakeRunner()
  var disk: [String?]
  var relaunched: URL?
  var stages: [InstallStage] = []
  lazy var installer = BrewInstaller(
    runner: runner,
    appURL: appURL,
    diskVersion: { [unowned self] _ in self.disk.count > 1 ? self.disk.removeFirst() : self.disk[0] },
    relaunch: { [unowned self] in self.relaunched = $0 }
  )

  init(disk: [String?]) {
    self.disk = disk
    runner.answer("update", "")
    runner.answer("upgrade", "")
  }

  func install() async throws {
    try await installer.install(offer) { [unowned self] in self.stages.append($0) }
  }

  func problem() async -> UpdateProblem? {
    do {
      try await install()
    } catch {
      return error as? UpdateProblem
    }
    return nil
  }
}

@Test @MainActor func runsUpdateThenUpgradesFormulaAndCaskThenRelaunches() async throws {
  let h = Harness(disk: ["0.10.0", "0.11.0"])
  try await h.install()
  #expect(h.runner.calls == [["update", "--quiet"], ["upgrade", "jrmatherly/tap/claude-multipass", "jrmatherly/tap/claude-multipass-app"]])
  #expect(h.relaunched == appURL)
  #expect(h.stages == [.updatingHomebrew, .upgrading, .relaunching])
}

@Test @MainActor func exitZeroWithAnOldDiskIsAFailure() async throws {
  let h = Harness(disk: ["0.10.0"])
  let problem = try #require(await h.problem())
  #expect(problem.message.contains("0.10.0"))
  #expect(problem.fallback == .command(BrewInstaller.command))
  #expect(h.relaunched == nil)
}

@Test @MainActor func aDiskAlreadyNewerSkipsBrew() async throws {
  let h = Harness(disk: ["0.12.0"])
  try await h.install()
  #expect(h.runner.calls.isEmpty)
  #expect(h.relaunched == appURL)
  #expect(h.stages == [.relaunching])
}

@Test @MainActor func aDiskAlreadyAtTheOfferSkipsBrew() async throws {
  let h = Harness(disk: ["0.11.0"])
  try await h.install()
  #expect(h.runner.calls.isEmpty)
  #expect(h.relaunched == appURL)
}

@Test @MainActor func aBrewFailureCarriesItsTailAndTheCommand() async throws {
  let h = Harness(disk: ["0.10.0"])
  let lines = (1...25).map { "line \($0)" }
  h.runner.fail("upgrade", .failed(status: 1, stderr: lines.joined(separator: "\n")))
  let problem = try #require(await h.problem())
  #expect(problem.detail == lines.suffix(20).joined(separator: "\n"))
  #expect(problem.fallback == .command(BrewInstaller.command))
  #expect(h.relaunched == nil)
}

@Test @MainActor func aFailedBrewUpdateStillTriesTheUpgrade() async throws {
  let landed = Harness(disk: ["0.10.0", "0.11.0"])
  landed.runner.fail("update", .failed(status: 1, stderr: "a stale tap"))
  try await landed.install()
  #expect(landed.runner.calls.count == 2)
  #expect(landed.relaunched == appURL)

  let stuck = Harness(disk: ["0.10.0"])
  stuck.runner.fail("update", .failed(status: 1, stderr: "no network"))
  let problem = try #require(await stuck.problem())
  #expect(problem.detail == "no network")
  #expect(stuck.relaunched == nil)
}

@Test @MainActor func brewWarningsExplainAnOldDiskAfterExitZero() async throws {
  let h = Harness(disk: ["0.10.0"])
  h.runner.onStderr["upgrade"] = "Warning: already installed"
  let problem = try #require(await h.problem())
  #expect(problem.detail == "Warning: already installed")
}

@Test @MainActor func aFailureWithNoOutputHasNoDetail() async throws {
  let h = Harness(disk: ["0.10.0"])
  h.runner.fail("upgrade", .failed(status: 1, stderr: ""))
  let problem = try #require(await h.problem())
  #expect(problem.detail == nil)
}

@Test @MainActor func exit3ReadsAsAPlainFailure() async throws {
  let h = Harness(disk: ["0.10.0"])
  h.runner.fail("upgrade", .refused("a refusal"))
  let problem = try #require(await h.problem())
  #expect(problem.detail == "a refusal")
  #expect(problem.fallback == .command(BrewInstaller.command))
}

@Test @MainActor func aDenialFromMacOSGetsAHint() async throws {
  let h = Harness(disk: ["0.10.0"])
  h.runner.fail("upgrade", .failed(status: 1, stderr: "mv: Operation not permitted"))
  let problem = try #require(await h.problem())
  #expect(problem.message.contains("App Management"))
}

@Test @MainActor func otherFailuresGetNoHint() async throws {
  let h = Harness(disk: ["0.10.0"])
  h.runner.fail("upgrade", .failed(status: 1, stderr: "Error: boom"))
  let problem = try #require(await h.problem())
  #expect(!problem.message.contains("App Management"))
}

@Test @MainActor func aTimeoutReportsAndChecksTheDisk() async throws {
  let moved = Harness(disk: ["0.10.0", "0.11.0"])
  moved.runner.fail("upgrade", .timedOut)
  try await moved.install()
  #expect(moved.relaunched == appURL)

  let stuck = Harness(disk: ["0.10.0"])
  stuck.runner.fail("upgrade", .timedOut)
  let problem = try #require(await stuck.problem())
  #expect(problem.message.contains("in time"))
  #expect(problem.fallback == .command(BrewInstaller.command))
  #expect(stuck.relaunched == nil)
}

@Test @MainActor func aFailedRunWithANewDiskStillRelaunches() async throws {
  let h = Harness(disk: ["0.10.0", "0.11.0"])
  h.runner.fail("upgrade", .failed(status: 1, stderr: "the formula failed after the cask moved"))
  try await h.install()
  #expect(h.relaunched == appURL)
}

@Test @MainActor func aMissingBundleAfterBrewIsReported() async throws {
  let h = Harness(disk: ["0.10.0", nil])
  let problem = try #require(await h.problem())
  #expect(problem.message.contains("reinstall"))
  #expect(h.relaunched == nil)
}

@Test @MainActor func anUnreadableDiskVersionIsNeverTheNewVersion() async throws {
  let h = Harness(disk: ["garbage"])
  let problem = try #require(await h.problem())
  #expect(problem.message.contains("garbage"))
  #expect(h.runner.calls.count == 2)
  #expect(h.relaunched == nil)
}

@Test func brewRunsUnattendedAndTheCommandMatchesWhatItRuns() {
  #expect(BrewInstaller.environment == [
    "HOMEBREW_NO_ASK": "1",
    "HOMEBREW_NO_AUTO_UPDATE": "1",
    "HOMEBREW_NO_INSTALL_CLEANUP": "1",
    "HOMEBREW_NO_ENV_HINTS": "1",
  ])
  #expect(BrewInstaller.command == "brew update && brew upgrade jrmatherly/tap/claude-multipass jrmatherly/tap/claude-multipass-app")
}
