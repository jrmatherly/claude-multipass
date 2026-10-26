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
      --version) echo "claude-multipass 0.2.0";;
      list) echo '{"version":"0.2.0","signedIn":false,"desktopRunning":false,"current":null,"profiles":[]}';;
      switch) echo "refused here" >&2; exit 3;;
      big) head -c 200000 /dev/zero | tr '\\0' x;;
      slow) sleep 5;;
      hang) (trap '' TERM; sleep 6 &); sleep 6;;
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

@Test func runParsesVersion() async throws {
  let cli = CLI(executable: try stubScript())
  #expect(CLI.parseVersion(try await cli.run(["--version"])) == "0.2.0")
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
  let cli = CLI(executable: try stubScript(), timeout: 1)
  let started = Date()
  await #expect(throws: CLIError.timedOut) { try await cli.run(["slow"]) }
  #expect(Date().timeIntervalSince(started) < 3)
}

@Test func timeoutReleasesAHungGrandchild() async throws {
  // usage runs each account in a backgrounded subshell; a Keychain prompt
  // left open keeps that grandchild, and so the pipes, alive.
  let cli = CLI(executable: try stubScript(), timeout: 1)
  let started = Date()
  await #expect(throws: CLIError.timedOut) { try await cli.run(["hang"]) }
  #expect(Date().timeIntervalSince(started) < 4)
}

@Test func versionCompare() {
  #expect(CLI.isSupported("0.2.0"))
  #expect(!CLI.isSupported("0.1.9"))
  #expect(CLI.isSupported("1.0.0"))
  #expect(CLI.isSupported("0.10.0"))
  #expect(!CLI.isSupported("garbage"))
  #expect(CLI.parseVersion(Data("claude-multipass 0.2.0\n".utf8)) == "0.2.0")
  #expect(CLI.parseVersion(Data("Usage: ...\n".utf8)) == nil)
}
