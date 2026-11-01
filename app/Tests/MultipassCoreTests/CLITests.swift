import Foundation
import MultipassCore
import Testing

private func stubScript() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cli-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let url = dir.appendingPathComponent("claude-multipass")
  let body = """
    #!/bin/bash
    case "$1" in
      --version) echo "claude-multipass 0.3.0";;
      warn) echo '{"ok":true}'; echo "careful" >&2;;
      list) echo '{"version":"0.2.0","signedIn":false,"desktopRunning":false,"current":null,"profiles":[]}';;
      switch) echo "refused here" >&2; exit 3;;
      big) head -c 200000 /dev/zero | tr '\\0' x;;
      slow) sleep 5;;
      hang) (trap '' TERM; sleep 6 &); sleep 6;;
      linger) (sleep 6 &); echo done;;
      orphan) (trap '' TERM; sleep 30) & echo $! > "$2"; wait;;
      save) sleep 2; echo saved;;
      usage) sleep 2; echo usage;;
      doctor) sleep 5;;
      color) tput setaf 1; echo boom >&2; exit 1;;
      *) echo boom >&2; exit 1;;
    esac

    """
  try body.write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  return url
}

@Test func locatePrefersOverride() throws {
  let stub = try stubScript()
  let existing: Set<String> = [stub.path, CLI.candidates[1]]
  let isExecutable = { (path: String) in existing.contains(path) }
  #expect(CLI.locate(override: stub.path, isExecutable: isExecutable) == stub)
  #expect(CLI.locate(override: "/nope/claude-multipass", isExecutable: isExecutable) == URL(fileURLWithPath: CLI.candidates[1]))
  #expect(CLI.locate(override: nil, isExecutable: isExecutable) == URL(fileURLWithPath: CLI.candidates[1]))
  #expect(CLI.locate(override: nil, isExecutable: { _ in false }) == nil)
  #expect(CLI.locate(override: "", isExecutable: isExecutable) == URL(fileURLWithPath: CLI.candidates[1]))
}

@Test func bundledToolIsLastInPrecedence() {
  let b = URL(fileURLWithPath: "/App/Contents/Resources/claude-multipass")
  #expect(CLI.locate(override: nil, bundled: b, isExecutable: { $0 == b.path }) == b)
  #expect(CLI.locate(override: nil, bundled: b, isExecutable: { _ in true })?.path == "/opt/homebrew/bin/claude-multipass")
  #expect(CLI.locate(override: "/custom", bundled: b, isExecutable: { _ in true })?.path == "/custom")
  #expect(CLI.locate(override: nil, bundled: nil, isExecutable: { _ in false }) == nil)
}

@Test func locationIsTheExecutablePath() throws {
  let stub = try stubScript()
  #expect(CLI(executable: stub).location == stub.path)
}

@Test func runParsesVersion() async throws {
  let cli = CLI(executable: try stubScript())
  #expect(CLI.parseVersion(try await cli.run(["--version"])) == "0.3.0")
}

@Test func runCapturingReturnsStderrOnSuccess() async throws {
  let cli = CLI(executable: try stubScript())
  let out = try await cli.runCapturing(["warn"])
  #expect(String(decoding: out.stdout, as: UTF8.self) == "{\"ok\":true}\n")
  #expect(out.stderr == "careful")
  #expect(try await cli.run(["warn"]) == out.stdout)
}

@Test func exit3IsRefused() async throws {
  let cli = CLI(executable: try stubScript())
  await #expect(throws: CLIError.refused("refused here")) { try await cli.run(["switch", "x"]) }
}

@Test func exit1IsFailed() async throws {
  let cli = CLI(executable: try stubScript())
  await #expect(throws: CLIError.failed(status: 1, stderr: "boom")) { try await cli.run(["nope"]) }
}

@Test func stderrHasNoEscapeCodes() async throws {
  let cli = CLI(executable: try stubScript())
  await #expect(throws: CLIError.failed(status: 1, stderr: "boom")) { try await cli.run(["color"]) }
}

@Test func largeOutputDoesNotDeadlock() async throws {
  let cli = CLI(executable: try stubScript())
  let data = try await cli.run(["big"])
  #expect(data.count == 200_000)
}

@Test func slowCommandTimesOut() async throws {
  let cli = CLI(executable: try stubScript(), timeout: 1, mutatingTimeout: 1)
  let started = Date()
  await #expect(throws: CLIError.timedOut) { try await cli.run(["slow"]) }
  // terminate at 1 s; a shell that defers SIGTERM behind a child dies to the SIGKILL at 3 s
  #expect(Date().timeIntervalSince(started) < 4.5)
}

@Test func timeoutReleasesAHungGrandchild() async throws {
  // usage runs each account in a backgrounded subshell; a Keychain prompt
  // left open keeps that grandchild, and so the pipes, alive.
  let cli = CLI(executable: try stubScript(), timeout: 1, mutatingTimeout: 1)
  let started = Date()
  await #expect(throws: CLIError.timedOut) { try await cli.run(["hang"]) }
  #expect(Date().timeIntervalSince(started) < 4.5)
}

@Test func normalExitWithALingeringPipeHolderReturns() async throws {
  // The child exits at once but a backgrounded grandchild keeps its stdout
  // open for 6 s; the drain gives up after 2 s with what was read.
  let cli = CLI(executable: try stubScript())
  let started = Date()
  let out = try await cli.runCapturing(["linger"])
  #expect(String(decoding: out.stdout, as: UTF8.self) == "done\n")
  #expect(Date().timeIntervalSince(started) < 4)
}

@Test func timeoutKillsTheWholeProcessGroup() async throws {
  // switch waits on osascript and security; a timeout must not leave them
  // running, even one that outlives the SIGTERM.
  let cli = CLI(executable: try stubScript(), timeout: 1, mutatingTimeout: 1)
  let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("orphan-\(UUID().uuidString)")
  await #expect(throws: CLIError.timedOut) { try await cli.run(["orphan", pidFile.path]) }
  let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
  try await Task.sleep(nanoseconds: 300_000_000)
  #expect(kill(pid, 0) != 0)
}

@Test func promptingCommandsGetTheLongerTimeout() async throws {
  // save and switch can sit on an Automation or Keychain prompt, usage on its Safe Storage read.
  let cli = CLI(executable: try stubScript(), timeout: 1, mutatingTimeout: 10)
  #expect(String(decoding: try await cli.run(["save", "x"]), as: UTF8.self) == "saved\n")
  #expect(String(decoding: try await cli.run(["usage", "--json"]), as: UTF8.self) == "usage\n")
  await #expect(throws: CLIError.timedOut) { try await cli.run(["doctor"]) }
}

@Test func versionCompare() {
  #expect(CLI.isSupported("0.3.0"))
  #expect(!CLI.isSupported("0.2.2"))
  #expect(!CLI.isSupported("0.1.9"))
  #expect(CLI.isSupported("1.0.0"))
  #expect(CLI.isSupported("0.10.0"))
  #expect(!CLI.isSupported("garbage"))
  #expect(CLI.parseVersion(Data("claude-multipass 0.3.0\n".utf8)) == "0.3.0")
  #expect(CLI.parseVersion(Data("Usage: ...\n".utf8)) == nil)
}
