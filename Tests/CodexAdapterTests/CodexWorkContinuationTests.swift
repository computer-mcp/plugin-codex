import Foundation
import MCP
import Testing

@testable import CodexAdapter

struct CodexWorkContinuationTests {
  @Test
  func firstClassAndGenericNativeCallsLocateTheSameKindsOfWork() throws {
    let generic = try selectors("codex.app.methods.call")
    for method in CodexAppServerMethodCatalog.methods {
      let direct = try selectors(method.toolName)
      let dispatched = generic.filter {
        $0["when"]?.objectValue?["values"]?.arrayValue?.contains(.string(method.method)) == true
      }
      #expect(direct.count == dispatched.count, "Missing generic binding for \(method.method)")
      for selector in direct {
        #expect(
          dispatched.contains {
            $0["kind"] == selector["kind"] && $0["handles"] == selector["handles"]
          })
      }
      let tool = try CodexWorkSnapshot.declaring(method.tool)
      #expect(tool.inputSchema == method.tool.inputSchema)
      #expect(tool._meta?["io.github.computer-mcp/risk"] == .string(method.risk.rawValue))
    }
  }

  @Test
  func startsDoNotLocateAnOldLifetimeWithTheSameReusableNativeHandle() throws {
    for method in [
      "command/exec", "process/spawn", "fs/watch", "mcpServer/event/stream/start", "thread/fork",
    ] {
      let descriptor = try #require(CodexAppServerMethodCatalog.method(named: method))
      #expect(
        try selectors(descriptor.toolName).allSatisfy {
          $0["handles"]?.objectValue?["native_id"] == nil
        })
    }
    for name in [
      "codex.exec.start", "codex.exec.resume", "codex.app.thread.start", "codex.app.thread.fork",
    ] {
      #expect(try selectors(name).isEmpty)
    }
    let command = try #require(selectors("codex.app.native.command.exec.write").first)
    #expect(command["kind"] == .string("codex.app.command"))
    #expect(command["handles"] == .object(["native_id": .string("/params/processId")]))
    let process = try #require(selectors("codex.app.native.process.writeStdin").first)
    #expect(process["kind"] == .string("codex.app.process"))
    #expect(process["handles"] == .object(["native_id": .string("/params/processHandle")]))
  }

  @Test
  func optionalNativeThreadScopeAllowsNullWithoutChangingNativeValidation() throws {
    let descriptor = try #require(CodexAppServerMethodCatalog.method(named: "app/read"))
    #expect(descriptor.threadParameters["threadId"] == false)
    let bindings = try selectors(descriptor.toolName)
    #expect(!bindings.isEmpty)
    #expect(
      bindings.allSatisfy {
        $0["nullable_handles"] == .array([.string("thread_id")])
          && $0["handles"] == .object(["thread_id": .string("/params/threadId")])
      })
    let required = try selectors("codex.app.native.turn.start")
    #expect(required.allSatisfy { $0["nullable_handles"] == nil })
  }

  @Test
  func adapterHandlesUseTheirOwnedIdentityAndUnscopedOperationsStayUnscoped() throws {
    #expect(
      try selectors("codex.exec.result") == [
        ["kind": .string("codex.exec.session"), "handles": .object(["id": .string("/session_id")])]
      ])
    #expect(
      try selectors("codex.app.approvals.respond") == [
        [
          "kind": .string("codex.app.server-request"),
          "handles": .object(["approval_id": .string("/approval_id")]),
        ]
      ])
    let owners = try selectors("codex.app.runtimes.stop")
    #expect(owners.count == 16)
    #expect(owners.allSatisfy { $0["handles"] == .object(["runtime_id": .string("/runtime_id")]) })
    for name in [
      "codex.exec.list", "codex.app.status", "codex.app.events.read", "codex.app.requests.list",
      "codex.app.runtime.stop",
    ] {
      #expect(try selectors(name).isEmpty)
    }
  }

  private func selectors(_ name: String) throws -> [[String: JSONValue]] {
    guard let value = try CodexWorkContinuation.declaration(for: name) else { return [] }
    let data = try JSONEncoder().encode(value)
    #expect(data.count <= 16_384)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    let selectors = try #require(decoded.objectValue?["selectors"]?.arrayValue)
    #expect((1...16).contains(selectors.count))
    return try selectors.map { try #require($0.objectValue) }
  }
}
