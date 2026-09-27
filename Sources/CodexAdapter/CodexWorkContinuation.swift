import Foundation
import MCP

/// Locators describe existing adapter-owned work, independently of authorization.
enum CodexWorkContinuation {
  static let metadataKey = "io.github.computer-mcp/continuation"

  private static let threadKinds = [
    "thread", "turn", "goal", "queued-input", "server-request", "realtime", "mcp-login",
  ]
  private static let runtimeKinds =
    threadKinds + [
      "call", "startup", "cleanup", "command", "process", "watch", "stream", "login",
      "remote-control",
    ]

  private struct Selector {
    let kind: String
    let handles: [String: String]
    var nullable: Set<String> = []
    var methods: [String] = []

    var value: MCP.Value {
      var fields: [String: MCP.Value] = [
        "kind": .string(kind), "handles": .object(handles.mapValues(MCP.Value.string)),
      ]
      if !nullable.isEmpty {
        fields["nullable_handles"] = .array(nullable.sorted().map(MCP.Value.string))
      }
      if !methods.isEmpty {
        fields["when"] = .object([
          "pointer": .string("/method"), "values": .array(methods.sorted().map(MCP.Value.string)),
        ])
      }
      return .object(fields)
    }
  }

  static func declaration(for name: String) throws -> MCP.Value? {
    let selectors: [Selector]
    if name == "codex.app.methods.call" {
      var grouped: [Selector] = []
      for method in CodexAppServerMethodCatalog.methods {
        for selector in nativeSelectors(method) {
          if let index = grouped.firstIndex(where: {
            $0.kind == selector.kind && $0.handles == selector.handles
          }) {
            grouped[index].methods.append(method.method)
            grouped[index].nullable.formUnion(selector.nullable)
          } else {
            var conditional = selector
            conditional.methods = [method.method]
            grouped.append(conditional)
          }
        }
      }
      selectors = grouped
    } else if let method = CodexAppServerMethodCatalog.methods.first(where: { $0.toolName == name })
    {
      selectors = nativeSelectors(method)
    } else {
      selectors = adapterSelectors(name)
    }
    guard !selectors.isEmpty else { return nil }
    let value = MCP.Value.object([
      "format_version": .int(1), "selectors": .array(selectors.map(\.value)),
    ])
    guard selectors.count <= 16, selectors.allSatisfy({ $0.methods.count <= 64 }),
      try JSONEncoder().encode(value).count <= 16_384
    else {
      throw SchemaError.invalid("Codex continuation declarations exceed the host metadata bounds.")
    }
    return value
  }

  private static func nativeSelectors(_ method: CodexAppServerMethod) -> [Selector] {
    switch method.method {
    case "command/exec/write", "command/exec/resize", "command/exec/terminate":
      return [nativeHandle("command", field: "processId")]
    case "process/writeStdin", "process/resizePty", "process/kill":
      return [nativeHandle("process", field: "processHandle")]
    case "fs/unwatch": return [nativeHandle("watch", field: "watchId")]
    case "mcpServer/event/stream/stop": return [nativeHandle("stream", field: "subscriptionId")]
    case "account/login/cancel":
      return [.init(kind: "codex.app.login", handles: ["login_id": "/params/loginId"])]
    default: break
    }
    // A fork creates another task; its source thread is not the new task's owner.
    guard method.method != "thread/fork", let required = method.threadParameters["threadId"] else {
      return []
    }
    return threadSelectors(pointer: "/params/threadId", nullable: !required)
  }

  private static func nativeHandle(_ kind: String, field: String) -> Selector {
    .init(kind: "codex.app." + kind, handles: ["native_id": "/params/" + field])
  }

  private static func threadSelectors(pointer: String, nullable: Bool = false) -> [Selector] {
    threadKinds.map {
      .init(
        kind: "codex.app." + $0, handles: ["thread_id": pointer],
        nullable: nullable ? ["thread_id"] : [])
    }
  }

  private static func adapterSelectors(_ name: String) -> [Selector] {
    switch name {
    case "codex.exec.events", "codex.exec.result", "codex.exec.cancel", "codex.exec.release":
      return [.init(kind: "codex.exec.session", handles: ["id": "/session_id"])]
    case "codex.app.thread.reclaim", "codex.app.thread.read", "codex.app.thread.turns.list",
      "codex.app.thread.items.list", "codex.app.thread.recent", "codex.app.thread.release",
      "codex.app.handoff.diagnose", "codex.app.goal.get", "codex.app.goal.set",
      "codex.app.goal.clear",
      "codex.app.turn.start", "codex.app.turn.steer", "codex.app.turn.interrupt",
      "codex.app.review.start":
      return threadSelectors(pointer: "/thread_id")
    case "codex.app.requests.respond":
      return [.init(kind: "codex.app.server-request", handles: ["request_id": "/request_id"])]
    case "codex.app.approvals.read", "codex.app.approvals.respond":
      return [.init(kind: "codex.app.server-request", handles: ["approval_id": "/approval_id"])]
    case "codex.app.runtimes.inspect", "codex.app.runtimes.stop":
      return runtimeKinds.map {
        .init(kind: "codex.app." + $0, handles: ["runtime_id": "/runtime_id"])
      }
    default: return []
    }
  }
}
