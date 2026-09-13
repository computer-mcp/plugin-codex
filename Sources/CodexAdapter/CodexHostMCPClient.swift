import CryptoKit
import Foundation
import MCP

/// Host tools use standard MCP and the existing gateway policy/ticket tool surface.
/// Caller-provided tool arguments cannot select this connection or its authority.
actor CodexHostMCPClient: CodexHostTools, CodexElevationAuthority, CodexManagedWorkspaceHost,
  CodexHostDiagnostics
{
  static let descriptorEnvironmentKey = "COMPUTER_MCP_HOST_FD"
  private let owner: CodexRuntimeOwner
  private let workspaceID: String
  private let client = MCP.Client(name: "codex-host-tools", version: "0.1.0")
  private let transport: MCPInheritedSocketTransport
  private let requestTimeout: Duration
  private var startup: Task<Void, Error>?
  private var connected = false
  private var closed = false
  private struct Decision: Equatable {
    let name: String
    let digest: String
    let declared: CodexOperationRisk
    let effective: CodexOperationRisk
  }
  private var decisions: [String: Decision] = [:]

  static func inherited(environment: [String: String], context: CodexLaunchContext) throws -> Self?
  {
    guard let text = environment[descriptorEnvironmentKey] else { return nil }
    guard environment["COMPUTER_MCP_HOST_CONTEXT"] != nil,
      let descriptor = Int32(text), (3...9).contains(descriptor), String(descriptor) == text
    else { throw ConfigurationError.invalid("Invalid inherited host MCP descriptor.") }
    return try Self(
      takingOwnershipOf: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
      owner: context.owner)
  }

  init(
    takingOwnershipOf handle: FileHandle, owner: CodexRuntimeOwner,
    requestTimeout: Duration = .seconds(30)
  ) throws {
    guard requestTimeout > .zero else {
      throw ConfigurationError.invalid("Invalid host request timeout.")
    }
    guard let workspaceID = owner.workspaceID, !workspaceID.isEmpty else {
      throw ConfigurationError.invalid("Host MCP requires a bound workspace identity.")
    }
    self.owner = owner
    self.workspaceID = workspaceID
    self.requestTimeout = requestTimeout
    transport = try MCPInheritedSocketTransport(takingOwnershipOf: handle)
  }

  func risk(named name: String, arguments: JSONValue, requestID: String, workspaceID: String?)
    async throws -> CodexOperationRisk
  {
    try validate(name: name, arguments: arguments, requestID: requestID, workspaceID: workspaceID)
    guard decisions[requestID] == nil, decisions.count < 256 else {
      throw CodexToolError.executionFailed(
        "A host tool decision is already pending or the decision limit was reached.")
    }
    let decision = try await probe(name: name, arguments: arguments)
    guard !closed, decisions[requestID] == nil, decisions.count < 256 else {
      throw CodexToolError.executionFailed(
        "The host decision changed while its preflight was pending.")
    }
    decisions[requestID] = decision
    return decision.effective
  }

  func discard(requestID: String) { decisions.removeValue(forKey: requestID) }

  func execute(name: String, arguments: JSONValue, requestID: String, workspaceID: String?)
    async throws -> JSONValue
  {
    try validate(name: name, arguments: arguments, requestID: requestID, workspaceID: workspaceID)
    guard let decision = decisions.removeValue(forKey: requestID),
      decision.name == name, decision.digest == (try Self.digest(arguments))
    else {
      throw CodexToolError.executionFailed(
        "Host execution requires its matching preflight decision.")
    }
    // Do not convert an earlier read-only decision into an unapproved mutation.
    guard decision == (try await probe(name: name, arguments: arguments)) else {
      throw CodexToolError.executionFailed(
        "Host tool classification changed; a fresh approval is required.")
    }
    if decision.declared == .destructive {
      let target = scoped(arguments.objectValue ?? [:])
      let prepared = try await call(
        name: "operations.prepare",
        arguments: [
          "tool": .string(name), "arguments": .object(target),
          "workspace_id": .string(self.workspaceID),
        ])
      guard
        let ticket = prepared.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["ticket_id"]?.stringValue, !ticket.isEmpty
      else {
        throw CodexToolError.executionFailed("Host preparation did not return an operation ticket.")
      }
      return try await call(
        name: "operations.commit",
        arguments: [
          "tool": .string(name), "arguments": .object(target), "ticket_id": .string(ticket),
          "workspace_id": .string(self.workspaceID),
        ])
    }
    return try await call(name: name, arguments: scoped(arguments.objectValue ?? [:]))
  }

  func shutdown() async {
    closed = true
    decisions.removeAll()
    let startup = startup
    startup?.cancel()
    await transport.disconnect()
    await client.disconnect()
    _ = await startup?.result
  }

  private func validate(name: String, arguments: JSONValue, requestID: String, workspaceID: String?)
    throws
  {
    guard !closed, arguments.objectValue != nil, !name.hasPrefix("codex."),
      !name.hasPrefix("host."), !name.isEmpty, name.utf8.count <= 512, !requestID.isEmpty,
      requestID.utf8.count <= 512,
      workspaceID == nil || workspaceID == self.workspaceID,
      arguments.objectValue?["workspace_id"] == nil
        || arguments.objectValue?["workspace_id"] == .string(self.workspaceID)
    else {
      throw CodexToolError.executionFailed(
        "Host tool call does not match the bound connection scope.")
    }
  }

  private func scoped(_ arguments: [String: JSONValue]) -> [String: JSONValue] {
    var arguments = arguments
    arguments["workspace_id"] = .string(self.workspaceID)
    return arguments
  }

  private func probe(name: String, arguments: JSONValue) async throws -> Decision {
    let result = try await call(
      name: "policy.probe",
      arguments: [
        "capability_id": .string(name), "arguments": .object(scoped(arguments.objectValue ?? [:])),
        "workspace_id": .string(self.workspaceID),
      ])
    guard let value = result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue,
      value["decision"] == .string("allowed"), value["capability_id"] == .string(name),
      value["workspace_id"] == .string(self.workspaceID),
      let declared = value["risk"]?.stringValue.flatMap(CodexOperationRisk.init(rawValue:)),
      let effective = value["effective_risk"]?.stringValue.flatMap(
        CodexOperationRisk.init(rawValue:))
    else {
      throw CodexToolError.executionFailed(
        "Host preflight returned an invalid or unsupported decision.")
    }
    return Decision(
      name: name, digest: try Self.digest(arguments), declared: declared, effective: effective)
  }

  private func call(name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
    try Task.checkCancellation()
    guard !closed else { throw MCPError.connectionClosed }
    if !connected {
      let task: Task<Void, Error>
      if let startup {
        task = startup
      } else {
        let client = client
        let transport = transport
        let timeout = requestTimeout
        task = Task {
          _ = try await Self.bounded(client: client, transport: transport, timeout: timeout) {
            try await client.connect(transport: transport)
          }
        }
        startup = task
      }
      try await Self.bounded(client: client, transport: transport, timeout: requestTimeout) {
        try await task.value
      }
      try Task.checkCancellation()
      guard !closed else { throw MCPError.connectionClosed }
      connected = true
    }
    let client = client
    let parameters = try JSONDecoder().decode(
      [String: MCP.Value].self, from: JSONEncoder().encode(arguments))
    let result: MCP.CallTool.Result = try await Self.bounded(
      client: client, transport: transport, timeout: requestTimeout
    ) {
      let request: RequestContext<MCP.CallTool.Result> = try await client.callTool(
        name: name, arguments: parameters)
      return try await request.value
    }
    let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
    guard result.isError != true else {
      let error = value.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue
      throw CodexToolError.executionFailed(
        CodexApprovalRedactor.redactString(
          error?["message"]?.stringValue ?? "The host rejected the tool call."))
    }
    return value
  }

  private static func digest(_ value: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
  }

  /// Disconnecting on timeout/cancellation resolves SDK waiters before the task group joins.
  /// A cancelled deadline after normal completion must not close a reusable connection.
  private static func bounded<T: Sendable>(
    client: MCP.Client, transport: MCPInheritedSocketTransport, timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let state = Completion()
    let value = try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        defer { state.finish() }
        return try await operation()
      }
      group.addTask {
        do { try await Task.sleep(for: timeout) } catch {
          if !state.finished {
            await transport.disconnect()
            await client.disconnect()
          }
          throw CancellationError()
        }
        if !state.finished {
          await transport.disconnect()
          await client.disconnect()
        }
        throw CodexToolError.executionFailed("The host MCP request exceeded its deadline.")
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
    try Task.checkCancellation()
    return value
  }

  private final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var complete = false
    var finished: Bool { lock.withLock { complete } }
    func finish() { lock.withLock { complete = true } }
  }
}

extension CodexHostMCPClient {
  func snapshot(limit: Int, now: Date) async throws -> CodexHostDiagnosticSnapshot {
    guard (1...1000).contains(limit) else {
      throw CodexToolError.invalidArguments("Host diagnostic limit must be 1...1000.")
    }
    let value = try await service("host.diagnostics.snapshot", ["limit": .number(Double(limit))])
    guard let object = value.objectValue,
      let returnedOwner = object["owner"],
      try JSONDecoder().decode(CodexRuntimeOwner.self, from: JSONEncoder().encode(returnedOwner))
        == owner,
      let audits = object["recent_tool_audits"]?.arrayValue, audits.count <= limit,
      let grants = object["elevation_grants"]?.arrayValue, grants.count <= limit
    else {
      throw CodexToolError.executionFailed(
        "Host diagnostic response differs from the connection scope or limit.")
    }
    let records = try grants.map {
      try JSONDecoder().decode(CodexElevationGrantRecord.self, from: JSONEncoder().encode($0))
    }
    guard audits.allSatisfy({ $0.objectValue?["workspace_id"] == .string(workspaceID) }),
      records.allSatisfy({
        $0.workspaceID == workspaceID && $0.profileID == owner.profileID
          && $0.requestingCaller == owner.caller
          && $0.requestingConnectionID == owner.elevationConnectionID
      })
    else {
      throw CodexToolError.executionFailed("Host diagnostics included a different owner.")
    }
    return CodexHostDiagnosticSnapshot(
      owner: owner, recentToolAudits: audits, elevationGrants: records)
  }

  func claimCodexElevationGrant(
    workspaceID: String, canonicalRoot: String, profileID: String,
    requestingCaller: String, requestingConnectionID: String?, threadID: String?, runtimeID: String,
    action: CodexElevationAction, now: Date
  ) async throws -> CodexElevationClaim? {
    guard workspaceID == self.workspaceID, profileID == owner.profileID,
      requestingCaller == owner.caller, requestingConnectionID == owner.elevationConnectionID
    else {
      throw CodexToolError.executionFailed("Elevation request does not match the bound owner.")
    }
    var arguments: [String: JSONValue] = [
      "runtime_id": .string(runtimeID), "action": .string(action.rawValue),
    ]
    if let threadID { arguments["thread_id"] = .string(threadID) }
    let value = try await service("host.elevation.claim", arguments)
    if value == .null { return nil }
    guard let object = value.objectValue, let id = object["id"]?.stringValue,
      object["action"] == .string(action.rawValue), let grant = object["grant"]
    else {
      throw CodexToolError.executionFailed("Host returned an invalid elevation claim.")
    }
    let record = try JSONDecoder().decode(
      CodexElevationGrantRecord.self, from: JSONEncoder().encode(grant))
    guard record.workspaceID == workspaceID, record.profileID == profileID,
      record.requestingCaller == requestingCaller,
      record.requestingConnectionID == requestingConnectionID,
      record.canonicalRoot == canonicalRoot, record.inFlightClaimID == id,
      record.inFlightAction == action,
      record.state.isEffective
    else {
      throw CodexToolError.executionFailed(
        "Host claim scope differs from the requested activation.")
    }
    return CodexElevationClaim(id: id, action: action, grant: record)
  }

  func commitCodexElevationClaim(
    _ claim: CodexElevationClaim, runtimeID: String,
    threadID: String, turnID: String?, now: Date
  ) async throws -> CodexElevationGrantRecord {
    var arguments: [String: JSONValue] = [
      "claim_id": .string(claim.id), "runtime_id": .string(runtimeID),
      "thread_id": .string(threadID),
    ]
    if let turnID { arguments["turn_id"] = .string(turnID) }
    let value = try await service("host.elevation.commit", arguments)
    let record = try JSONDecoder().decode(
      CodexElevationGrantRecord.self, from: JSONEncoder().encode(value))
    guard record.id == claim.grant.id, record.workspaceID == workspaceID,
      record.profileID == owner.profileID, record.requestingCaller == owner.caller,
      record.requestingConnectionID == owner.elevationConnectionID,
      record.consumedRuntimeIDs.contains(runtimeID), record.threadID == threadID,
      record.inFlightClaimID == nil
    else {
      throw CodexToolError.executionFailed("Host activation receipt does not match this claim.")
    }
    return record
  }

  func invalidateCodexElevationClaim(_ claim: CodexElevationClaim, reason: String, now: Date)
    async throws
  {
    _ = try await service(
      "host.elevation.invalidate_claim", ["claim_id": .string(claim.id), "reason": .string(reason)])
  }

  func invalidateCodexElevationGrants(
    workspaceID: String?, threadID: String?,
    consumedRuntimeIDs: Set<String>, reason: String
  ) async throws {
    guard workspaceID == nil || workspaceID == self.workspaceID else {
      throw CodexToolError.executionFailed("Host invalidation scope differs.")
    }
    // No owned runtime/thread selector means no authority to invalidate unrelated grants.
    guard threadID != nil || !consumedRuntimeIDs.isEmpty else { return }
    var arguments: [String: JSONValue] = [
      "runtime_ids": .array(consumedRuntimeIDs.sorted().map(JSONValue.string)),
      "reason": .string(reason),
    ]
    if let threadID { arguments["thread_id"] = .string(threadID) }
    _ = try await service("host.elevation.invalidate", arguments)
  }

  func registerDerivedWorkspace(_ worktree: CodexManagedWorktree, now: Date) async throws {
    try validateDerived(worktree)
    let result = try await service("host.workspaces.register", ["worktree": worktree.json])
    guard result.objectValue?["registered"] == .bool(true),
      result.objectValue?["workspace_id"] == .string(worktree.workspaceID)
    else {
      throw CodexToolError.executionFailed("Host did not confirm the exact derived registration.")
    }
  }

  func unregisterDerivedWorkspace(_ worktree: CodexManagedWorktree, now: Date) async throws {
    try validateDerived(worktree)
    let result = try await service("host.workspaces.unregister", ["worktree": worktree.json])
    guard result.objectValue?["unregistered"] == .bool(true) else {
      throw CodexToolError.executionFailed("Host did not confirm registration removal.")
    }
  }

  func authorizeRemoval(_ worktree: CodexManagedWorktree) async throws {
    try validateDerived(worktree)
    let result = try await service("host.workspaces.authorize_removal", ["worktree": worktree.json])
    guard result.objectValue?["authorized"] == .bool(true) else {
      throw CodexToolError.executionFailed("Host did not authorize this removal.")
    }
  }

  private func validateDerived(_ worktree: CodexManagedWorktree) throws {
    guard worktree.sourceWorkspaceID == workspaceID, worktree.profileID == owner.profileID,
      worktree.caller == owner.caller
    else {
      throw CodexToolError.executionFailed(
        "Derived workspace receipt belongs to a different scope.")
    }
  }

  private func service(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
    let response = try await call(name: name, arguments: arguments)
    guard let result = response.objectValue?["structuredContent"]?.objectValue?["result"] else {
      throw CodexToolError.executionFailed("Host service returned no structured result.")
    }
    return result
  }
}
