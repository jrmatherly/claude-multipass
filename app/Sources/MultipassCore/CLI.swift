import Foundation

public protocol CommandRunner: Sendable {
  func run(_ args: [String]) async throws -> Data
  /// Where the command lives, for display; nil when there is no path to show.
  var location: String? { get }
}

extension CommandRunner {
  public var location: String? { nil }
}

public enum CLIError: Error, Equatable {
  case refused(String)
  case failed(status: Int32, stderr: String)
  case badJSON(String)
  case timedOut
}

/// Runs `claude-multipass` as a subprocess. Exit 3 is a refusal `--force`
/// lifts; anything else non-zero is a failure with the CLI's stderr.
public struct CLI: CommandRunner {
  public let executable: URL
  public let timeout: TimeInterval

  public init(executable: URL, timeout: TimeInterval = 120) {
    self.executable = executable
    self.timeout = timeout
  }

  public static let candidates = ["/opt/homebrew/bin/claude-multipass", "/usr/local/bin/claude-multipass"]

  public var location: String? { executable.path }

  public static func locate(
    override: String?,
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> URL? {
    if let override, !override.isEmpty, isExecutable(override) {
      return URL(fileURLWithPath: override)
    }
    return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
  }

  public func run(_ args: [String]) async throws -> Data {
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    env["TERM"] = "dumb"
    process.environment = env
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice

    let exit = Exit()
    process.terminationHandler = { p in exit.finish(status: p.terminationStatus) }
    try process.run()

    // Drain both pipes while the command runs, or a chatty command fills a
    // pipe buffer and never terminates. The reads run on GCD through
    // readabilityHandler, never on a cooperative thread: a blocking read
    // there starves the pool on a small machine (a 3-core CI runner) and
    // the watchdog below never gets to run. After a timeout a grandchild
    // (usage runs each account in a backgrounded subshell) can keep the
    // write ends open, so the drains are only awaited on the normal path.
    let outData = PipeDrain(stdout.fileHandleForReading)
    let errData = PipeDrain(stderr.fileHandleForReading)
    let watchdog = Task {
      try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
      exit.markTimedOut()
      process.terminate()
      try await Task.sleep(nanoseconds: 2_000_000_000)
      kill(process.processIdentifier, SIGKILL)
    }
    let status = await exit.wait()
    watchdog.cancel()
    if exit.timedOut {
      outData.stop()
      errData.stop()
      throw CLIError.timedOut
    }
    let out = await outData.value()
    let err = await errData.value()
    let message = Self.plainText(err)
    switch status {
    case 0: return out
    case 3: throw CLIError.refused(message)
    default: throw CLIError.failed(status: status, stderr: message)
    }
  }

  /// "claude-multipass 0.2.0\n" → "0.2.0"
  public static func parseVersion(_ data: Data) -> String? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    guard parts.count == 2, parts[0] == "claude-multipass" else { return nil }
    return String(parts[1])
  }

  /// At least 0.2.0, compared per numeric component.
  public static func isSupported(_ version: String) -> Bool {
    let parts = version.split(separator: ".").map { Int($0) }
    guard parts.count >= 2, !parts.contains(nil) else { return false }
    let nums = parts.compactMap { $0 }
    return nums.lexicographicallyPrecedes([0, 2, 0]) == false
  }

  private static func plainText(_ data: Data) -> String {
    var text = String(decoding: data, as: UTF8.self)
    text = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]|\u{1B}\\([A-Z]", with: "", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Bridges `terminationHandler` to async, once, from whichever thread fires it.
private final class Exit: @unchecked Sendable {
  private let lock = NSLock()
  private var status: Int32?
  private var waiter: CheckedContinuation<Int32, Never>?
  private var didTimeOut = false
  var timedOut: Bool { lock.withLock { didTimeOut } }

  func finish(status: Int32) {
    lock.lock()
    self.status = status
    let w = waiter
    waiter = nil
    lock.unlock()
    w?.resume(returning: status)
  }

  func markTimedOut() {
    lock.withLock { didTimeOut = true }
  }

  func wait() async -> Int32 {
    await withCheckedContinuation { c in
      lock.lock()
      if let status {
        lock.unlock()
        c.resume(returning: status)
      } else {
        waiter = c
        lock.unlock()
      }
    }
  }
}

/// Collects a pipe to EOF on GCD and hands the bytes to one async waiter.
private final class PipeDrain: @unchecked Sendable {
  private let lock = NSLock()
  private let handle: FileHandle
  private var data = Data()
  private var done = false
  private var waiter: CheckedContinuation<Data, Never>?

  init(_ handle: FileHandle) {
    self.handle = handle
    handle.readabilityHandler = { [weak self] h in
      let chunk = h.availableData
      guard let self else { return }
      if chunk.isEmpty {
        self.finish()
      } else {
        self.lock.lock()
        self.data.append(chunk)
        self.lock.unlock()
      }
    }
  }

  func value() async -> Data {
    await withCheckedContinuation { c in
      lock.lock()
      if done {
        lock.unlock()
        c.resume(returning: data)
      } else {
        waiter = c
        lock.unlock()
      }
    }
  }

  /// Stop reading and release the handle; nothing waits for the bytes.
  func stop() {
    finish()
  }

  private func finish() {
    lock.lock()
    let first = !done
    done = true
    let w = waiter
    waiter = nil
    let bytes = data
    lock.unlock()
    if first {
      handle.readabilityHandler = nil
      try? handle.close()
    }
    w?.resume(returning: bytes)
  }
}
