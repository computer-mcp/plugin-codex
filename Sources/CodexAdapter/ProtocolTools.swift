import CodexAppServerRuntime
import Foundation
import MCP

struct ProtocolTools: Sendable {
  let inventory: ProtocolInventory

  static let definitions: [Tool] = [
    Tool(
      name: "codex.protocol.methods.list",
      description:
        "List version-specific App Server protocol declarations. Declaration is not execution support or authorization. No Codex process is started. Use the returned cursor for further pages.",
      inputSchema: inputSchema(list: true),
      annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)),
    Tool(
      name: "codex.protocol.methods.describe",
      description:
        "Read a complete App Server message and parameter schema, including reachable recursive definitions. Server requests and notifications are separate directions. No Codex process is started.",
      inputSchema: inputSchema(list: false),
      annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)),
  ]

  func call(name: String, arguments: [String: MCP.Value]) throws -> MCP.CallTool.Result {
    guard Self.definitions.contains(where: { $0.name == name }) else {
      throw MCPError.invalidParams("Unknown adapter tool: \(name).")
    }
    let listing = name == "codex.protocol.methods.list"
    let allowed = Set(["channel", "direction"] + (listing ? ["cursor", "limit"] : ["method"]))
    guard Set(arguments.keys).isSubset(of: allowed) else {
      throw MCPError.invalidParams("Unknown tool arguments.")
    }
    let channelName = try string(arguments, "channel") ?? "stable"
    let directionName = try string(arguments, "direction") ?? "ClientRequest"
    guard let channel = ProtocolInventory.Channel(rawValue: channelName),
      let direction = ProtocolInventory.Direction(rawValue: directionName)
    else { throw MCPError.invalidParams("Unknown schema channel or direction.") }
    let schema = inventory.schema(channel: channel, direction: direction)
    var result: [String: AppServerJSON] = [
      "codex_version": .string(inventory.receipt.codexVersion),
      "channel": .string(channelName), "direction": .string(directionName),
      "schema_sha256": .string(schema.sha256),
    ]
    if listing {
      let limit: Int
      if let value = arguments["limit"] {
        guard case .int(let number) = value, (1...100).contains(number) else {
          throw MCPError.invalidParams("limit must be an integer between 1 and 100.")
        }
        limit = number
      } else {
        limit = 50
      }
      var start = 0
      if let cursor = try string(arguments, "cursor") {
        let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]) == schema.sha256,
          let offset = Int(parts[1]), offset > 0, offset < schema.messages.count
        else { throw MCPError.invalidParams("Invalid or stale schema cursor.") }
        start = offset
      }
      let end = min(start + limit, schema.messages.count)
      result["methods"] = .array(
        schema.messages[start..<end].map {
          .object(["method": .string($0.method), "requires_params": .bool($0.parametersRequired)])
        })
      result["total"] = .number(.integer(Int64(schema.messages.count)))
      if end < schema.messages.count { result["next_cursor"] = .string("\(schema.sha256):\(end)") }
    } else {
      guard let method = try string(arguments, "method"),
        let message = schema.message(named: method)
      else {
        throw MCPError.invalidParams("method must identify a declaration in the selected schema.")
      }
      result["method"] = .string(method)
      result["requires_params"] = .bool(message.parametersRequired)
      result["request_schema"] = try schema.standalone(message.declaration)
      if let parameters = message.parameters {
        result["params_schema"] = try schema.standalone(parameters)
      }
    }
    let value = AppServerJSON.object(result)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let text = String(decoding: try encoder.encode(value), as: UTF8.self)
    return MCP.CallTool.Result(
      content: [.text(text: text, annotations: nil, _meta: nil)],
      structuredContent: Optional.some(Self.mcpValue(value)),
      isError: false)
  }

  private func string(_ arguments: [String: MCP.Value], _ name: String) throws -> String? {
    guard let value = arguments[name] else { return nil }
    guard case .string(let text) = value else {
      throw MCPError.invalidParams("\(name) must be a string.")
    }
    return text
  }

  private static func inputSchema(list: Bool) -> MCP.Value {
    var properties: [String: MCP.Value] = [
      "channel": .object([
        "type": .string("string"), "enum": .array([.string("stable"), .string("experimental")]),
      ]),
      "direction": .object([
        "type": .string("string"),
        "enum": .array(ProtocolInventory.Direction.allCases.map { .string($0.rawValue) }),
      ]),
    ]
    if list {
      properties["cursor"] = .object(["type": .string("string")])
      properties["limit"] = .object([
        "type": .string("integer"), "minimum": .int(1), "maximum": .int(100),
      ])
    } else {
      properties["method"] = .object(["type": .string("string")])
    }
    return .object([
      "type": .string("object"), "properties": .object(properties),
      "additionalProperties": .bool(false), "required": .array(list ? [] : [.string("method")]),
    ])
  }

  static func mcpValue(_ value: AppServerJSON) -> MCP.Value {
    switch value {
    case .null: .null
    case .bool(let value): .bool(value)
    case .number(.integer(let value)): .int(Int(value))
    case .number(.decimal(let value)): .double(NSDecimalNumber(decimal: value).doubleValue)
    case .string(let value): .string(value)
    case .array(let values): .array(values.map(mcpValue))
    case .object(let values): .object(values.mapValues(mcpValue))
    }
  }
}
