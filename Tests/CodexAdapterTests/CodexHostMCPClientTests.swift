import Foundation
import MCP
import Testing

@testable import CodexAdapter

@Suite(.timeLimit(.minutes(1)))
struct CodexHostMCPClientTests {
  @Test(arguments: ["read-only", "project-write", "destructive"])
  func executionUsesFreshHostAuthorization(risk: String) async throws {
    let fixture = try HostClientFixture()
    await fixture.state.setRisk(risk)
    try await fixture.start()
    do {
      let arguments: JSONValue = .object(["path": .string("fixture.txt")])
      let decision = try await fixture.client.risk(
        named: "file.test", arguments: arguments, requestID: "call", workspaceID: "fixture")
      #expect(decision.hostValue == risk)
      let result = try await fixture.client.execute(
        name: "file.test", arguments: arguments, requestID: "call", workspaceID: "fixture")
      #expect(result.objectValue?["isError"] == .bool(false))
      let calls = await fixture.state.calls
      #expect(calls.map(\.0) == ["policy.probe", "policy.probe", "file.test"])
      #expect(calls.allSatisfy { $0.1["project_id"] == .string("fixture") })
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
        : change == "nested-workspace" ? .object(["project_id": .string("other")]) : .object([:])
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

  @Test(arguments: [nil, "projects-v0", "projects-v1"] as [String?])
  func lifecycleRequiresObservedHostContract(_ marker: String?) async throws {
    let fixture = try HostClientFixture(peerContract: marker, launchContract: "projects-v1")
    try await fixture.start()
    do {
      let response = try await fixture.client.add(
        CodexWorktreeSelection(["name": .string("change"), "base": .null]),
        ids: .init(invocationID: UUID(), operationID: UUID()))
      #expect(marker == "projects-v1")
      #expect(response.isError == true)
      #expect(response.refusal?.objectValue?["extra"] == .integer(9))
      #expect(response.raw.objectValue?["content"]?.arrayValue?.count == 1)
    } catch let error as CodexProjectContract.Unsupported {
      #expect(marker != "projects-v1")
      #expect(error.observed == marker)
    } catch {
      await fixture.close()
      throw error
    }
    let calls = await fixture.state.calls
    if marker == "projects-v1" {
      #expect(calls.map(\.0) == ["host.projects.worktree_add"])
      #expect(calls.first?.1["base"] == .null)
      #expect(calls.first?.1["branch"] == nil)
    } else {
      #expect(calls.isEmpty)
    }
    await fixture.close()
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
      base: [
        "COMPUTER_MCP_HOST_FD": "3", "COMPUTER_MCP_HOST_READ_HANDLE": "144",
        "COMPUTER_MCP_HOST_WRITE_HANDLE": "148",
      ], systemProxy: .init())
    #expect(environment["COMPUTER_MCP_HOST_FD"] == nil)
    #expect(environment["COMPUTER_MCP_HOST_READ_HANDLE"] == nil)
    #expect(environment["COMPUTER_MCP_HOST_WRITE_HANDLE"] == nil)
  }
}

private final class HostClientFixture: Sendable {
  let state = HostClientState()
  let transport: MCPInheritedSocketTransport
  let client: CodexHostMCPClient
  let server = MCP.Server(name: "host-fixture", version: "1", capabilities: .init(tools: .init()))
  let peerContract: String?
  init(peerContract: String? = nil, launchContract: String? = nil) throws {
    self.peerContract = peerContract
    let pair = try MCPInheritedSocketTransport.makePair()
    transport = try MCPInheritedSocketTransport(takingOwnershipOf: pair.0)
    client = try CodexHostMCPClient(
      takingOwnershipOf: pair.1,
      owner: .init(
        workspaceID: "fixture", profileID: "fixture", caller: "secure-tunnel",
        transport: "gateway_socket", socketConnectionID: "fixture-socket", tunnelInstanceID: nil,
        tunnelProfileID: nil, principalID: "subject-a"), launchContract: launchContract)
  }
  func start() async throws {
    await server.withMethodHandler(MCP.CallTool.self) { [state] params in
      await state.respond(params)
    }
    if let peerContract {
      try await server.start(
        transport: CodexProjectHandshakeTransport(transport, contract: peerContract))
    } else {
      try await server.start(transport: transport)
    }
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
        "risk": .string(risk), "requirements": .object([:]),
      ])
    } else if params.name == "host.projects.worktree_add" {
      return .init(
        content: [.text(text: "fixture refusal", annotations: nil, _meta: nil)],
        structuredContent: .object([
          "error": .object(["code": .string("host.service_denied"), "extra": .int(9)])
        ]), isError: true)
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
