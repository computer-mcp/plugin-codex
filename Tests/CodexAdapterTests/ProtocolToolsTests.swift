import Foundation
import MCP
import Testing

@testable import CodexAdapter

struct ProtocolToolsTests {
  @Test func pagesCoverEveryDeclaredMethodExactlyOnce() throws {
    let tools = ProtocolTools(inventory: try .bundled())
    var arguments: [String: MCP.Value] = ["limit": .int(13)]
    var methods: [String] = []
    repeat {
      let value = try payload(tools.call(name: "codex.protocol.methods.list", arguments: arguments))
      let page = try #require(value["methods"]?.arrayValue)
      #expect(page.count <= 13)
      methods += page.compactMap { $0.objectValue?["method"]?.stringValue }
      arguments["cursor"] = value["next_cursor"]
    } while arguments["cursor"] != nil
    #expect(methods.count == 99)
    #expect(Set(methods).count == 99)
    #expect(methods == methods.sorted())
  }

  @Test func channelChangesInvalidateCursor() throws {
    let tools = ProtocolTools(inventory: try .bundled())
    let first = try payload(
      tools.call(name: "codex.protocol.methods.list", arguments: ["limit": .int(2)]))
    let cursor = try #require(first["next_cursor"])
    #expect(throws: MCPError.self) {
      try tools.call(
        name: "codex.protocol.methods.list",
        arguments: ["cursor": cursor, "channel": .string("experimental")])
    }
  }

  @Test func describeReturnsParameterDefinitionsAndExactText() throws {
    let tools = ProtocolTools(inventory: try .bundled())
    let result = try tools.call(
      name: "codex.protocol.methods.describe", arguments: ["method": .string("thread/goal/set")])
    let value = try payload(result)
    #expect(value["codex_version"] == .string("0.153.4"))
    #expect(value["requires_params"] == .bool(true))
    let params = try #require(value["params_schema"]?.objectValue)
    let definitions = try #require(params["definitions"]?.objectValue)
    #expect(definitions["ThreadGoalSetParams"] != nil)
    guard case .text(let text, _, _) = result.content.first else {
      Issue.record("Missing text result.")
      return
    }
    #expect(
      try JSONDecoder().decode(MCP.Value.self, from: Data(text.utf8)) == result.structuredContent)
  }

  @Test(arguments: [
    ["limit": MCP.Value.int(0)], ["limit": .double(2.5)], ["limit": .int(101)],
    ["cursor": .string("bad")], ["direction": .null], ["extra": .bool(true)],
  ])
  func rejectsMalformedListArguments(arguments: [String: MCP.Value]) throws {
    let tools = ProtocolTools(inventory: try .bundled())
    #expect(throws: MCPError.self) {
      try tools.call(name: "codex.protocol.methods.list", arguments: arguments)
    }
  }

  @Test func unknownToolIsRejected() throws {
    let tools = ProtocolTools(inventory: try .bundled())
    #expect(throws: MCPError.self) {
      try tools.call(
        name: "codex.app.unknown", arguments: [:])
    }
  }

  @Test func tamperedReceiptCannotCreateInventory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"codexVersion":"0.153.4","files":{}}"#.utf8).write(
      to: directory.appendingPathComponent("receipt.json"))
    #expect(throws: SchemaError.self) { try ProtocolInventory(directory: directory) }
  }

  private func payload(_ result: MCP.CallTool.Result) throws -> [String: MCP.Value] {
    #expect(result.isError == false)
    return try #require(result.structuredContent?.objectValue)
  }

  @Test(arguments: ["bytes", "count"])
  func inventoryChecksEveryReceiptedFile(tamper: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data(
      #"{"oneOf":[{"type":"object","properties":{"method":{"enum":["test"]}},"required":["method"]}]}"#
        .utf8)
    var files: [String: Any] = [:]
    for channel in ProtocolInventory.Channel.allCases {
      let subdirectory = directory.appendingPathComponent(channel.rawValue)
      try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
      for direction in ProtocolInventory.Direction.allCases {
        let path = "\(channel.rawValue)/\(direction.rawValue).json"
        try bytes.write(to: directory.appendingPathComponent(path))
        files[path] = ["sha256": AppServerSchema.digest(bytes), "messages": 1]
      }
    }
    let receiptURL = directory.appendingPathComponent("receipt.json")
    try JSONSerialization.data(withJSONObject: ["codexVersion": "1.2.3", "files": files]).write(
      to: receiptURL)
    #expect(try ProtocolInventory(directory: directory).receipt.codexVersion == "1.2.3")
    let target = "experimental/ServerNotification.json"
    if tamper == "bytes" {
      try (bytes + Data([32])).write(to: directory.appendingPathComponent(target))
    } else {
      files[target] = ["sha256": AppServerSchema.digest(bytes), "messages": 2]
      try JSONSerialization.data(withJSONObject: ["codexVersion": "1.2.3", "files": files]).write(
        to: receiptURL)
    }
    #expect(throws: SchemaError.self) { try ProtocolInventory(directory: directory) }
  }

}
