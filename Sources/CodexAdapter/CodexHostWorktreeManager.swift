import Foundation
import MCP

struct CodexHostWorktreeManager: Sendable {
  let database: CodexDatabase
  let scope: CodexProjectScope
  let services: any CodexProjectServices

  func planProvision(
    selection: CodexWorktreeSelection, agentID: String, threadID: String?, runID: String?,
    parentLeaseID: String, ttlSeconds: Int, now: Date = Date()
  ) throws -> JSONValue {
    try Self.validateIdentifier(agentID, maximum: 256, name: "agent_id")
    try Self.validateIdentifier(parentLeaseID, maximum: 256, name: "parent_lease_id")
    if let threadID { try Self.validateIdentifier(threadID, maximum: 1024, name: "thread_id") }
    if let runID {
      try Self.validateIdentifier(runID, maximum: 256, name: "run_id")
      guard let run = try database.codexOrchestrationRun(id: runID),
        run.workspaceID == scope.projectID
      else { throw CodexManagedWorktreeError.invalid("run_id must identify a source-local run") }
    }
    guard (30...86_400).contains(ttlSeconds) else {
      throw CodexManagedWorktreeError.invalid("ttl_seconds must be between 30 and 86400")
    }
    let worktree = CodexHostWorktree(
      id: UUID().uuidString.lowercased(), source: scope, selection: selection,
      agentID: agentID, threadID: threadID, runID: runID, parentLeaseID: parentLeaseID,
      ttlSeconds: ttlSeconds, createdAt: now, updatedAt: now,
      planExpiresAt: now.addingTimeInterval(300))
    try database.saveProvisionPlan(worktree, in: scope, now: now)
    return .object(worktree.projection(in: scope))
  }

  func planRemoval(id: String, force: Bool, now: Date = Date()) throws -> JSONValue {
    let worktree = try database.saveRemovalPlan(id: id, in: scope, force: force, now: now)
    return .object(worktree.projection(in: scope))
  }

  func perform(
    id: String, action: CodexWorktreeAction, revision: Int,
    arguments: [String: JSONValue], invocation: CodexHostInvocation?, now: Date = Date()
  ) async throws -> MCP.CallTool.Result {
    guard let invocationID = invocation?.invocationID, let operationID = invocation?.operationID,
      invocationID != operationID
    else {
      throw CodexManagedWorktreeError.invalid("Host invocation and operation IDs are required.")
    }
    try await services.validateContract()
    let (worktree, operation) = try database.beginWorktreeOperation(
      id: id, in: scope, action: action, revision: revision, arguments: arguments,
      ids: .init(invocationID: invocationID, operationID: operationID), now: now)

    var response: CodexHostToolResponse?
    do {
      let inspection = try await services.describe(.invocation(invocationID))
      response = inspection
      let envelope = try operation.validateInvocation(inspection)
      let (current, observed) = try database.settleWorktreeOperation(
        id: worktree.id, in: scope, operationID: operationID, envelope: envelope,
        response: inspection, now: Date())
      guard observed.observedState == .reserved else { return try projected(current, observed) }
      response = nil
      let effect: CodexHostToolResponse
      switch action {
      case .provision:
        effect = try await services.add(worktree.selection, ids: operation.ids)
      case .remove:
        effect = try await services.remove(force: worktree.force == true, ids: operation.ids)
      }
      response = effect
      return try settle(worktree, operation, envelope: Self.envelope(effect), response: effect)
    } catch {
      return try uncertain(worktree, operation, response: response, error: error)
    }
  }

  func read(_ worktree: CodexHostWorktree, operation: CodexWorktreeOperation?) async throws
    -> MCP.CallTool.Result
  {
    guard let operation else { return try result(.object(worktree.projection(in: scope))) }
    guard operation.observedState?.isTerminal != true else {
      return try projected(worktree, operation)
    }
    var response: CodexHostToolResponse?
    do {
      let inspection = try await services.describe(.operation(operation.ids.operationID))
      response = inspection
      return try settle(
        worktree, operation, envelope: Self.envelope(inspection), response: inspection)
    } catch let error as CodexProjectContract.Unsupported {
      throw error
    } catch {
      return try uncertain(worktree, operation, response: response, error: error)
    }
  }

  func list(history: [JSONValue], limit: Int, invocation: CodexHostInvocation?) async throws
    -> MCP.CallTool.Result
  {
    guard let id = invocation?.invocationID, invocation?.operationID == nil else {
      throw CodexManagedWorktreeError.invalid("A host inventory invocation ID is required.")
    }
    let records = try database.hostWorktrees(in: scope, limit: limit)
    let response = try await services.list(invocationID: id)
    var payload: [String: JSONValue] = [
      "worktrees": .array(records.map { .object($0.projection(in: scope)) }),
      "unmanaged_history": .array(history), "host_response": response.raw,
    ]
    if response.result?.objectValue?["worktrees"]?.arrayValue == nil
      || response.isError == true || response.refusal != nil
    {
      payload["observation_error"] = .string("Host inventory was unavailable.")
    }
    return try response.toolResult(.object(payload))
  }

  private func settle(
    _ worktree: CodexHostWorktree, _ operation: CodexWorktreeOperation,
    envelope: JSONValue, response: CodexHostToolResponse
  ) throws -> MCP.CallTool.Result {
    let (current, observed) = try database.settleWorktreeOperation(
      id: worktree.id, in: scope, operationID: operation.ids.operationID,
      envelope: envelope, response: response, now: Date())
    return try projected(current, observed)
  }

  private func uncertain(
    _ worktree: CodexHostWorktree, _ operation: CodexWorktreeOperation,
    response: CodexHostToolResponse?, error: Error
  ) throws -> MCP.CallTool.Result {
    let message = CodexApprovalRedactor.redactString(
      error.localizedDescription, maximumCharacters: 4096)
    if let (current, observed) = try? database.recordWorktreeObservationFailure(
      id: worktree.id, in: scope, operationID: operation.ids.operationID,
      response: response, message: message),
      observed.observationError == message
    {
      return try projected(current, observed)
    }
    // The earlier ID transaction has committed. An observation that could not be
    // stored must still be visible to the caller without claiming settlement.
    let latest = try? database.hostWorktree(id: worktree.id, in: scope)
    var observed = latest?.1 ?? operation
    observed.observationError = message
    if let response { observed.uncertainResponse = response }
    return try projected(latest?.0 ?? worktree, observed)
  }

  private func projected(_ worktree: CodexHostWorktree, _ operation: CodexWorktreeOperation)
    throws -> MCP.CallTool.Result
  {
    let payload = operation.projection(in: scope, worktree: worktree)
    if let response = operation.uncertainResponse ?? operation.response {
      return try response.toolResult(payload)
    }
    return try result(payload, isError: operation.observationError != nil)
  }

  private func result(_ payload: JSONValue, isError: Bool = false) throws -> MCP.CallTool.Result {
    try MCP.CallTool.Result(
      structuredContent: JSONValue.object(["result": payload]), isError: isError)
  }

  private static func envelope(_ response: CodexHostToolResponse) throws -> JSONValue {
    if response.refusal != nil { throw CodexWorktreeObservationError.refusal }
    guard let envelope = response.result else {
      throw CodexWorktreeObservationError.invalidEnvelope
    }
    return envelope
  }

  private static func validateIdentifier(_ value: String, maximum: Int, name: String) throws {
    guard !value.isEmpty, value.utf8.count <= maximum,
      value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
      CodexApprovalRedactor.redactString(value, maximumCharacters: maximum) == value
    else { throw CodexManagedWorktreeError.invalid("\(name) must be a bounded identifier") }
  }
}
