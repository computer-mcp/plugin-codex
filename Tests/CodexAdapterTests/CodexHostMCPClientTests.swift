import Foundation
import MCP
import Testing

@testable import CodexAdapter

@Suite(.timeLimit(.minutes(1)))
struct CodexHostMCPClientTests {
  @Test(arguments: ["read-only", "destructive"])
  func executionUsesFreshHostAuthorizationWithoutImplicitTickets(risk: String) async throws {
    let fixture = try HostClientFixture()
    await fixture.state.setRisk(risk)
    try await fixture.start()
    do {
      let arguments: JSONValue = .object(["path": .string("fixture.txt")])
      let decision = try await fixture.client.risk(
        named: "file.test", arguments: arguments, requestID: "call", workspaceID: "fixture")
      #expect(decision.rawValue == risk)
      let result = try await fixture.client.execute(
        name: "file.test", arguments: arguments, requestID: "call", workspaceID: "fixture")
      #expect(result.objectValue?["isError"] == .bool(false))
      let calls = await fixture.state.calls
      #expect(calls.map(\.0) == ["policy.probe", "policy.probe", "file.test"])
      #expect(calls.allSatisfy { $0.1["workspace_id"] == .string("fixture") })
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }

  @Test
  func changedClassificationDoesNotTurnReadOnlyApprovalIntoAMutation() async throws {
    let fixture = try HostClientFixture()
    try await fixture.start()
    do {
      _ = try await fixture.client.risk(
        named: "file.test", arguments: .object([:]), requestID: "call", workspaceID: "fixture")
      await fixture.state.setRisk("external-write")
      await #expect(throws: (any Error).self) {
        try await fixture.client.execute(
          name: "file.test", arguments: .object([:]), requestID: "call", workspaceID: "fixture")
      }
      #expect(await fixture.state.calls.map(\.0) == ["policy.probe", "policy.probe"])
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }

  @Test(arguments: ["workspace", "nested-workspace", "arguments", "name", "missing-decision"])
  func executionCannotChangeItsPreflightIdentity(change: String) async throws {
    let fixture = try HostClientFixture()
    try await fixture.start()
    do {
      if change != "missing-decision" {
        _ = try await fixture.client.risk(
          named: "file.test", arguments: .object([:]), requestID: "call", workspaceID: "fixture")
      }
      let arguments: JSONValue =
        change == "arguments"
        ? .object(["extra": .bool(true)])
        : change == "nested-workspace" ? .object(["workspace_id": .string("other")]) : .object([:])
      await #expect(throws: (any Error).self) {
        try await fixture.client.execute(
          name: change == "name" ? "file.other" : "file.test", arguments: arguments,
          requestID: "call", workspaceID: change == "workspace" ? "other" : "fixture")
      }
      #expect(await fixture.state.calls.count == (change == "missing-decision" ? 0 : 1))
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }

  @Test
  func errorResultIsNotReportedAsSuccessfulAndDoesNotRetireHealthyConnection() async throws {
    let fixture = try HostClientFixture()
    try await fixture.start()
    do {
      _ = try await fixture.client.risk(
        named: "file.test", arguments: .object([:]), requestID: "failed", workspaceID: "fixture")
      await fixture.state.setFailExecution(true)
      let failed = try await fixture.client.execute(
        name: "file.test", arguments: .object([:]), requestID: "failed", workspaceID: "fixture")
      #expect(failed.objectValue?["isError"] == .bool(true))
      #expect(
        failed.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["message"]
          == .string("fixture rejection"))
      await fixture.state.setFailExecution(false)
      _ = try await fixture.client.risk(
        named: "file.test", arguments: .object([:]), requestID: "next", workspaceID: "fixture")
      let result = try await fixture.client.execute(
        name: "file.test", arguments: .object([:]), requestID: "next", workspaceID: "fixture")
      #expect(result.objectValue?["isError"] == .bool(false))
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }

  @Test(arguments: ["timeout", "cancel"])
  func incompleteHostStartupHasABoundedAndJoinedExit(mode: String) async throws {
    let pair = try MCPInheritedSocketTransport.makePair()
    let peer = try MCPInheritedSocketTransport(takingOwnershipOf: pair.1)
    if mode == "cancel" { try await peer.connect() }
    let owner = CodexRuntimeOwner(
      workspaceID: "fixture", profileID: "fixture", caller: "secure-tunnel",
      transport: "gateway_socket", socketConnectionID: "fixture-socket", tunnelInstanceID: nil,
      tunnelProfileID: nil)
    let client = try CodexHostMCPClient(
      takingOwnershipOf: pair.0, owner: owner,
      requestTimeout: mode == "timeout" ? .milliseconds(200) : .seconds(10))
    let started = ContinuousClock.now
    let call = Task {
      try await client.risk(
        named: "file.test", arguments: .object([:]), requestID: "call", workspaceID: "fixture")
    }
    do {
      var messages = await peer.receive().makeAsyncIterator()
      if mode == "cancel" {
        let initialize = try #require(try await messages.next())
        let request = try JSONDecoder().decode(JSONValue.self, from: initialize)
        #expect(request.objectValue?["method"] == .string("initialize"))
        call.cancel()
      }
      let result = await call.result
      await client.shutdown()
      await client.shutdown()
      #expect(started.duration(to: .now) < .seconds(2))
      if case .success = result { Issue.record("Incomplete startup unexpectedly succeeded.") }
      // The deadline may close startup before the peer reads its initialization frame.
      if mode == "timeout" { try await peer.connect() }
      // A joined disconnect closes the peer, including the transport reader.
      do {
        var remaining = 0
        while let message = try await messages.next() {
          remaining += 1
          #expect(mode == "timeout" && remaining == 1)
          let request = try JSONDecoder().decode(JSONValue.self, from: message)
          #expect(request.objectValue?["method"] == .string("initialize"))
        }
      } catch let error as MCPError {
        #expect(error == .connectionClosed)
      }
      await peer.disconnect()
    } catch {
      call.cancel()
      await client.shutdown()
      await peer.disconnect()
      _ = await call.result
      throw error
    }
  }

  @Test(arguments: ["same", "different", "unbound"])
  func managedWorkspaceOwnershipUsesSubjectNotChannel(_ binding: String) async throws {
    let fixture = try HostClientFixture(principalID: "subject-a")
    try await fixture.start()
    var worktree = CodexManagedWorktree(
      id: "worktree", sourceWorkspaceID: "fixture", workspaceID: "child",
      sourceRepositoryRoot: "/tmp/source", gitCommonDirectory: "/tmp/source/.git",
      path: "/tmp/child", branch: "codex/fixture", startPoint: "HEAD", headOID: "head",
      agentID: "agent", threadID: nil, runID: nil, parentLeaseID: "lease", profileID: "fixture",
      caller: "local-mcp", ttlSeconds: 60, leaseID: nil, state: .active, createdAt: Date(),
      updatedAt: Date(), planExpiresAt: nil, removedAt: nil, lastError: nil, revision: 1)
    worktree.principalID =
      binding == "unbound" ? nil : (binding == "same" ? "subject-a" : "subject-b")
    do {
      if binding == "same" {
        try await fixture.client.authorizeRemoval(worktree)
        let calls = await fixture.state.calls
        #expect(calls.count == 1)
        #expect(calls.first?.1["worktree"]?.objectValue?["principal_id"] == .string("subject-a"))
      } else {
        await #expect(throws: CodexToolError.self) {
          try await fixture.client.authorizeRemoval(worktree)
        }
        #expect(await fixture.state.calls.isEmpty)
      }
      let decoded = try JSONDecoder().decode(
        CodexManagedWorktree.self, from: JSONEncoder().encode(worktree))
      #expect(decoded.principalID == worktree.principalID)
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }

  @Test
  func spoofedOrMissingDescriptorNeverFallsBackToAnotherHost() throws {
    let context = try CodexLaunchContext(
      environment: [:], currentDirectory: URL(fileURLWithPath: "/tmp"))
    #expect(try CodexHostMCPClient.inherited(environment: [:], context: context) == nil)
    for value in ["0", "1", "2", "-1", "999", "03", "not-a-number"] {
      #expect(throws: (any Error).self) {
        try CodexHostMCPClient.inherited(
          environment: ["COMPUTER_MCP_HOST_FD": value], context: context)
      }
    }
    let environment = CodexProcessEnvironment.resolved(
      base: ["COMPUTER_MCP_HOST_FD": "3"], systemProxy: .init())
    #expect(environment["COMPUTER_MCP_HOST_FD"] == nil)
  }
}

private final class HostClientFixture: Sendable {
  let state = HostClientState()
  let transport: MCPInheritedSocketTransport
  let client: CodexHostMCPClient
  let server = MCP.Server(name: "host-fixture", version: "1", capabilities: .init(tools: .init()))
  init(principalID: String? = nil) throws {
    let pair = try MCPInheritedSocketTransport.makePair()
    transport = try MCPInheritedSocketTransport(takingOwnershipOf: pair.0)
    client = try CodexHostMCPClient(
      takingOwnershipOf: pair.1,
      owner: .init(
        workspaceID: "fixture", profileID: "fixture", caller: "secure-tunnel",
        transport: "gateway_socket", socketConnectionID: "fixture-socket", tunnelInstanceID: nil,
        tunnelProfileID: nil, principalID: principalID))
  }
  func start() async throws {
    await server.withMethodHandler(MCP.CallTool.self) { [state] params in
      await state.respond(params)
    }
    try await server.start(transport: transport)
  }
  func close() async {
    await client.shutdown()
    await transport.disconnect()
    await server.stop()
  }
}

private actor HostClientState {
  private var risk = "read-only"
  private var failExecution = false
  private(set) var calls: [(String, [String: MCP.Value])] = []
  func setRisk(_ value: String) { risk = value }
  func setFailExecution(_ value: Bool) { failExecution = value }
  func respond(_ params: MCP.CallTool.Parameters) -> MCP.CallTool.Result {
    let arguments = params.arguments ?? [:]
    calls.append((params.name, arguments))
    let result: MCP.Value
    if params.name == "policy.probe" {
      result = .object([
        "decision": .string("allowed"), "capability_id": arguments["capability_id"]!,
        "workspace_id": .string("fixture"), "risk": .string(risk), "effective_risk": .string(risk),
      ])
    } else if params.name == "host.workspaces.authorize_removal" {
      result = .object(["authorized": .bool(true)])
    } else if params.name == "operations.prepare" {
      result = .object(["ticket_id": .string("host-ticket")])
    } else if failExecution {
      return .init(
        content: [],
        structuredContent: .object(["error": .object(["message": .string("fixture rejection")])]),
        isError: true)
    } else {
      result = .object(["accepted": .bool(true)])
    }
    return .init(content: [], structuredContent: .object(["result": result]), isError: false)
  }
}
