import Foundation
import MCP
import Testing

@testable import CodexAdapter

@Suite(.timeLimit(.minutes(1)))
struct CodexHostMCPClientTests {
  @Test(arguments: ["read-only", "destructive"])
  func executionUsesFreshScopeAndStandardTickets(risk: String) async throws {
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
      #expect(
        calls.map(\.0)
          == (risk == "destructive"
            ? ["policy.probe", "policy.probe", "operations.prepare", "operations.commit"]
            : ["policy.probe", "policy.probe", "file.test"]))
      #expect(calls.allSatisfy { $0.1["workspace_id"] == .string("fixture") })
      if risk == "destructive" {
        #expect(calls.last?.1["ticket_id"] == .string("host-ticket"))
        #expect(calls.last?.1["arguments"] == calls[calls.count - 2].1["arguments"])
      }
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
      await #expect(throws: (any Error).self) {
        try await fixture.client.execute(
          name: "file.test", arguments: .object([:]), requestID: "failed", workspaceID: "fixture")
      }
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
    let owner = CodexRuntimeOwner(
      workspaceID: "fixture", profileID: "fixture", caller: "secure-tunnel",
      transport: "gateway_socket", socketConnectionID: "fixture-socket", tunnelInstanceID: nil,
      tunnelProfileID: nil)
    let client = try CodexHostMCPClient(
      takingOwnershipOf: pair.0, owner: owner,
      requestTimeout: mode == "timeout" ? .milliseconds(40) : .seconds(5))
    let started = ContinuousClock.now
    let call = Task {
      try await client.risk(
        named: "file.test", arguments: .object([:]), requestID: "call", workspaceID: "fixture")
    }
    if mode == "cancel" {
      try await Task.sleep(for: .milliseconds(30))
      call.cancel()
    }
    let result = await call.result
    #expect(started.duration(to: .now) < .seconds(2))
    if case .success = result { Issue.record("Incomplete startup unexpectedly succeeded.") }
    await client.shutdown()
    try pair.1.close()
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
  init() throws {
    let pair = try MCPInheritedSocketTransport.makePair()
    transport = try MCPInheritedSocketTransport(takingOwnershipOf: pair.0)
    client = try CodexHostMCPClient(
      takingOwnershipOf: pair.1,
      owner: .init(
        workspaceID: "fixture", profileID: "fixture", caller: "secure-tunnel",
        transport: "gateway_socket", socketConnectionID: "fixture-socket", tunnelInstanceID: nil,
        tunnelProfileID: nil))
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
