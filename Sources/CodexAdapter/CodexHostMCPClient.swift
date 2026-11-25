import CryptoKit
import Foundation
import MCP

/// Host tools use standard MCP and the existing gateway project tool surface.
/// Caller-provided tool arguments cannot select this connection or its authority.
actor CodexHostMCPClient: CodexHostTools, CodexProjectServices,
  CodexHostDiagnostics
{
  static let descriptorEnvironmentKey = "COMPUTER_MCP_HOST_FD"
  private let owner: CodexRuntimeOwner
  private let projectID: String
  private let client = MCP.Client(name: "codex-host-tools", version: CodexAdapterBuildInfo.version)
  private let transport: MCPInheritedSocketTransport
  private let requestTimeout: Duration
  private let launchContract: String?
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
      owner: context.owner, launchContract: context.hostServiceContract)
  }

  init(
    takingOwnershipOf handle: FileHandle, owner: CodexRuntimeOwner,
    requestTimeout: Duration = .seconds(30), launchContract: String? = nil
  ) throws {
    guard requestTimeout > .zero else {
      throw ConfigurationError.invalid("Invalid host request timeout.")
    }
    guard let projectID = owner.workspaceID, !projectID.isEmpty else {
      throw ConfigurationError.invalid("Host MCP requires a bound project identity.")
    }
    self.owner = owner
    self.projectID = projectID
    self.requestTimeout = requestTimeout
    self.launchContract = launchContract
    transport = try MCPInheritedSocketTransport(
      takingOwnershipOf: handle, observesProjectContract: true)
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
    return try await call(
      name: name, arguments: scoped(arguments.objectValue ?? [:]), preserveToolError: true)
  }

  func shutdown() async {
    closed = true
    decisions.removeAll()
    let startup = startup
    startup?.cancel()
    await client.disconnect()
    await transport.disconnect()
    _ = await startup?.result
  }

  private func validate(name: String, arguments: JSONValue, requestID: String, workspaceID: String?)
    throws
  {
    guard !closed, arguments.objectValue != nil, !name.hasPrefix("codex."),
      !name.hasPrefix("host."), !name.isEmpty, name.utf8.count <= 512, !requestID.isEmpty,
      requestID.utf8.count <= 512,
      workspaceID == nil || workspaceID == self.projectID,
      arguments.objectValue?["project_id"] == nil
        || arguments.objectValue?["project_id"] == .string(self.projectID)
    else {
      throw CodexToolError.executionFailed(
        "Host tool call does not match the bound connection scope.")
    }
  }

  private func scoped(_ arguments: [String: JSONValue]) -> [String: JSONValue] {
    var arguments = arguments
    arguments["project_id"] = .string(self.projectID)
    return arguments
  }

  private func probe(name: String, arguments: JSONValue) async throws -> Decision {
    let result = try await call(
      name: "policy.probe",
      arguments: [
        "capability_id": .string(name), "arguments": .object(scoped(arguments.objectValue ?? [:])),
        "project_id": .string(self.projectID),
      ])
    guard let value = result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue,
      value["decision"] == .string("allowed"), value["capability_id"] == .string(name),
      value["project_id"] == .string(self.projectID),
      let declared = value["risk"]?.stringValue.flatMap(CodexOperationRisk.init(hostValue:)),
      let effective = value["effective_risk"]?.stringValue.flatMap(
        CodexOperationRisk.init(hostValue:))
    else {
      throw CodexToolError.executionFailed(
        "Host preflight returned an invalid or unsupported decision.")
    }
    return Decision(
      name: name, digest: try Self.digest(arguments), declared: declared, effective: effective)
  }

  private func connect() async throws {
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
  }

  private enum RawToolCall: MCP.Method {
    static let name = MCP.CallTool.name
    typealias Parameters = MCP.CallTool.Parameters
    typealias Result = MCP.Value
  }

  private func call(
    name: String, arguments: [String: JSONValue], preserveToolError: Bool = false
  ) async throws -> JSONValue {
    try await connect()
    let client = client
    let parameters = try JSONDecoder().decode(
      [String: MCP.Value].self, from: JSONEncoder().encode(arguments))
    let result: MCP.Value = try await Self.bounded(
      client: client, transport: transport, timeout: requestTimeout
    ) {
      let request = try await client.send(
        RawToolCall.request(.init(name: name, arguments: parameters)))
      return try await request.value
    }
    let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
    guard preserveToolError || value.objectValue?["isError"] != .bool(true) else {
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
    let value = try await service("host.diagnostics.snapshot", ["limit": .integer(Int64(limit))])
    guard let object = value.objectValue,
      let returnedOwner = object["owner"],
      try JSONDecoder().decode(
        CodexHostDiagnosticOwner.self, from: JSONEncoder().encode(returnedOwner)
      ).runtimeOwner == owner,
      let audits = object["recent_tool_audits"]?.arrayValue, audits.count <= limit
    else {
      throw CodexToolError.executionFailed(
        "Host diagnostic response differs from the connection scope or limit.")
    }
    guard audits.allSatisfy({ $0.objectValue?["project_id"] == .string(projectID) })
    else {
      throw CodexToolError.executionFailed("Host diagnostics included a different owner.")
    }
    return CodexHostDiagnosticSnapshot(
      owner: owner, recentToolAudits: audits)
  }

  func validateContract() async throws {
    guard launchContract == CodexProjectContract.identifier else {
      throw CodexProjectContract.Unsupported(observed: launchContract)
    }
    try await connect()
    let observed = await transport.observedProjectContract
    guard observed == CodexProjectContract.identifier else {
      throw CodexProjectContract.Unsupported(observed: observed)
    }
  }

  func describe(_ inspection: CodexProjectInspection) async throws -> CodexHostToolResponse {
    let arguments: [String: JSONValue]
    switch inspection {
    case .invocation(let id): arguments = ["invocation_id": .string(id.uuidString)]
    case .operation(let id): arguments = ["operation_id": .string(id.uuidString)]
    }
    return try await projectService("host.invocations.describe", arguments)
  }

  func add(_ selection: CodexWorktreeSelection, ids: CodexHostOperationIDs) async throws
    -> CodexHostToolResponse
  {
    try await projectService(
      "host.projects.worktree_add", ids.arguments.merging(selection.arguments) { id, _ in id })
  }

  func list(invocationID: UUID) async throws -> CodexHostToolResponse {
    try await projectService(
      "host.projects.worktree_list", ["invocation_id": .string(invocationID.uuidString)])
  }

  func remove(force: Bool, ids: CodexHostOperationIDs) async throws -> CodexHostToolResponse {
    var arguments = ids.arguments
    arguments["force"] = .bool(force)
    return try await projectService("host.projects.worktree_remove", arguments)
  }

  private func projectService(_ name: String, _ arguments: [String: JSONValue]) async throws
    -> CodexHostToolResponse
  {
    try await validateContract()
    return .init(raw: try await call(name: name, arguments: arguments, preserveToolError: true))
  }

  private func service(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
    let response = try await call(name: name, arguments: arguments)
    guard let result = response.objectValue?["structuredContent"]?.objectValue?["result"] else {
      throw CodexToolError.executionFailed("Host service returned no structured result.")
    }
    return result
  }
}
