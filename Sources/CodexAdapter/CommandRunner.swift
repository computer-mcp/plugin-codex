import Foundation

struct CommandResult: Codable, Equatable, Sendable {
  var executable: String
  var arguments: [String]
  var exitCode: Int32?
  var timedOut: Bool
  var stdout: String
  var stderr: String
  var stdoutTruncated: Bool
  var stderrTruncated: Bool

  private enum CodingKeys: String, CodingKey {
    case executable
    case arguments
    case exitCode = "exit_code"
    case timedOut = "timed_out"
    case stdout
    case stderr
    case stdoutTruncated = "stdout_truncated"
    case stderrTruncated = "stderr_truncated"
  }

  init(
    executable: String,
    arguments: [String],
    exitCode: Int32?,
    timedOut: Bool,
    stdout: String,
    stderr: String,
    stdoutTruncated: Bool,
    stderrTruncated: Bool
  ) {
    self.executable = executable
    self.arguments = arguments
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.stdout = stdout
    self.stderr = stderr
    self.stdoutTruncated = stdoutTruncated
    self.stderrTruncated = stderrTruncated
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

struct CommandDataResult: Equatable, Sendable {
  var executable: String
  var arguments: [String]
  var exitCode: Int32?
  var timedOut: Bool
  var stdout: Data
  var stderr: Data
  var stdoutTruncated: Bool
  var stderrTruncated: Bool

  init(
    executable: String,
    arguments: [String],
    exitCode: Int32?,
    timedOut: Bool,
    stdout: Data,
    stderr: Data,
    stdoutTruncated: Bool,
    stderrTruncated: Bool
  ) {
    self.executable = executable
    self.arguments = arguments
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.stdout = stdout
    self.stderr = stderr
    self.stdoutTruncated = stdoutTruncated
    self.stderrTruncated = stderrTruncated
  }

  var stdoutString: String {
    String(decoding: stdout, as: UTF8.self)
  }

  var stderrString: String {
    String(decoding: stderr, as: UTF8.self)
  }
}

protocol CommandRunning: Sendable {
  func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult

  func runData(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandDataResult
}

enum CommandRunnerError: Error, LocalizedError, Equatable {
  case launchFailed(String)

  var errorDescription: String? {
    switch self {
    case .launchFailed(let message):
      return message
    }
  }
}
