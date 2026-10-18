import Foundation

struct ManagedLineProcessSnapshot: Codable, Equatable, Sendable {
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
  let pendingWrites: Int
  let hasExited: Bool
  let lastError: String?
  var cleanupConfirmed: Bool? = nil

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
    case pendingWrites = "pending_writes"
    case hasExited = "has_exited"
    case lastError = "last_error"
    case cleanupConfirmed = "cleanup_confirmed"
  }

}

enum ManagedLineProcessError: Error, LocalizedError, Sendable {
  case closed
  case invalidConfiguration
  case bufferOverflow
  case launchFailed(String)
  case oversizedMessage(Int)
  case terminationTimedOut(processID: Int32?)

  var errorDescription: String? {
    switch self {
    case .closed:
      return "The gateway-owned process transport is closed."
    case .invalidConfiguration:
      return "Managed process requires absolute executable/cwd paths and bounded process settings."
    case .bufferOverflow:
      return "Managed process output exceeded the bounded inbound queue."
    case .launchFailed(let message):
      return "Could not launch the gateway-owned process: \(message)"
    case .oversizedMessage(let limit):
      return "Managed process emitted a protocol line larger than \(limit) bytes."
    case .terminationTimedOut(let processID):
      return
        "Managed process \(processID.map(String.init) ?? "unknown") did not exit after SIGKILL."
    }
  }
}

extension ManagedLineProcess {
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
      arguments: [String] = [],
      environment: [String: String] = ProcessInfo.processInfo.environment,
      workingDirectory: URL,
      terminationGraceMilliseconds: Int = 1_000,
      killGraceMilliseconds: Int = 2_000,
      maximumMessageBytes: Int = 1_024 * 1_024,
      ownerProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
      self.executable = executable
      self.arguments = arguments
      self.environment = environment
      self.workingDirectory = workingDirectory.standardizedFileURL
      self.terminationGraceMilliseconds = terminationGraceMilliseconds
      self.killGraceMilliseconds = killGraceMilliseconds
      self.maximumMessageBytes = maximumMessageBytes
      self.ownerProcessID = ownerProcessID
    }

    func validate() throws {
      #if os(Windows)
        let validPaths =
          Self.isAbsoluteWindowsPath(executable)
          && workingDirectory.isFileURL && Self.isAbsoluteWindowsPath(workingDirectory.path)
        let validOwner = UInt32(bitPattern: ownerProcessID) > 1
        let validEnvironment = environment.allSatisfy {
          !$0.key.isEmpty && !$0.key.contains("\0") && !$0.value.contains("\0")
        }
      #else
        let validPaths =
          executable.hasPrefix("/")
          && workingDirectory.isFileURL && workingDirectory.path.hasPrefix("/")
        let validOwner = ownerProcessID > 1
        let validEnvironment = environment.allSatisfy {
          !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0")
            && !$0.value.contains("\0")
        }
      #endif
      guard validPaths, validOwner, validEnvironment,
        !executable.contains("\0"), !workingDirectory.path.contains("\0"),
        arguments.allSatisfy({ !$0.contains("\0") }),
        (0...30_000).contains(terminationGraceMilliseconds),
        (100...30_000).contains(killGraceMilliseconds),
        (1...16_777_216).contains(maximumMessageBytes)
      else { throw ManagedLineProcessError.invalidConfiguration }
    }

    #if os(Windows)
      private static func isAbsoluteWindowsPath(_ path: String) -> Bool {
        let bytes = Array(path.replacingOccurrences(of: "/", with: "\\").utf8)
        if bytes.starts(with: [92, 92]) { return bytes.count > 2 }
        guard bytes.count >= 3, bytes[1] == 58, bytes[2] == 92 else { return false }
        return (65...90).contains(bytes[0]) || (97...122).contains(bytes[0])
      }
    #endif

  }
}
