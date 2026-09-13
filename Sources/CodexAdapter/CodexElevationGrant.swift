import Foundation

enum CodexElevationGrantMode: String, Codable, CaseIterable, Sendable {
  case nextTurn = "next-turn"
  case threadScopedTTL = "thread-scoped-ttl"
  case boundedTime = "bounded-time"
}

enum CodexElevationGrantState: String, Codable, Sendable {
  case pending
  case approved
  case active
  case denied
  case revoked
  case expired
  case consumed
  case invalidated

  var isEffective: Bool {
    self == .approved || self == .active
  }
}

enum CodexElevationAction: String, Codable, Sendable {
  case threadStart = "thread-start"
  case turnStart = "turn-start"
}

struct CodexElevationGrantRecord: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let workspaceID: String
  let canonicalRoot: String
  let profileID: String
  let requestingCaller: String
  let requestingConnectionID: String?
  var threadID: String?
  let requestedSandbox: String
  let reason: String
  let mode: CodexElevationGrantMode
  let createdAt: Date
  let requestExpiresAt: Date
  let maximumDurationSeconds: Int
  let maximumTurnCount: Int?
  let requestCorrelationID: String
  var state: CodexElevationGrantState
  var localApprovedAt: Date?
  var activationAt: Date?
  var expiresAt: Date?
  var revokedAt: Date?
  var resolvedAt: Date?
  var resolutionReason: String?
  var approvalCorrelationID: String?
  var localApproverCaller: String?
  var consumedTurnCount: Int
  var consumedRuntimeIDs: [String]
  var consumedTurnIDs: [String]
  var inFlightClaimID: String?
  var inFlightAction: CodexElevationAction?
  var updatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case id
    case workspaceID = "workspace_id"
    case canonicalRoot = "canonical_root"
    case profileID = "profile_id"
    case requestingCaller = "requesting_caller"
    case requestingConnectionID = "requesting_connection_id"
    case threadID = "thread_id"
    case requestedSandbox = "requested_sandbox"
    case reason
    case mode
    case createdAt = "created_at"
    case requestExpiresAt = "request_expires_at"
    case maximumDurationSeconds = "maximum_duration_seconds"
    case maximumTurnCount = "maximum_turn_count"
    case requestCorrelationID = "request_correlation_id"
    case state
    case localApprovedAt = "local_approved_at"
    case activationAt = "activation_at"
    case expiresAt = "expires_at"
    case revokedAt = "revoked_at"
    case resolvedAt = "resolved_at"
    case resolutionReason = "resolution_reason"
    case approvalCorrelationID = "approval_correlation_id"
    case localApproverCaller = "local_approver_caller"
    case consumedTurnCount = "consumed_turn_count"
    case consumedRuntimeIDs = "consumed_runtime_ids"
    case consumedTurnIDs = "consumed_turn_ids"
    case inFlightClaimID = "in_flight_claim_id"
    case inFlightAction = "in_flight_action"
    case updatedAt = "updated_at"
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

struct CodexElevationClaim: Sendable {
  let id: String
  let action: CodexElevationAction
  let grant: CodexElevationGrantRecord
}

enum CodexElevationGrantError: Error, LocalizedError, Sendable, Equatable {
  case persistenceUnavailable
  case missingRuntimeBinding
  case unknown(String)
  case invalidMode(String)
  case invalidDuration
  case invalidTurnCount
  case threadRequired
  case requestExpired
  case alreadyResolved(String)
  case localApprovalRequired
  case requesterMismatch
  case claimMismatch

  var errorDescription: String? {
    switch self {
    case .persistenceUnavailable:
      return "Scoped Codex elevation requires the Gateway Database."
    case .missingRuntimeBinding:
      return "Scoped Codex elevation requires workspace, profile, caller, and connection bindings."
    case .unknown(let id):
      return "Unknown Codex elevation grant '\(id)'."
    case .invalidMode(let mode):
      return "Unsupported Codex elevation mode '\(mode)'."
    case .invalidDuration:
      return "maximum_duration_seconds must be between 30 and 3600."
    case .invalidTurnCount:
      return "maximum_turn_count must be between 1 and 100."
    case .threadRequired:
      return "thread-scoped-ttl requires an exact thread_id."
    case .requestExpired:
      return "The elevation request expired before local approval."
    case .alreadyResolved(let state):
      return "The elevation grant is already in terminal state '\(state)'."
    case .localApprovalRequired:
      return "Elevation approval and denial require the local-admin profile and a local caller."
    case .requesterMismatch:
      return "Only the bound requester or a local administrator may revoke this grant."
    case .claimMismatch:
      return "The elevation activation claim no longer matches the durable grant."
    }
  }
}
