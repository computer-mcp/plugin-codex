import Foundation
import GRDB
import MCP
import Testing

@testable import CodexAdapter

@Suite(.timeLimit(.minutes(1)))
struct CodexManagedWorktreeTests {
  @Test(arguments: [nil, .null, .string("reviewed-base")] as [JSONValue?])
  func mcpPreservesReviewedSelectionAndCommitsHostIDsBeforeInspection(base: JSONValue?) async throws
  {
    let fixture = try WorktreeFixture()
    let provider = fixture.provider()
    try await withMCPClient(provider) { client in
      var planArguments: [String: JSONValue] = [
        "name": .string("example"), "agent_id": .string("child-agent"),
        "parent_lease_id": .string(fixture.parent.id),
      ]
      let branch: JSONValue? = base?.stringValue == nil ? base : .string("explicit-branch")
      planArguments["base"] = base
      planArguments["branch"] = branch
      let plan = try result(await call(client, "codex.worktree.provision.plan", planArguments))
      let performArguments = try #require(plan["perform_arguments"]?.objectValue)
      #expect(performArguments["base"] == base)
      #expect(performArguments["branch"] == branch)
      let ids = newIDs()
      var altered = performArguments
      altered["branch"] = .string("worktree/example")
      let substituted = try await call(
        client, "codex.worktree.provision.perform", altered, ids: ids)
      #expect(substituted.isError == true)
      let missing = try await call(client, "codex.worktree.provision.perform", performArguments)
      #expect(missing.isError == true)
      var spoofed = performArguments
      spoofed["operation_id"] = .string(ids.operationID.uuidString)
      let spoof = try await call(client, "codex.worktree.provision.perform", spoofed, ids: ids)
      #expect(spoof.isError == true)
      #expect(await fixture.host.callbacks.isEmpty)
      let digest = try CodexHostInvocation.digest(performArguments)
      await fixture.host.capture(digest, action: .provision)
      let completed = try result(
        await call(client, "codex.worktree.provision.perform", performArguments, ids: ids))
      #expect(completed["state"] == .string("active"))
      #expect(completed["host_state"] == .string("completed"))
      #expect(completed["requested"]?.objectValue?["base"] == base)
      #expect(
        completed["resolved"]?.objectValue?["branch"]
          == (branch?.stringValue.map(JSONValue.string) ?? .string("worktree/example")))
      #expect(
        completed["resolved"]?.objectValue?["base"]
          == (base?.stringValue.map(JSONValue.string) ?? .string("captured-main")))
      #expect(completed["lease"]?.objectValue?["state"] == .string("acquired"))
      #expect(await fixture.host.callbacks == ["inspect-invocation", "add"])
      #expect(await fixture.host.selection?.arguments["base"] == base)
      let id = try #require(completed["id"]?.stringValue)
      let child = try #require(try fixture.child.hostWorktree(id: id, in: fixture.childScope)?.0)
      #expect(child.projection(in: fixture.childScope)["run_id"] == nil)
      #expect(
        try fixture.child.hostWorktree(
          id: id, in: #require(CodexProjectScope(fixture.owner(project: "sibling")))) == nil)
      #expect(
        try fixture.child.hostWorktree(
          id: id,
          in: #require(CodexProjectScope(fixture.owner(project: "child", principal: "other"))))
          == nil)
    }
  }

  @Test
  func hostDigestMismatchPreservesPendingOperationWithoutCallingEffect() async throws {
    let fixture = try WorktreeFixture()
    let (id, request) = try fixture.plan()
    let ids = newIDs()
    await fixture.host.capture("mismatched-complete-digest", action: .provision)
    let reply = try await fixture.manager.perform(
      id: id, action: .provision, revision: 1, arguments: request, invocation: metadata(ids))
    #expect(reply.isError == true)
    let projection = try result(reply)
    #expect(projection["operation_id"] == .string(ids.operationID.uuidString))
    #expect(projection["uncertain_host_response"]?.objectValue?["structuredContent"] != nil)
    #expect(await fixture.host.callbacks == ["inspect-invocation"])
    let stored = try #require(try fixture.source.hostWorktree(id: id, in: fixture.sourceScope))
    #expect(stored.0.state == .provisioning)
    #expect(stored.1?.ids == ids)
  }

  @Test
  func conflictingLeaseLeavesCompletedAssociationAndAllowsLaterChildAcquisition() async throws {
    let fixture = try WorktreeFixture()
    let conflict = try fixture.acquire(
      in: fixture.child, scope: fixture.childScope, agent: "other-agent")
    let (id, request) = try fixture.plan()
    let created = try await fixture.performProvision(id, request: request)
    #expect(created["host_state"] == .string("completed"))
    #expect(created["lease"]?.objectValue?["state"] == .string("conflict"))
    #expect(try fixture.child.codexWorktreeLease(id: conflict.id) == conflict)
    #expect(throws: CodexManagedWorktreeError.self) {
      try fixture.childManager.planRemoval(id: id, force: false)
    }
    try fixture.release(conflict, in: fixture.child)
    let original = try #require(try fixture.child.hostWorktree(id: id, in: fixture.childScope))
    let operation = try #require(original.1)
    let envelope = try #require(operation.envelope)
    let response = try #require(operation.response)
    _ = try fixture.child.settleWorktreeOperation(
      id: id, in: fixture.childScope, operationID: operation.ids.operationID,
      envelope: envelope, response: response, now: Date())
    #expect(try fixture.child.hostWorktree(id: id, in: fixture.childScope)?.0.lease == .conflict)
    let acquired = try fixture.acquire(
      in: fixture.child, scope: fixture.childScope, agent: "child-agent", parent: fixture.parent.id)
    #expect(acquired.hostWorktreeID == fixture.host.worktreeID)
    #expect(acquired.creationOperationID == operation.ids.operationID)
    #expect(acquired.managedWorktreeID == id)
  }

  @Test
  func concurrentSourceConnectionsCommitOnlyOneOperation() async throws {
    let fixture = try WorktreeFixture()
    let another = try CodexDatabase(path: fixture.sourcePath, worktreeLeasePath: fixture.sharedPath)
    let (id, request) = try fixture.plan()
    let digest = try CodexHostInvocation.digest(request)
    await fixture.host.capture(digest, action: .provision)

    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { tasks in
      for database in [fixture.source, another] {
        tasks.addTask {
          let manager = CodexHostWorktreeManager(
            database: database, scope: fixture.sourceScope, services: fixture.host)
          do {
            _ = try await manager.perform(
              id: id, action: .provision, revision: 1, arguments: request,
              invocation: metadata(newIDs()))
            return true
          } catch CodexManagedWorktreeError.revisionConflict {
            return false
          } catch {
            Issue.record("Unexpected admission failure: \(error)")
            return false
          }
        }
      }
      var successes = 0
      for await admitted in tasks where admitted { successes += 1 }
      return successes
    }
    #expect(successes == 1)
    #expect(await fixture.host.callbacks == ["inspect-invocation", "add"])
  }

  @Test(arguments: [CodexHostWorktreeState.failed, .recoveryRequired])
  func structuredHostErrorsRetainTheirEnvelopeAndNeverReplay(state: CodexHostWorktreeState)
    async throws
  {
    let fixture = try WorktreeFixture()
    let (id, request) = try fixture.plan()
    await fixture.host.failCreation(as: state)
    let outcome = try await fixture.performProvision(id, request: request)
    #expect(outcome["state"] == .string(state == .failed ? "failed" : "provisioning"))
    #expect(outcome["host_state"] == .string(state.rawValue))
    let raw = try #require(outcome["host_response"]?.objectValue)
    #expect(raw["isError"] == .bool(true))
    #expect(raw["content"]?.arrayValue?.count == 1)
    let envelope = raw["structuredContent"]?.objectValue?["result"]?.objectValue
    #expect(envelope?["extension"] == .integer(9))
    #expect(envelope?["error"]?.objectValue?["code"] == .string("permission.required"))
    let pending = try #require(try fixture.source.hostWorktree(id: id, in: fixture.sourceScope))
    #expect(pending.1?.response?.raw == .object(raw))
    let revision = pending.0.revision
    await #expect(throws: CodexManagedWorktreeError.self) {
      try await fixture.manager.perform(
        id: id, action: .provision, revision: revision, arguments: request,
        invocation: metadata(newIDs()))
    }
    #expect(await fixture.host.callbacks == ["inspect-invocation", "add"])
  }

  @Test
  func sqlSettlementFailureRecoversSameCreationWithoutRepeatingHostEffect() async throws {
    let fixture = try WorktreeFixture()
    let (id, request) = try fixture.plan()
    let queue = try DatabaseQueue(path: fixture.sharedPath)
    try await queue.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER reject_child_settlement BEFORE UPDATE ON codexHostWorktrees
          WHEN NEW.childProjectID IS NOT NULL
          BEGIN SELECT RAISE(ABORT, 'fixture settlement failure'); END
          """)
    }
    let uncertain = try await fixture.performProvision(id, request: request)
    #expect(uncertain["state"] == .string("provisioning"))
    #expect(uncertain["host_state"] == .string("reserved"))
    #expect(uncertain["uncertain_host_response"] != nil)
    let pending = try #require(try fixture.source.hostWorktree(id: id, in: fixture.sourceScope))
    let operation = try #require(pending.1)
    #expect(operation.observedState == .reserved)
    #expect(try fixture.child.hostWorktree(id: id, in: fixture.childScope) == nil)
    try await queue.write { try $0.execute(sql: "DROP TRIGGER reject_child_settlement") }
    let reopened = try CodexDatabase(
      path: fixture.sourcePath, worktreeLeasePath: fixture.sharedPath)
    let source = CodexHostWorktreeManager(
      database: reopened, scope: fixture.sourceScope, services: fixture.host)
    let resolved = try result(await source.read(pending.0, operation: operation))
    #expect(resolved["state"] == .string("active"))
    #expect(resolved["operation_id"] == .string(operation.ids.operationID.uuidString))
    #expect(await fixture.host.callbacks == ["inspect-invocation", "add", "inspect-operation"])
  }

  @Test
  func lostChildRemovalReplyIsRecoverableFromTheSource() async throws {
    let fixture = try WorktreeFixture()
    let (id, request) = try fixture.plan()
    let created = try await fixture.performProvision(id, request: request)
    let leaseID = try #require(created["lease"]?.objectValue?["lease_id"]?.stringValue)
    let lease = try #require(try fixture.child.codexWorktreeLease(id: leaseID))
    try fixture.release(lease, in: fixture.child)
    #expect(throws: CodexManagedWorktreeError.self) {
      try fixture.manager.planRemoval(id: id, force: true)
    }
    let plan = try fixture.childManager.planRemoval(id: id, force: true)
    let arguments = try #require(plan.objectValue?["perform_arguments"]?.objectValue)
    let revision = try #require(arguments["expected_revision"]?.intValue)
    let ids = newIDs()
    var changed = arguments
    changed["force"] = .bool(false)
    await #expect(throws: CodexManagedWorktreeError.self) {
      try await fixture.childManager.perform(
        id: id, action: .remove, revision: revision, arguments: changed, invocation: metadata(ids))
    }
    #expect(throws: CodexWorktreeLeaseError.self) {
      try fixture.acquire(
        in: fixture.child, scope: fixture.childScope, agent: "racer", parent: fixture.parent.id)
    }
    let digest = try CodexHostInvocation.digest(arguments)
    await fixture.host.capture(digest, action: .remove)
    await fixture.host.loseNextRemovalReply()
    let removal = try await fixture.childManager.perform(
      id: id, action: .remove, revision: revision, arguments: arguments, invocation: metadata(ids))
    #expect(removal.isError == true)
    #expect(try result(removal)["state"] == .string("removing"))
    let recovered = try #require(try fixture.source.hostWorktree(id: id, in: fixture.sourceScope))
    #expect(recovered.1?.ids == ids)
    let settled = try result(await fixture.manager.read(recovered.0, operation: recovered.1))
    #expect(settled["state"] == .string("removed"))
    #expect(settled["operation_id"] == .string(ids.operationID.uuidString))
    #expect(
      await fixture.host.callbacks.suffix(3) == [
        "inspect-invocation", "remove", "inspect-operation",
      ])
  }

  @Test
  func foreignInventoryDoesNotCreateLineage() async throws {
    let fixture = try WorktreeFixture()
    let listed = try await fixture.manager.list(
      history: [], limit: 10, invocation: metadata(newIDs(), list: true))
    let payload = try result(listed)
    let inventory = payload["host_response"]?.objectValue?["structuredContent"]?
      .objectValue?["result"]?.objectValue?["worktrees"]?.arrayValue
    #expect(inventory?.count == 1)
    #expect(payload["worktrees"] == .array([]))
    #expect(throws: CodexWorktreeLeaseError.self) {
      try fixture.acquire(
        in: fixture.child, scope: fixture.childScope, agent: "child", parent: fixture.parent.id)
    }
  }
}

private final class WorktreeFixture: Sendable {
  let root: URL
  let sourcePath: String
  let sharedPath: String
  let source: CodexDatabase
  let child: CodexDatabase
  let sourceScope: CodexProjectScope
  let childScope: CodexProjectScope
  let host: FixtureProjectServices
  let parent: CodexWorktreeLease
  let childPath: String

  init() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    self.root = root
    sourcePath = root.appendingPathComponent("source.sqlite").path
    sharedPath = root.appendingPathComponent("leases.sqlite").path
    source = try CodexDatabase(path: sourcePath, worktreeLeasePath: sharedPath)
    child = try CodexDatabase(
      path: root.appendingPathComponent("child.sqlite").path, worktreeLeasePath: sharedPath)
    sourceScope = try #require(CodexProjectScope(worktreeOwner(project: "source")))
    childScope = try #require(CodexProjectScope(worktreeOwner(project: "child")))
    childPath = root.appendingPathComponent("checkout").path
    host = FixtureProjectServices(db: source, source: sourceScope, childPath: childPath)
    parent = try CodexWorktreeLeaseManager.acquire(
      database: source, workspaceID: sourceScope.projectID, workspaceURL: root,
      agentID: "source-agent", threadID: nil, runID: nil, parentLeaseID: nil, branch: nil,
      mode: .exclusive, ttlSeconds: 900, liveRuntimeStatus: .object([:]), scope: sourceScope)
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  var manager: CodexHostWorktreeManager {
    .init(database: source, scope: sourceScope, services: host)
  }
  var childManager: CodexHostWorktreeManager {
    .init(database: child, scope: childScope, services: host)
  }

  func owner(project: String, principal: String = "principal") -> CodexRuntimeOwner {
    worktreeOwner(project: project, principal: principal)
  }

  func provider() -> CodexAppServerProvider {
    .init(
      appServer: FakeAppServerRuntime(), owner: owner(project: "source"), database: source,
      workspaceURL: root, recentThreadReader: nil, localControlAllowed: true, projectServices: host)
  }

  func plan() throws -> (String, [String: JSONValue]) {
    let plan = try manager.planProvision(
      selection: .init(["name": .string("example"), "base": .null]),
      agentID: "child-agent", threadID: nil, runID: nil, parentLeaseID: parent.id, ttlSeconds: 900)
    return (
      try #require(plan.objectValue?["id"]?.stringValue),
      try #require(plan.objectValue?["perform_arguments"]?.objectValue)
    )
  }

  func performProvision(_ id: String, request: [String: JSONValue]) async throws
    -> [String: JSONValue]
  {
    let digest = try CodexHostInvocation.digest(request)
    await host.capture(digest, action: .provision)
    return try result(
      await manager.perform(
        id: id, action: .provision, revision: 1, arguments: request, invocation: metadata(newIDs()))
    )
  }

  func acquire(
    in database: CodexDatabase, scope: CodexProjectScope, agent: String, parent: String? = nil
  )
    throws -> CodexWorktreeLease
  {
    try CodexWorktreeLeaseManager.acquire(
      database: database, workspaceID: scope.projectID,
      workspaceURL: URL(fileURLWithPath: childPath),
      agentID: agent, threadID: nil, runID: nil, parentLeaseID: parent, branch: nil,
      mode: parent == nil ? .exclusive : .isolatedWorktree,
      ttlSeconds: 900, liveRuntimeStatus: .object([:]), scope: scope)
  }

  func release(_ lease: CodexWorktreeLease, in database: CodexDatabase) throws {
    _ = try CodexWorktreeLeaseManager.release(
      database: database, workspaceID: lease.workspaceID, leaseID: lease.id,
      expectedRevision: lease.revision, reason: "reviewed")
  }
}

private actor FixtureProjectServices: CodexProjectServices {
  private let db: CodexDatabase
  private let source: CodexProjectScope
  private let childPath: String
  nonisolated let worktreeID = UUID()
  private var digest = ""
  private var action: CodexWorktreeAction = .provision
  private var lostRemovalReply = false
  private var creationFailure: CodexHostWorktreeState?
  private var outcomes: [UUID: JSONValue] = [:]
  private(set) var callbacks: [String] = []
  private(set) var selection: CodexWorktreeSelection?

  init(db: CodexDatabase, source: CodexProjectScope, childPath: String) {
    self.db = db
    self.source = source
    self.childPath = childPath
  }

  func capture(_ digest: String, action: CodexWorktreeAction) {
    self.digest = digest
    self.action = action
  }

  func loseNextRemovalReply() { lostRemovalReply = true }
  func failCreation(as state: CodexHostWorktreeState) { creationFailure = state }

  func validateContract() {}

  func describe(_ inspection: CodexProjectInspection) throws -> CodexHostToolResponse {
    switch inspection {
    case .invocation(let id):
      callbacks.append("inspect-invocation")
      let pending = try db.hostWorktrees(in: source, limit: 20).first {
        $0.state == action.pendingState
      }
      let worktree = try #require(pending)
      let operation = try #require(try db.hostWorktree(id: worktree.id, in: source)?.1)
      #expect(operation.ids.invocationID == id)
      return reply(
        .object([
          "format_version": .integer(1), "invocation_id": .string(id.uuidString),
          "principal_id": .string(source.principalID), "profile_id": .string(source.profileID),
          "project_id": .string(operation.selectedProjectID),
          "tool": .string(action.tool), "host_action": .string(action.rawValue),
          "arguments_digest": .string(digest),
          "operation": envelope(operation.ids, result: .null, state: "reserved"),
        ]))
    case .operation(let id):
      callbacks.append("inspect-operation")
      return reply(try #require(outcomes[id]))
    }
  }

  func add(_ selection: CodexWorktreeSelection, ids: CodexHostOperationIDs)
    -> CodexHostToolResponse
  {
    callbacks.append("add")
    self.selection = selection
    if let creationFailure {
      let error: JSONValue = .object([
        "code": .string("permission.required"), "message": .string("fixture host refused"),
      ])
      let failed = envelope(ids, result: .null, state: creationFailure.rawValue, error: error)
      outcomes[ids.operationID] = failed
      return .init(
        raw: .object([
          "content": .array([
            .object(["type": .string("text"), "text": .string("fixture refusal")])
          ]),
          "structuredContent": .object(["result": failed]), "isError": .bool(true),
        ]))
    }
    return complete(
      ids,
      [
        "worktree_id": .string(worktreeID.uuidString), "project_id": .string("child"),
        "path": .string(childPath), "branch": .string(selection.expectedBranch),
        "base": .string(selection.explicitBase ?? "captured-main"), "warnings": .array([]),
      ])
  }

  func remove(force: Bool, ids: CodexHostOperationIDs) throws -> CodexHostToolResponse {
    callbacks.append("remove")
    #expect(force)
    let result = complete(
      ids,
      [
        "worktree_id": .string(worktreeID.uuidString), "project_id": .string("child"),
        "branch": .string("worktree/example"), "oid": .string(String(repeating: "a", count: 40)),
        "termination_warnings": .array([]),
      ])
    if lostRemovalReply {
      lostRemovalReply = false
      throw MCPError.connectionClosed
    }
    return result
  }

  func list(invocationID: UUID) -> CodexHostToolResponse {
    reply(.object(["worktrees": .array([.object(["owner": .string("foreign")])])]))
  }

  private func complete(_ ids: CodexHostOperationIDs, _ fields: [String: JSONValue])
    -> CodexHostToolResponse
  {
    let completed = envelope(ids, result: .object(fields), state: "completed")
    outcomes[ids.operationID] = completed
    return reply(completed)
  }

  private func envelope(
    _ ids: CodexHostOperationIDs, result: JSONValue, state: String, error: JSONValue = .null
  ) -> JSONValue {
    .object(
      ids.arguments.merging([
        "action": .string(action.rawValue), "source_project_id": .string(source.projectID),
        "project_id": .string(action == .provision ? source.projectID : "child"),
        "state": .string(state), "result": result, "error": error, "extension": .integer(9),
      ]) { current, _ in current })
  }

  private func reply(_ fields: JSONValue) -> CodexHostToolResponse {
    .init(
      raw: .object([
        "content": .array([]), "isError": .bool(false),
        "structuredContent": .object(["result": fields]),
      ]))
  }
}

private func worktreeOwner(project: String, principal: String = "principal") -> CodexRuntimeOwner {
  .init(
    workspaceID: project, profileID: "profile", caller: "local-mcp", transport: nil,
    socketConnectionID: nil, tunnelInstanceID: nil, tunnelProfileID: nil, principalID: principal)
}

private func newIDs() -> CodexHostOperationIDs { .init(invocationID: UUID(), operationID: UUID()) }

private func metadata(_ ids: CodexHostOperationIDs, list: Bool = false) throws
  -> CodexHostInvocation
{
  var fields: [String: MCP.Value] = [
    CodexHostInvocation.invocationKey: .string(ids.invocationID.uuidString)
  ]
  if !list { fields[CodexHostInvocation.operationKey] = .string(ids.operationID.uuidString) }
  return try CodexHostInvocation(.init(additionalFields: fields))
}

private func call(
  _ client: MCP.Client, _ tool: String, _ args: [String: JSONValue],
  ids: CodexHostOperationIDs? = nil
) async throws -> MCP.CallTool.Result {
  let args = try JSONDecoder().decode([String: MCP.Value].self, from: JSONEncoder().encode(args))
  let meta = ids.map {
    MCP.Metadata(additionalFields: [
      CodexHostInvocation.invocationKey: .string($0.invocationID.uuidString),
      CodexHostInvocation.operationKey: .string($0.operationID.uuidString),
    ])
  }
  let request: RequestContext<MCP.CallTool.Result> = try await client.callTool(
    name: tool, arguments: args, meta: meta)
  return try await request.value
}

private func result(_ reply: MCP.CallTool.Result) throws -> [String: JSONValue] {
  let value = try JSONDecoder().decode(
    JSONValue.self, from: JSONEncoder().encode(reply.structuredContent))
  return try #require(value.objectValue?["result"]?.objectValue)
}

private func withMCPClient(
  _ provider: CodexAppServerProvider, body: (MCP.Client) async throws -> Void
) async throws {
  let pair = await InMemoryTransport.createConnectedPair()
  try await pair.server.connect()
  let serving = Task {
    try await CodexAdapterServer.serve(transport: pair.server, appServer: provider)
  }
  let client = MCP.Client(name: "managed-worktree-fixture", version: "1")
  do {
    _ = try await client.connect(transport: pair.client)
    try await body(client)
    await client.disconnect()
    try await serving.value
  } catch {
    await client.disconnect()
    await pair.server.disconnect()
    _ = try? await serving.value
    throw error
  }
}
