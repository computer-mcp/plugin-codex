import CodexAppServerProtocol
import Foundation
import MCP

struct CodexAppServerMethod: Equatable, Sendable {
  let method: String
  let description: String
  let takesParams: Bool
  let risk: CodexOperationRisk
  var channel: ProtocolInventory.Channel = .stable
  var parameterSchema: JSONValue? = nil
  var parametersRequired = false
  var threadParameters: [String: Bool] = [:]

  var toolName: String { "codex.app.native." + method.replacingOccurrences(of: "/", with: ".") }

  func validate(params: JSONValue?) throws {
    var request: [String: JSONValue] = ["id": .integer(1), "method": .string(method)]
    if let params { request["params"] = params }
    let bytes = try JSONEncoder().encode(JSONValue.object(request))
    do {
      switch channel {
      case .stable:
        _ = try JSONDecoder().decode(CodexAppServerProtocol.Stable.ClientRequest.self, from: bytes)
      case .experimental:
        _ = try JSONDecoder().decode(
          CodexAppServerProtocol.Experimental.ClientRequest.self, from: bytes)
      }
    } catch {
      throw CodexToolError.invalidArguments(
        "codex.app.params_invalid: Parameters do not match the SDK's \(channel.rawValue) request type for \(method)."
      )
    }
  }

  var tool: MCP.Tool {
    // Native references remain rooted at the tool schema, including recursive definitions.
    var native = parameterSchema?.objectValue ?? [:]
    let definitions = native.removeValue(forKey: "definitions")
    native.removeValue(forKey: "$schema")
    var schema: [String: JSONValue] = [
      "type": .string("object"),
      "properties": .object(takesParams ? ["params": .object(native)] : [:]),
      "additionalProperties": .bool(false),
    ]
    if parametersRequired { schema["required"] = .array([.string("params")]) }
    if let definitions { schema["definitions"] = definitions }
    return .init(
      name: toolName, description: description,
      inputSchema: try! JSONDecoder().decode(
        MCP.Value.self, from: JSONEncoder().encode(JSONValue.object(schema))),
      annotations: .init(
        readOnlyHint: risk == .readOnly,
        destructiveHint: risk == .destructive || risk == .fullShell,
        idempotentHint: risk == .readOnly, openWorldHint: true),
      outputSchema: .object([
        "type": .string("object"), "properties": .object(["result": .object([:])]),
        "required": .array([.string("result")]), "additionalProperties": .bool(false),
      ]),
      _meta: .init(additionalFields: ["io.github.computer-mcp/risk": .string(risk.rawValue)]))
  }
}

/// SDK adoption defines existence; this package classifies effects and native runtime ownership.
enum CodexAppServerMethodCatalog {
  private static let loaded = Result { try derive(inventory: .bundled()) }

  static var methods: [CodexAppServerMethod] { (try? loaded.get()) ?? [] }

  static func validate() throws { _ = try loaded.get() }

  static func method(named name: String) -> CodexAppServerMethod? {
    methods.first { $0.method == name }
  }

  static func derive(inventory: ProtocolInventory) throws -> [CodexAppServerMethod] {
    var result: [CodexAppServerMethod] = []
    for channel in ProtocolInventory.Channel.allCases {
      let schema = inventory.schema(channel: channel, direction: .clientRequest)
      for name in inventory.adoption.adopted[channel.rawValue] ?? [] {
        guard let declaration = schema.message(named: name), let risk = risk(for: name) else {
          throw SchemaError.invalid("Adopted SDK method lacks projection policy: \(name).")
        }
        let params = try declaration.parameters.map { try JSONValue.encoded(schema.standalone($0)) }
        let takesParams = params != nil && params?.objectValue?["type"] != .string("null")
        result.append(
          .init(
            method: name,
            description:
              "Native Codex \(channel.rawValue) request \(name). Risk: \(risk.rawValue). Native parameters and response fields are preserved; asynchronous events are available through codex.app.events.read.",
            takesParams: takesParams, risk: risk, channel: channel,
            parameterSchema: params,
            parametersRequired: takesParams && declaration.parametersRequired,
            threadParameters: threadParameters(in: params)))
      }
    }
    guard Set(result.map(\.toolName)).count == result.count else {
      throw SchemaError.invalid("Native MCP projection names collide.")
    }
    return result.sorted { $0.method < $1.method }
  }

  private static func threadParameters(in schema: JSONValue?) -> [String: Bool] {
    guard let root = schema?.objectValue else { return [:] }
    let definitions = root["definitions"]?.objectValue ?? [:]
    var pending: [JSONValue] = [.object(root)]
    var visited = Set<String>()
    var fields: [String: Bool] = [:]
    while let value = pending.popLast(), let object = value.objectValue {
      if let reference = object["$ref"]?.stringValue,
        visited.insert(reference).inserted,
        let definition = definitions[String(reference.dropFirst("#/definitions/".count))]
      {
        pending.append(definition)
      }
      let required = object["required"]?.arrayValue ?? []
      for key in ["threadId", "beforeThreadId"] where object["properties"]?.objectValue?[key] != nil
      {
        fields[key] = required.contains(.string(key))
      }
      for key in ["anyOf", "oneOf", "allOf"] { pending += object[key]?.arrayValue ?? [] }
    }
    return fields
  }

  static func risk(for method: String) -> CodexOperationRisk? {
    switch method {
    case "account/rateLimits/read", "account/read", "account/usage/read",
      "account/workspaceMessages/read", "app/installed", "app/list", "app/read", "config/read",
      "configRequirements/read", "experimentalFeature/list", "externalAgentConfig/detect",
      "externalAgentConfig/import/readHistories", "fs/getMetadata", "fs/readDirectory",
      "fs/readFile", "hooks/list", "mcpServer/resource/read", "mcpServerStatus/list", "model/list",
      "modelProvider/capabilities/read", "permissionProfile/list", "plugin/installed",
      "plugin/list", "plugin/read", "plugin/share/list", "plugin/skill/read", "skills/list",
      "thread/goal/get", "thread/items/list", "thread/list", "thread/loaded/list", "thread/read",
      "thread/turns/list", "threadSection/list", "windowsSandbox/readiness",
      "collaborationMode/list", "environment/info", "environment/status", "plugin/search",
      "project/list", "project/read", "remoteControl/client/list", "remoteControl/pairing/status",
      "remoteControl/status/read", "server/diagnostics", "thread/backgroundTerminals/list",
      "thread/queue/list", "thread/realtime/listVoices", "thread/search",
      "thread/searchOccurrences", "thread/timeline/list", "mock/experimentalMethod":
      return .readOnly
    case "thread/goal/clear", "thread/goal/set", "thread/inject_items", "thread/metadata/update",
      "thread/name/set", "thread/rollback", "thread/section/move", "thread/unarchive",
      "thread/unsubscribe", "threadSection/create", "threadSection/update",
      "thread/decrement_elicitation", "thread/increment_elicitation", "thread/memoryMode/set",
      "thread/queue/delete", "thread/queue/reorder", "command/exec/resize", "process/resizePty":
      return .workspaceWrite
    case "account/login/cancel", "account/login/start", "account/logout",
      "account/rateLimitResetCredit/consume", "account/sendAddCreditsNudgeEmail",
      "config/batchWrite", "config/value/write", "experimentalFeature/enablement/set",
      "externalAgentConfig/import", "externalAgentConfig/import/recordHistory", "feedback/upload",
      "fs/copy", "fs/createDirectory", "fs/unwatch", "fs/watch", "fs/writeFile", "marketplace/add",
      "marketplace/upgrade", "mcpServer/oauth/login", "plugin/install", "plugin/share/checkout",
      "plugin/share/save", "plugin/share/updateTargets", "skills/config/write",
      "skills/extraRoots/set", "windowsSandbox/setupStart", "environment/add", "project/create",
      "project/import", "project/move", "project/update", "remoteControl/disable",
      "remoteControl/enable", "remoteControl/pairing/start", "mcpServer/event/stream/start",
      "mcpServer/event/stream/stop":
      return .externalWrite
    case "fs/remove", "marketplace/remove", "plugin/share/delete", "plugin/uninstall",
      "thread/revert", "threadSection/delete", "memory/reset", "project/delete",
      "remoteControl/client/revoke", "thread/backgroundTerminals/clean",
      "thread/backgroundTerminals/terminate", "command/exec/terminate", "process/kill":
      return .destructive
    // Model continuations and native lifecycle hooks can execute user-configured
    // commands. Parameter-level sandbox settings do not lower the host floor.
    case "config/mcpServer/reload", "review/start", "thread/archive", "thread/compact/start",
      "thread/delete", "thread/fork", "thread/queue/add", "thread/queue/start",
      "thread/queue/update", "thread/realtime/appendAudio", "thread/realtime/appendSpeech",
      "thread/realtime/appendText", "thread/realtime/start", "thread/realtime/stop",
      "thread/resume", "thread/settings/update", "thread/start", "turn/interrupt",
      "turn/settings/update", "turn/start", "turn/steer", "command/exec",
      "command/exec/write", "mcpServer/tool/call", "thread/approveGuardianDeniedAction",
      "thread/shellCommand", "process/spawn", "process/writeStdin":
      return .fullShell
    default: return nil
    }
  }
}
