import Foundation

struct CodexWorktreeSelection: Codable, Equatable, Sendable {
  // Dictionary membership preserves explicit JSON null independently of omission.
  let name: String
  private let fields: [String: JSONValue]

  init(_ arguments: [String: JSONValue]) throws {
    guard let name = arguments["name"]?.stringValue, name.utf8.count <= 48,
      name.wholeMatch(of: #/[a-z0-9]+(-[a-z0-9]+)*/#) != nil
    else { throw CodexManagedWorktreeError.invalid("name must be a lowercase worktree slug") }
    var fields: [String: JSONValue] = [:]
    for key in ["branch", "base"] {
      guard let value = arguments[key] else { continue }
      if value != .null {
        guard let text = value.stringValue, !text.isEmpty, text.utf8.count <= 1024,
          text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
          throw CodexManagedWorktreeError.invalid("\(key) must be a bounded branch name or null")
        }
      }
      fields[key] = value
    }
    self.name = name
    self.fields = fields
  }

  var arguments: [String: JSONValue] {
    var arguments = fields
    arguments["name"] = .string(name)
    return arguments
  }
  var expectedBranch: String { fields["branch"]?.stringValue ?? "worktree/\(name)" }
  var explicitBase: String? { fields["base"]?.stringValue }
}

struct CodexProjectScope: Codable, Equatable, Sendable {
  let principalID: String
  let profileID: String
  let projectID: String

  init?(_ owner: CodexRuntimeOwner?) {
    guard let principalID = owner?.principalID, !principalID.isEmpty,
      let profileID = owner?.profileID, !profileID.isEmpty,
      let projectID = owner?.workspaceID, !projectID.isEmpty
    else { return nil }
    self.principalID = principalID
    self.profileID = profileID
    self.projectID = projectID
  }
}

struct CodexHostWorktree: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let source: CodexProjectScope
  let selection: CodexWorktreeSelection
  let agentID: String
  let threadID: String?
  let runID: String?
  let parentLeaseID: String
  let ttlSeconds: Int
  let createdAt: Date
  var updatedAt: Date
  var revision = 1
  var state = CodexManagedWorktreeState.planned
  var planExpiresAt: Date?
  var force: Bool?
  var creation: CodexWorktreeCreation?
  var creationOperationID: UUID?
  var currentOperationID: UUID?
  var lease: CodexWorktreeLeaseOutcome?

  func projection(in scope: CodexProjectScope) -> [String: JSONValue] {
    var fields: [String: JSONValue] = [
      "id": .string(id), "source_project_id": .string(source.projectID),
      "project_id": creation.map { .string($0.projectID) } ?? .null,
      "requested": .object(selection.arguments),
      "resolved": creation?.result ?? .null,
      "state": .string(state.rawValue), "revision": .integer(Int64(revision)),
      "plan_expires_at": planExpiresAt.map { .string($0.ISO8601Format()) } ?? .null,
      "lease": lease?.json ?? .null,
      "operation_id": currentOperationID.map { .string($0.uuidString) } ?? .null,
    ]
    if scope == source {
      fields["agent_id"] = .string(agentID)
      fields["thread_id"] = threadID.map(JSONValue.string) ?? .null
      fields["run_id"] = runID.map(JSONValue.string) ?? .null
      fields["parent_lease_id"] = .string(parentLeaseID)
    }
    fields["perform_arguments"] = performArguments.map(JSONValue.object)
    return fields
  }

  var performArguments: [String: JSONValue]? {
    let revision = JSONValue.integer(Int64(revision))
    switch state {
    case .planned:
      return selection.arguments.merging([
        "plan_id": .string(id), "expected_revision": revision, "confirm_provision": .bool(true),
      ]) { value, _ in value }
    case .removalPlanned:
      return [
        "managed_worktree_id": .string(id), "expected_revision": revision,
        "confirm_remove": .bool(true), "force": .bool(force == true),
      ]
    default:
      return nil
    }
  }
}

struct CodexWorktreeCreation: Codable, Equatable, Sendable {
  let worktreeID: UUID
  let projectID: String
  let path: String
  let branch: String
  let result: JSONValue

  init(_ result: JSONValue, worktree: CodexHostWorktree) throws {
    guard let object = result.objectValue,
      let rawID = object["worktree_id"]?.stringValue, let id = UUID(uuidString: rawID),
      let projectID = object["project_id"]?.stringValue, !projectID.isEmpty,
      projectID != worktree.source.projectID,
      let path = object["path"]?.stringValue, path.hasPrefix("/"), !path.contains("\0"),
      let branch = object["branch"]?.stringValue, branch == worktree.selection.expectedBranch,
      let base = object["base"]?.stringValue, !base.isEmpty,
      worktree.selection.explicitBase.map({ $0 == base }) ?? true,
      let warnings = object["warnings"]?.arrayValue, warnings.allSatisfy({ $0.stringValue != nil })
    else { throw CodexWorktreeObservationError.invalidCompletion }
    self.worktreeID = id
    self.projectID = projectID
    self.path = path
    self.branch = branch
    self.result = result
  }
}

enum CodexWorktreeLeaseOutcome: Codable, Equatable, Sendable {
  case acquired(String)
  case conflict
  case unavailable(String)

  var json: JSONValue {
    switch self {
    case .acquired(let id): .object(["state": .string("acquired"), "lease_id": .string(id)])
    case .conflict: .object(["state": .string("conflict")])
    case .unavailable(let reason):
      .object(["state": .string("unavailable"), "reason": .string(reason)])
    }
  }
}

enum CodexWorktreeAction: String, Codable, Sendable {
  case provision = "projects.provision"
  case remove = "projects.remove"

  var tool: String {
    switch self {
    case .provision: "codex.worktree.provision.perform"
    case .remove: "codex.worktree.remove.perform"
    }
  }

  var pendingState: CodexManagedWorktreeState {
    switch self {
    case .provision: .provisioning
    case .remove: .removing
    }
  }
}

enum CodexHostWorktreeState: String, Codable, Sendable {
  case reserved
  case running
  case completed
  case failed
  case recoveryRequired = "recovery_required"

  var isTerminal: Bool { self == .completed || self == .failed }
}

enum CodexWorktreeObservationError: LocalizedError {
  case invalidInvocation
  case invalidEnvelope
  case invalidCompletion
  case refusal
  case conflictingTerminalState

  var errorDescription: String? {
    switch self {
    case .invalidInvocation: "Host invocation does not match the committed worktree operation."
    case .invalidEnvelope: "Host operation envelope is missing or does not match its binding."
    case .invalidCompletion: "Host completion does not match the reviewed worktree selection."
    case .refusal: "Host returned a refusal without a worktree operation outcome."
    case .conflictingTerminalState: "Host observation differs from the stored terminal outcome."
    }
  }
}

struct CodexWorktreeOperation: Codable, Equatable, Sendable {
  let ids: CodexHostOperationIDs
  let domainID: String
  let action: CodexWorktreeAction
  let source: CodexProjectScope
  let selectedProjectID: String
  let arguments: [String: JSONValue]
  let argumentsDigest: String
  var observedState: CodexHostWorktreeState?
  var envelope: JSONValue?
  var response: CodexHostToolResponse?
  var observationError: String?
  var uncertainResponse: CodexHostToolResponse?

  func validateInvocation(_ response: CodexHostToolResponse) throws -> JSONValue {
    guard response.refusal == nil else { throw CodexWorktreeObservationError.refusal }
    guard response.isError != true,
      let live = response.result?.objectValue, live["format_version"] == .integer(1),
      live["invocation_id"]?.stringValue.flatMap(UUID.init(uuidString:)) == ids.invocationID,
      live["principal_id"] == .string(source.principalID),
      live["profile_id"] == .string(source.profileID),
      live["project_id"] == .string(selectedProjectID),
      live["tool"] == .string(action.tool), live["host_action"] == .string(action.rawValue),
      live["arguments_digest"] == .string(argumentsDigest), let operation = live["operation"]
    else { throw CodexWorktreeObservationError.invalidInvocation }
    _ = try state(of: operation)
    return operation
  }

  func state(of envelope: JSONValue?) throws -> CodexHostWorktreeState {
    let fields = envelope?.objectValue
    guard fields?["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:)) == ids.operationID,
      fields?["invocation_id"]?.stringValue.flatMap(UUID.init(uuidString:)) == ids.invocationID,
      fields?["action"] == .string(action.rawValue),
      fields?["source_project_id"] == .string(source.projectID),
      fields?["project_id"] == .string(selectedProjectID),
      let state = fields?["state"]?.stringValue.flatMap(CodexHostWorktreeState.init(rawValue:)),
      state == .completed ? fields?["result"]?.objectValue != nil : fields?["result"] == .null
    else { throw CodexWorktreeObservationError.invalidEnvelope }
    let error = fields?["error"]
    switch state {
    case .failed, .recoveryRequired:
      guard let details = error?.objectValue,
        let code = details["code"]?.stringValue, !code.isEmpty,
        details["message"]?.stringValue != nil
      else { throw CodexWorktreeObservationError.invalidEnvelope }
    case .reserved, .running, .completed:
      guard error == .null else { throw CodexWorktreeObservationError.invalidEnvelope }
    }
    return state
  }

  func projection(in scope: CodexProjectScope, worktree: CodexHostWorktree) -> JSONValue {
    var result = worktree.projection(in: scope)
    result["invocation_id"] = .string(ids.invocationID.uuidString)
    result["host_state"] = observedState.map { .string($0.rawValue) } ?? .null
    result["host_response"] = response?.raw
    result["observation_error"] = observationError.map(JSONValue.string)
    result["uncertain_host_response"] = uncertainResponse?.raw
    return .object(result)
  }
}
