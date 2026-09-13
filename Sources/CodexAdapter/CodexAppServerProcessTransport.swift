import CodexAppServerRuntime
import Darwin
import Foundation

struct CodexAppServerProcessSnapshot: Codable, Equatable, Sendable {
  enum State: String, Codable, Equatable, Sendable {
    case starting
    case running
    case stopping
    case stopped
    case failed
  }

  let state: State
  let processID: Int32?
  let supervisorProcessID: Int32?
  let parentProcessID: Int32
  let processGroupID: Int32?
  let startedAt: Date?
  let stoppedAt: Date?
  let exitCode: Int32?
  let signal: Int32?
  let terminationEscalated: Bool
  let lastError: String?

  private enum CodingKeys: String, CodingKey {
    case state
    case processID = "process_id"
    case supervisorProcessID = "supervisor_process_id"
    case parentProcessID = "parent_process_id"
    case processGroupID = "process_group_id"
    case startedAt = "started_at"
    case stoppedAt = "stopped_at"
    case exitCode = "exit_code"
    case signal
    case terminationEscalated = "termination_escalated"
    case lastError = "last_error"
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

enum CodexAppServerProcessTransportError: Error, LocalizedError, Sendable {
  case closed
  case launchFailed(String)
  case oversizedMessage(Int)
  case terminationTimedOut(processID: Int32?)

  var errorDescription: String? {
    switch self {
    case .closed:
      return "The Computer MCP-owned Codex App Server transport is closed."
    case .launchFailed(let message):
      return "Could not launch the Computer MCP-owned Codex App Server: \(message)"
    case .oversizedMessage(let limit):
      return "Codex App Server emitted a protocol line larger than \(limit) bytes."
    case .terminationTimedOut(let processID):
      return
        "Codex App Server process \(processID.map(String.init) ?? "unknown") did not exit after SIGKILL."
    }
  }
}

/// Adapts the shared owned-process primitive to the App Server line-peer contract.
final class ManagedCodexAppServerTransport: CodexAppServerLinePeer, Sendable {
  struct Configuration: Sendable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: URL
    var terminationGraceMilliseconds: Int
    var killGraceMilliseconds: Int
    var maximumMessageBytes: Int
    var ownerProcessID: Int32

    init(
      executable: String,
      arguments: [String] = ["app-server", "--listen", "stdio://"],
      environment: [String: String] = ProcessInfo.processInfo.environment,
      workingDirectory: URL,
      terminationGraceMilliseconds: Int = 1_000,
      killGraceMilliseconds: Int = 2_000,
      maximumMessageBytes: Int = 16 * 1_024 * 1_024,
      ownerProcessID: Int32 = getpid()
    ) {
      self.executable = executable
      self.arguments = arguments
      self.environment = environment
      self.workingDirectory = workingDirectory.standardizedFileURL
      self.terminationGraceMilliseconds = max(0, terminationGraceMilliseconds)
      self.killGraceMilliseconds = max(1, killGraceMilliseconds)
      self.maximumMessageBytes = max(1, maximumMessageBytes)
      self.ownerProcessID = ownerProcessID
    }
  }

  private let process: ManagedLineProcess
  var inboundLines: AsyncThrowingStream<String, Error> { process.inboundLines }

  init(configuration: Configuration) throws {
    process = try ManagedLineProcess(
      configuration: .init(
        executable: configuration.executable,
        arguments: configuration.arguments,
        environment: configuration.environment,
        workingDirectory: configuration.workingDirectory,
        terminationGraceMilliseconds: configuration.terminationGraceMilliseconds,
        killGraceMilliseconds: configuration.killGraceMilliseconds,
        maximumMessageBytes: configuration.maximumMessageBytes,
        ownerProcessID: configuration.ownerProcessID))
  }

  func sendLine(_ line: String) async throws {
    do { try await process.sendLine(line) } catch let error as ManagedLineProcessError {
      switch error {
      case .closed: throw CodexAppServerProcessTransportError.closed
      case .oversizedMessage(let limit):
        throw CodexAppServerProcessTransportError.oversizedMessage(limit)
      case .terminationTimedOut(let pid):
        throw CodexAppServerProcessTransportError.terminationTimedOut(processID: pid)
      default: throw CodexAppServerProcessTransportError.launchFailed(error.localizedDescription)
      }
    }
  }

  func close() async { await process.close() }

  func snapshot() async -> CodexAppServerProcessSnapshot {
    let value = await process.snapshot()
    return .init(
      state: .init(rawValue: value.state.rawValue) ?? .failed,
      processID: value.processID,
      supervisorProcessID: value.supervisorProcessID,
      parentProcessID: value.parentProcessID,
      processGroupID: value.processGroupID,
      startedAt: value.startedAt,
      stoppedAt: value.stoppedAt,
      exitCode: value.exitCode,
      signal: value.signal,
      terminationEscalated: value.terminationEscalated,
      lastError: value.lastError)
  }
}
