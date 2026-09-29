import Foundation
import MCP
import Testing

@testable import CodexAdapter

struct CodexNativeProjectionTests {
  @Test(arguments: [
    "thread/start", "thread/resume", "thread/fork", "turn/start", "turn/steer", "review/start",
    "thread/compact/start", "thread/archive", "thread/delete", "turn/interrupt",
    "thread/queue/add", "thread/queue/update", "thread/queue/start", "thread/realtime/start",
    "thread/realtime/appendAudio", "thread/realtime/appendSpeech", "thread/realtime/appendText",
    "thread/realtime/stop", "thread/settings/update", "turn/settings/update",
    "thread/approveGuardianDeniedAction", "config/mcpServer/reload", "thread/goal/set",
    "thread/inject_items", "thread/decrement_elicitation",
  ])
  func nativeExecutionAndContinuationCannotAdvertiseRestrictedRisk(method: String) throws {
    let descriptor = try #require(CodexAppServerMethodCatalog.method(named: method))
    #expect(descriptor.risk == .fullShell)
    #expect(
      descriptor.tool._meta?["io.github.computer-mcp/risk"]
        == .string("full-shell"))
  }

  @Test
  func narrowNativeEffectsKeepTheirOwnClassification() throws {
    for (method, risk) in [
      ("fs/readFile", CodexOperationRisk.readOnly), ("thread/read", .readOnly),
      ("thread/name/set", .workspaceWrite), ("thread/goal/clear", .workspaceWrite),
      ("fs/writeFile", .externalWrite), ("fs/remove", .destructive),
      ("command/exec/terminate", .destructive), ("process/kill", .destructive),
      ("command/exec/resize", .workspaceWrite), ("process/resizePty", .workspaceWrite),
    ] {
      #expect(try #require(CodexAppServerMethodCatalog.method(named: method)).risk == risk)
    }
  }

  @Test func everyAdoptedStableRequestHasOneTypedProjection() throws {
    let inventory = try ProtocolInventory.bundled()
    let methods = try CodexAppServerMethodCatalog.derive(inventory: inventory)
    for channel in ProtocolInventory.Channel.allCases {
      let actual = methods.filter { $0.channel == channel }
      #expect(Set(actual.map(\.method)) == Set(inventory.adoption.adopted[channel.rawValue] ?? []))
      #expect(actual.allSatisfy { $0.risk == CodexAppServerMethodCatalog.risk(for: $0.method) })
    }
    #expect(methods.filter { $0.channel == .stable }.count == 96)
    #expect(methods.filter { $0.channel == .experimental }.count == 51)
    #expect(Set(methods.map(\.toolName)).count == methods.count)
    for exclusion in inventory.adoption.excluded {
      #expect(!methods.contains { $0.method == exclusion.method })
    }
  }

  @Test func schemasPreserveNativeFieldsAndReferences() throws {
    let method = try #require(CodexAppServerMethodCatalog.method(named: "turn/start"))
    let schema = try #require(method.tool.inputSchema.objectValue)
    let params = try #require(schema["properties"]?.objectValue?["params"]?.objectValue)
    #expect(params["$ref"] == .string("#/definitions/TurnStartParams"))
    let fields = schema["definitions"]?.objectValue?["TurnStartParams"]?.objectValue?["properties"]?
      .objectValue
    #expect(fields?["outputSchema"] != nil)
    #expect(fields?["approvalPolicy"] != nil)
    #expect(fields?["toolOutput"] != nil)
    #expect(schema["required"] == .array([.string("params")]))
    #expect(method.threadParameters["threadId"] == true)
    #expect(
      CodexAppServerMethodCatalog.method(named: "app/read")?.threadParameters["threadId"] == false)
    #expect(
      CodexAppServerMethodCatalog.method(named: "thread/section/move")?.threadParameters[
        "beforeThreadId"] == false)
  }

  @Test func nativeTypesRejectMalformedArgumentsAndPreserveExtensions() throws {
    let exec = try #require(CodexAppServerMethodCatalog.method(named: "command/exec"))
    #expect(exec.risk == .fullShell)
    #expect(exec.tool.annotations.readOnlyHint == false)
    #expect(exec.tool.annotations.destructiveHint == true)
    try exec.validate(
      params: .object([
        "command": .array([.string("echo"), .string("hello")]),
        "extension": .object(["integer": .integer(9_007_199_254_740_993)]),
      ]))
    for invalid in [JSONValue.object([:]), .object(["command": .string("echo hello")])] {
      #expect(throws: CodexToolError.self) { try exec.validate(params: invalid) }
    }
    let write = try #require(CodexAppServerMethodCatalog.method(named: "fs/writeFile"))
    #expect(write.risk == .externalWrite)
    #expect(throws: CodexToolError.self) {
      try write.validate(params: .object(["path": .integer(12), "dataBase64": .string("")]))
    }
    try write.validate(params: .object(["path": .string("/tmp/file"), "dataBase64": .string("")]))
  }

  @Test func sdkAdoptionCannotAddAnUnclassifiedMethod() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = Data(
      #"{"oneOf":[{"properties":{"method":{"enum":["future/new"]}},"required":["method"]}]}"#.utf8)
    let adoption = Data(
      #"{"schema":"swift-codex.codex-app-server-method-adoption.v1","upstreamTag":"rust-v1.2.3","adopted":{"stable":["future/new"],"experimental":[]},"excluded":[]}"#
        .utf8)
    var files: [String: Any] = [:]
    for channel in ProtocolInventory.Channel.allCases {
      try FileManager.default.createDirectory(
        at: directory.appendingPathComponent(channel.rawValue), withIntermediateDirectories: true)
      for direction in ProtocolInventory.Direction.allCases {
        let name = "\(channel.rawValue)/\(direction.rawValue).json"
        try request.write(to: directory.appendingPathComponent(name))
        files[name] = ["sha256": AppServerSchema.digest(request), "messages": 1]
      }
    }
    try adoption.write(to: directory.appendingPathComponent("adoption.json"))
    try JSONSerialization.data(withJSONObject: [
      "codexVersion": "1.2.3", "adoptionSHA256": AppServerSchema.digest(adoption), "files": files,
    ]).write(to: directory.appendingPathComponent("receipt.json"))
    let inventory = try ProtocolInventory(directory: directory)
    #expect(throws: SchemaError.self) {
      try CodexAppServerMethodCatalog.derive(inventory: inventory)
    }
  }
}
