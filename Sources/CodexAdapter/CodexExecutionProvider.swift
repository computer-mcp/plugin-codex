import Foundation
import MCP

/// The existing Exec and Codex MCP use cases projected over the plugin's standard MCP connection.
struct CodexExecutionProvider: Sendable {
  let exec: (any CodexExecRuntimeProtocol)?
  let mcp: (any CodexMCPRuntimeProtocol)?
  let readOnly: Bool

  var tools: [MCP.Tool] {
    (exec == nil ? [] : Self.execTools) + (mcp == nil ? [] : Self.mcpTools)
  }

  func call(name: String, arguments: JSONValue?) async throws -> MCP.CallTool.Result {
    guard let tool = tools.first(where: { $0.name == name }) else {
      throw CodexToolError.unknownTool(name)
    }
    if readOnly && Self.mutatingTools.contains(tool.name) {
      throw CodexToolError.disabled("The bound host profile does not permit this operation.")
    }
    let object = arguments?.objectValue ?? [:]
    guard arguments == nil || arguments?.objectValue != nil,
      Set(object.keys).isSubset(
        of: Set(tool.inputSchema.objectValue?["properties"]?.objectValue?.keys.map { $0 } ?? []))
    else {
      throw CodexToolError.invalidArguments(
        "Arguments must match the tool's declared object schema.")
    }
    let result: JSONValue
    do {
      switch name {
      case "codex.exec.start":
        result = try await tryExec().start(
          prompt: Self.requiredString("prompt", in: object),
          model: Self.optionalString("model", in: object)
        )
      case "codex.exec.resume":
        result = try await tryExec().resume(
          upstreamSessionID: Self.requiredString("upstream_session_id", in: object),
          prompt: Self.optionalString("prompt", in: object)
        )
      case "codex.exec.list":
        result = try await tryExec().list()
      case "codex.exec.events":
        result = try await tryExec().events(
          sessionID: Self.requiredIdentifier("session_id", in: object),
          afterCursor: Self.nonnegativeInt("after_cursor", in: object, default: 0),
          maxResults: Self.boundedInt(
            "max_results",
            in: object,
            default: 100,
            range: 1...1_000
          )
        )
      case "codex.exec.result":
        result = try await tryExec().result(
          sessionID: Self.requiredIdentifier("session_id", in: object)
        )
      case "codex.exec.cancel":
        result = try await tryExec().cancel(
          sessionID: Self.requiredIdentifier("session_id", in: object)
        )

      case "codex.mcp.status":
        result = try await tryMCP().status()
      case "codex.mcp.tools.list":
        result = try await tryMCP().tools()
      case "codex.mcp.run":
        result = try await tryMCP().run(
          prompt: Self.requiredString("prompt", in: object),
          model: Self.optionalString("model", in: object)
        )
      case "codex.mcp.reply":
        result = try await tryMCP().reply(
          threadID: Self.requiredIdentifier("thread_id", in: object),
          prompt: Self.requiredString("prompt", in: object)
        )
      case "codex.mcp.calls.list":
        result = try await tryMCP().calls()
      case "codex.mcp.events":
        result = try await tryMCP().events(
          callID: Self.requiredIdentifier("call_id", in: object),
          afterCursor: Self.nonnegativeInt("after_cursor", in: object, default: 0),
          maxResults: Self.boundedInt(
            "max_results",
            in: object,
            default: 100,
            range: 1...1_000
          )
        )
      case "codex.mcp.result":
        result = try await tryMCP().result(
          callID: Self.requiredIdentifier("call_id", in: object)
        )
      case "codex.mcp.approvals.list":
        result = try await tryMCP().pendingApprovals(
          callID: Self.requiredIdentifier("call_id", in: object)
        )
      case "codex.mcp.approval.respond":
        result = try await tryMCP().respondToApproval(
          callID: Self.requiredIdentifier("call_id", in: object),
          approvalID: Self.requiredIdentifier("approval_id", in: object),
          decision: Self.requiredString("decision", in: object)
        )
      case "codex.mcp.cancel":
        result = try await tryMCP().cancel(
          callID: Self.requiredIdentifier("call_id", in: object)
        )
      default: throw CodexToolError.unknownTool(name)
      }
    } catch let error as CodexToolError {
      throw error
    } catch {
      throw CodexToolError.executionFailed(
        CodexApprovalRedactor.redactString(error.localizedDescription))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(result)
    let value = try JSONDecoder().decode(MCP.Value.self, from: data)
    return .init(
      content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
      structuredContent: .object(["result": value]), isError: false)
  }

  private static let mutatingTools: Set<String> = [
    "codex.exec.start", "codex.exec.resume", "codex.exec.cancel",
    "codex.mcp.run", "codex.mcp.reply", "codex.mcp.approval.respond", "codex.mcp.cancel",
  ]

  func shutdown() async {
    await exec?.shutdown()
    await mcp?.shutdown()
  }

  private func tryExec() throws -> any CodexExecRuntimeProtocol {
    guard let exec else {
      throw CodexToolError.disabled("codex.exec.disabled: Codex Exec is disabled.")
    }
    return exec
  }

  private func tryMCP() throws -> any CodexMCPRuntimeProtocol {
    guard let mcp else {
      throw CodexToolError.disabled("codex.mcp.disabled: Codex MCP is disabled.")
    }
    return mcp
  }

  private static func requiredString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard let value = object[key]?.stringValue,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.utf8.count <= 1_048_576
    else {
      throw CodexToolError.invalidArguments(
        "codex.argument_required: '\(key)' must be a non-empty string."
      )
    }
    return value
  }

  private static func requiredIdentifier(
    _ key: String,
    in object: [String: JSONValue],
    maximumBytes: Int = 1_024
  ) throws -> String {
    try validatedIdentifier(
      requiredString(key, in: object),
      key: key,
      maximumBytes: maximumBytes
    )
  }

  private static func validatedIdentifier(
    _ value: String,
    key: String,
    maximumBytes: Int = 1_024
  ) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count <= maximumBytes,
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
      CodexApprovalRedactor.redactString(trimmed, maximumCharacters: 8_192) == trimmed
    else {
      throw CodexToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be a bounded opaque identifier."
      )
    }
    return trimmed
  }

  private static func optionalString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String? {
    guard let raw = object[key] else { return nil }
    guard let value = raw.stringValue,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.utf8.count <= 1_048_576
    else {
      throw CodexToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be a non-empty string when provided."
      )
    }
    return value
  }

  private static func nonnegativeInt(
    _ key: String,
    in object: [String: JSONValue],
    default defaultValue: Int
  ) throws -> Int {
    let value: Int
    if let raw = object[key] {
      guard let supplied = raw.intValue else {
        throw CodexToolError.invalidArguments(
          "codex.argument_invalid: '\(key)' must be a nonnegative integer."
        )
      }
      value = supplied
    } else {
      value = defaultValue
    }
    guard value >= 0 else {
      throw CodexToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be nonnegative."
      )
    }
    return value
  }

  private static func boundedInt(
    _ key: String,
    in object: [String: JSONValue],
    default defaultValue: Int,
    range: ClosedRange<Int>
  ) throws -> Int {
    let value: Int
    if let raw = object[key] {
      guard let supplied = raw.intValue else {
        throw CodexToolError.invalidArguments(
          "codex.argument_invalid: '\(key)' must be an integer between \(range.lowerBound) and \(range.upperBound)."
        )
      }
      value = supplied
    } else {
      value = defaultValue
    }
    guard range.contains(value) else {
      throw CodexToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be between \(range.lowerBound) and \(range.upperBound)."
      )
    }
    return value
  }

  private static let emptySchema = objectSchema()

  private static let execTools: [MCP.Tool] = [
    tool(
      "codex.exec.start",
      "Start an isolated `codex exec` JSONL session. cwd, sandbox, approval policy, writable roots, and config overrides are fixed locally.",
      objectSchema(
        properties: ["prompt": stringSchema(), "model": stringSchema()],
        required: ["prompt"]
      ),
      write: true
    ),
    tool(
      "codex.exec.resume",
      "Resume one upstream Codex Exec session under the same fixed workspace and policy.",
      objectSchema(
        properties: [
          "upstream_session_id": stringSchema(),
          "prompt": stringSchema(),
        ],
        required: ["upstream_session_id"]
      ),
      write: true
    ),
    tool("codex.exec.list", "List gateway-owned Codex Exec sessions.", emptySchema),
    tool(
      "codex.exec.events",
      "Read JSONL events for one Codex Exec session by monotonic cursor.",
      sessionCursorSchema(id: "session_id")
    ),
    tool(
      "codex.exec.result",
      "Read the terminal result for one completed Codex Exec session.",
      objectSchema(properties: ["session_id": stringSchema()], required: ["session_id"])
    ),
    tool(
      "codex.exec.cancel",
      "Cancel one running Codex Exec session.",
      objectSchema(properties: ["session_id": stringSchema()], required: ["session_id"]),
      write: true
    ),
  ]

  private static let mcpTools: [MCP.Tool] = [
    tool(
      "codex.mcp.status", "Read the persistent `codex mcp-server` connection status.", emptySchema),
    tool("codex.mcp.tools.list", "List tools reported by `codex mcp-server`.", emptySchema),
    tool(
      "codex.mcp.run",
      "Start the Codex MCP `codex` tool with gateway-owned cwd, sandbox, approval policy, and no instruction/config overrides.",
      objectSchema(
        properties: ["prompt": stringSchema(), "model": stringSchema()],
        required: ["prompt"]
      ),
      write: true
    ),
    tool(
      "codex.mcp.reply",
      "Reply to an existing Codex MCP thread.",
      objectSchema(
        properties: ["thread_id": stringSchema(), "prompt": stringSchema()],
        required: ["thread_id", "prompt"]
      ),
      write: true
    ),
    tool("codex.mcp.calls.list", "List gateway-owned Codex MCP calls.", emptySchema),
    tool(
      "codex.mcp.events",
      "Read server messages and approval events for one Codex MCP call by cursor.",
      sessionCursorSchema(id: "call_id")
    ),
    tool(
      "codex.mcp.result",
      "Read the current or terminal result for one Codex MCP call.",
      objectSchema(properties: ["call_id": stringSchema()], required: ["call_id"])
    ),
    tool(
      "codex.mcp.approvals.list",
      "List pending command or patch approvals for one Codex MCP call.",
      objectSchema(properties: ["call_id": stringSchema()], required: ["call_id"])
    ),
    tool(
      "codex.mcp.approval.respond",
      "Allow or deny one pending Codex MCP approval. Allow is accepted only when every cwd, grant root, and patch path stays within the bound workspace.",
      objectSchema(
        properties: [
          "call_id": stringSchema(),
          "approval_id": stringSchema(),
          "decision": .object([
            "type": .string("string"),
            "enum": .array([.string("allow"), .string("deny")]),
          ]),
        ],
        required: ["call_id", "approval_id", "decision"]
      ),
      write: true
    ),
    tool(
      "codex.mcp.cancel",
      "Request cancellation for one active Codex MCP call.",
      objectSchema(properties: ["call_id": stringSchema()], required: ["call_id"]),
      write: true
    ),
  ]

  private static func tool(
    _ name: String, _ description: String, _ inputSchema: JSONValue, write: Bool = false
  ) -> MCP.Tool {
    let title = name.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
      .map { String($0.prefix(1)).uppercased() + $0.dropFirst() }.joined(separator: " ")
    let input = try! JSONDecoder().decode(
      MCP.Value.self, from: JSONEncoder().encode(inputSchema))
    return .init(
      name: name, title: title, description: description, inputSchema: input,
      annotations: .init(
        readOnlyHint: !write, destructiveHint: false, idempotentHint: !write, openWorldHint: write),
      outputSchema: .object([
        "type": .string("object"), "properties": .object(["result": .object([:])]),
        "required": .array([.string("result")]), "additionalProperties": .bool(false),
      ]))
  }

  private static func objectSchema(
    properties: [String: JSONValue] = [:],
    required: [String] = []
  ) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("object"),
      "properties": .object(properties),
      "additionalProperties": .bool(false),
    ]
    if !required.isEmpty {
      schema["required"] = .array(required.map(JSONValue.string))
    }
    return .object(schema)
  }

  private static func sessionCursorSchema(id: String) -> JSONValue {
    objectSchema(
      properties: [
        id: stringSchema(),
        "after_cursor": integerSchema(minimum: 0),
        "max_results": integerSchema(minimum: 1, maximum: 1_000),
      ],
      required: [id]
    )
  }

  private static func stringSchema() -> JSONValue {
    .object([
      "type": .string("string"),
      "minLength": .number(1),
      "maxLength": .number(1_048_576),
    ])
  }

  private static func integerSchema(minimum: Int, maximum: Int? = nil) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("integer"),
      "minimum": .number(Double(minimum)),
    ]
    if let maximum {
      schema["maximum"] = .number(Double(maximum))
    }
    return .object(schema)
  }
}

enum CodexToolError: Error, LocalizedError, Equatable {
  case unknownTool(String)
  case invalidArguments(String)
  case disabled(String)
  case executionFailed(String)
  var errorDescription: String? {
    switch self {
    case .unknownTool(let name): "Unknown tool: \(name)"
    case .invalidArguments(let message), .disabled(let message), .executionFailed(let message):
      message
    }
  }
}
