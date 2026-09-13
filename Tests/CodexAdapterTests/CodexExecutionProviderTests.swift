import Foundation
import MCP
import Testing

@testable import CodexAdapter

struct CodexExecutionProviderTests {
  @Test(.timeLimit(.minutes(1)))
  func existingExecutionContractsRoundTripOverMCPAndCloseIndependently() async throws {
    let exec = ExecutionSpy()
    let mcp = ExecutionSpy()
    let execution = CodexExecutionProvider(exec: exec, mcp: mcp, readOnly: false)
    let pair = await InMemoryTransport.createConnectedPair()
    // The SDK drops messages delivered before its peer transport is connected.
    try await pair.server.connect()
    let serving = Task {
      try await CodexAdapterServer.serve(transport: pair.server, execution: execution)
    }
    let client = MCP.Client(name: "extraction-tests", version: "1")
    do {
      _ = try await client.connect(transport: pair.client)
      let catalog = try await client.listTools()
      #expect(
        Set(catalog.tools.map(\.name))
          == Set(cases.map(\.name) + ProtocolTools.definitions.map(\.name)))
      for item in cases {
        let request = try await client.send(
          MCP.CallTool.request(
            .init(
              name: item.name, arguments: item.arguments)))
        let result = try await request.value
        #expect(result.isError == false)
        #expect(
          result.structuredContent?.objectValue?["result"]
            == .object([
              "operation": .string(item.operation), "arguments": .object(item.expected),
            ]))
        guard case .text(let text, _, _) = result.content.first else {
          Issue.record("Missing legacy text result for \(item.name)")
          continue
        }
        #expect(
          try JSONDecoder().decode(MCP.Value.self, from: Data(text.utf8))
            == result.structuredContent?.objectValue?["result"])
      }
      let invalid = try await client.callTool(name: "codex.exec.start", arguments: [:])
      #expect(invalid.isError == true)
      await #expect(throws: MCPError.self) { try await client.callTool(name: "codex.unknown") }
      await client.disconnect()
      try await serving.value
    } catch {
      await client.disconnect()
      await pair.server.disconnect()
      _ = try? await serving.value
      throw error
    }
    #expect(await exec.operations.count == 6)
    #expect(await mcp.operations.count == 10)
    #expect(await exec.shutdowns == 1)
    #expect(await mcp.shutdowns == 1)
  }

  @Test func readOnlyAndInvalidArgumentsNeverReachExecution() async throws {
    let spy = ExecutionSpy()
    let provider = CodexExecutionProvider(exec: spy, mcp: spy, readOnly: true)
    for item in cases where item.write {
      let args = try JSONDecoder().decode(
        JSONValue.self, from: JSONEncoder().encode(item.arguments))
      await #expect(throws: CodexToolError.self) {
        try await provider.call(name: item.name, arguments: args)
      }
    }
    await #expect(throws: CodexToolError.self) {
      try await provider.call(
        name: "codex.exec.list", arguments: .object(["cwd": .string("/outside")]))
    }
    await #expect(throws: CodexToolError.self) {
      try await provider.call(name: "codex.exec.list", arguments: .array([]))
    }
    #expect(await spy.operations.isEmpty)
    _ = try await provider.call(name: "codex.exec.list", arguments: nil)
    #expect(await spy.operations == ["exec.list"])
  }

  private struct CallCase {
    let name: String
    let operation: String
    let arguments: [String: MCP.Value]
    let expected: [String: MCP.Value]
    let write: Bool
    init(
      _ name: String, _ arguments: [String: MCP.Value] = [:], expected: [String: MCP.Value]? = nil,
      write: Bool = false
    ) {
      self.name = "codex." + name
      operation = name
      self.arguments = arguments
      self.expected = expected ?? arguments
      self.write = write
    }
  }

  private var cases: [CallCase] {
    [
      .init("exec.start", ["prompt": .string("hello"), "model": .string("test")], write: true),
      .init(
        "exec.resume", ["upstream_session_id": .string("upstream")],
        expected: ["upstream_session_id": .string("upstream"), "prompt": .null], write: true),
      .init("exec.list"),
      .init(
        "exec.events", ["session_id": .string("session")],
        expected: [
          "session_id": .string("session"), "after_cursor": .int(0), "max_results": .int(100),
        ]),
      .init("exec.result", ["session_id": .string("session")]),
      .init("exec.cancel", ["session_id": .string("session")], write: true),
      .init("mcp.status"), .init("mcp.tools.list"),
      .init(
        "mcp.run", ["prompt": .string("hello")],
        expected: ["prompt": .string("hello"), "model": .null], write: true),
      .init(
        "mcp.reply", ["thread_id": .string("thread"), "prompt": .string("continue")], write: true),
      .init("mcp.calls.list"),
      .init(
        "mcp.events", ["call_id": .string("call"), "after_cursor": .int(3), "max_results": .int(7)]),
      .init("mcp.result", ["call_id": .string("call")]),
      .init("mcp.approvals.list", ["call_id": .string("call")]),
      .init(
        "mcp.approval.respond",
        [
          "call_id": .string("call"), "approval_id": .string("approval"),
          "decision": .string("approved"),
        ], write: true),
      .init("mcp.cancel", ["call_id": .string("call")], write: true),
    ]
  }
}

private actor ExecutionSpy: CodexExecRuntimeProtocol, CodexMCPRuntimeProtocol {
  var operations: [String] = []
  var shutdowns = 0
  func record(_ operation: String, _ arguments: [String: JSONValue] = [:]) -> JSONValue {
    operations.append(operation)
    return .object(["operation": .string(operation), "arguments": .object(arguments)])
  }
  func start(prompt: String, model: String?) -> JSONValue {
    record(
      "exec.start", ["prompt": .string(prompt), "model": model.map(JSONValue.string) ?? .null])
  }
  func resume(upstreamSessionID: String, prompt: String?) -> JSONValue {
    record(
      "exec.resume",
      [
        "upstream_session_id": .string(upstreamSessionID),
        "prompt": prompt.map(JSONValue.string) ?? .null,
      ])
  }
  func list() -> JSONValue { record("exec.list") }
  func events(sessionID: String, afterCursor: Int, maxResults: Int) -> JSONValue {
    record(
      "exec.events",
      [
        "session_id": .string(sessionID), "after_cursor": .number(Double(afterCursor)),
        "max_results": .number(Double(maxResults)),
      ])
  }
  func result(sessionID: String) -> JSONValue {
    record("exec.result", ["session_id": .string(sessionID)])
  }
  func cancel(sessionID: String) -> JSONValue {
    record("exec.cancel", ["session_id": .string(sessionID)])
  }
  func status() -> JSONValue { record("mcp.status") }
  func tools() -> JSONValue { record("mcp.tools.list") }
  func run(prompt: String, model: String?) -> JSONValue {
    record("mcp.run", ["prompt": .string(prompt), "model": model.map(JSONValue.string) ?? .null])
  }
  func reply(threadID: String, prompt: String) -> JSONValue {
    record("mcp.reply", ["thread_id": .string(threadID), "prompt": .string(prompt)])
  }
  func calls() -> JSONValue { record("mcp.calls.list") }
  func events(callID: String, afterCursor: Int, maxResults: Int) -> JSONValue {
    record(
      "mcp.events",
      [
        "call_id": .string(callID), "after_cursor": .number(Double(afterCursor)),
        "max_results": .number(Double(maxResults)),
      ])
  }
  func result(callID: String) -> JSONValue { record("mcp.result", ["call_id": .string(callID)]) }
  func pendingApprovals(callID: String) -> JSONValue {
    record("mcp.approvals.list", ["call_id": .string(callID)])
  }
  func respondToApproval(callID: String, approvalID: String, decision: String) -> JSONValue {
    record(
      "mcp.approval.respond",
      [
        "call_id": .string(callID), "approval_id": .string(approvalID),
        "decision": .string(decision),
      ])
  }
  func cancel(callID: String) -> JSONValue { record("mcp.cancel", ["call_id": .string(callID)]) }
  func shutdown() { shutdowns += 1 }
}
