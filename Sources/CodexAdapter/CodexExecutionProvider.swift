import Foundation
import MCP

/// Codex Exec use cases projected over the plugin's standard MCP connection.
struct CodexExecutionProvider: Sendable {
  let exec: (any CodexExecRuntimeProtocol)?

  var tools: [MCP.Tool] {
    exec == nil ? [] : Self.execTools
  }

  func call(name: String, arguments: JSONValue?) async throws -> MCP.CallTool.Result {
    guard let tool = tools.first(where: { $0.name == name }) else {
      throw CodexToolError.unknownTool(name)
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
          model: Self.optionalString("model", in: object),
          options: object["options"]
        )
      case "codex.exec.resume":
        result = try await tryExec().resume(
          upstreamSessionID: Self.requiredString("upstream_session_id", in: object),
          prompt: Self.optionalString("prompt", in: object),
          model: Self.optionalString("model", in: object),
          options: object["options"]
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

  func shutdown() async {
    await exec?.shutdown()
  }

  private func tryExec() throws -> any CodexExecRuntimeProtocol {
    guard let exec else {
      throw CodexToolError.disabled("codex.exec.disabled: Codex Exec is disabled.")
    }
    return exec
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
      "Start an owned Codex Exec JSONL session. Omitted native options inherit Codex configuration; workspace supplies only the initial directory.",
      objectSchema(
        properties: [
          "prompt": stringSchema(), "model": stringSchema(), "options": CodexExecOptions.schema,
        ],
        required: ["prompt"]
      ),
      write: true
    ),
    tool(
      "codex.exec.resume",
      "Resume one upstream Codex Exec session with optional native execution overrides.",
      objectSchema(
        properties: [
          "upstream_session_id": stringSchema(),
          "prompt": stringSchema(),
          "model": stringSchema(),
          "options": CodexExecOptions.schema,
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
