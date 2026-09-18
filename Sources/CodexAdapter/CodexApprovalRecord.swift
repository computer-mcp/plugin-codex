import Foundation

enum CodexApprovalKind: String, Codable, Equatable, Sendable {
  case commandExecution = "command_execution"
  case fileChange = "file_change"
  case permissions
  case applyPatch = "apply_patch"
  case execCommand = "exec_command"
  case registeredTool = "registered_tool"
}

enum CodexApprovalState: String, Codable, Equatable, Sendable {
  case pending
  case approved
  case denied
  case cancelled
  case timedOut = "timed_out"
  case interrupted
  case failed

  var isTerminal: Bool {
    self != .pending
  }
}

struct CodexApprovalRecord: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let upstreamRequestID: String
  let kind: CodexApprovalKind
  let risk: CodexOperationRisk
  var state: CodexApprovalState
  let workspaceID: String?
  let workspacePath: String
  let runtimeID: String
  let threadID: String?
  let turnID: String?
  let itemID: String?
  let correlationID: String
  let socketConnectionID: String?
  let tunnelInstanceID: String?
  let details: JSONValue
  let proposedAction: JSONValue
  let createdAt: Date
  let expiresAt: Date
  var resolvedAt: Date?
  var decision: JSONValue?
  var scope: String?
  var resolutionReason: String?
  var owner: CodexRuntimeOwner? = nil
  var response: JSONValue? = nil

  private enum CodingKeys: String, CodingKey {
    case id
    case upstreamRequestID = "upstream_request_id"
    case kind
    case risk
    case state
    case workspaceID = "workspace_id"
    case workspacePath = "workspace_path"
    case runtimeID = "runtime_id"
    case threadID = "thread_id"
    case turnID = "turn_id"
    case itemID = "item_id"
    case correlationID = "correlation_id"
    case socketConnectionID = "socket_connection_id"
    case tunnelInstanceID = "tunnel_instance_id"
    case details
    case proposedAction = "proposed_action"
    case createdAt = "created_at"
    case expiresAt = "expires_at"
    case resolvedAt = "resolved_at"
    case decision
    case scope
    case resolutionReason = "resolution_reason"
    case owner
    case response
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

enum CodexApprovalBrokerError: Error, LocalizedError, Sendable {
  case unknown(String)
  case alreadyResolved(String)
  case unavailableAfterRestart(String)

  var errorDescription: String? {
    switch self {
    case .unknown(let id):
      return "Unknown Codex approval '\(id)'."
    case .alreadyResolved(let id):
      return "Codex approval '\(id)' is already resolved."
    case .unavailableAfterRestart(let id):
      return
        "Codex approval '\(id)' survived for audit, but its App Server request is no longer live."
    }
  }
}
