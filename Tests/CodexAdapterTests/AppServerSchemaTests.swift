import Foundation
import MCP
import Testing

@testable import CodexAdapter

struct AppServerSchemaTests {
  @Test func inventoryMatchesVersionSpecificExports() throws {
    let inventory = try ProtocolInventory.bundled()
    #expect(inventory.receipt.codexVersion == "0.154.0")
    for (channel, counts) in [
      (ProtocolInventory.Channel.stable, [99, 1, 10, 81]), (.experimental, [159, 1, 11, 81]),
    ] {
      for (direction, count) in zip(ProtocolInventory.Direction.allCases, counts) {
        let schema = inventory.schema(channel: channel, direction: direction)
        #expect(schema.messages.count == count)
        #expect(Set(schema.messages.map(\.method)).count == count)
        for message in schema.messages {
          _ = try schema.standalone(message.declaration)
          if let params = message.parameters { _ = try schema.standalone(params) }
        }
      }
    }
    let schema = inventory.schema(channel: .stable, direction: .clientRequest)
    for method in ["thread/goal/get", "thread/goal/set", "thread/goal/clear"] {
      #expect(try #require(schema.message(named: method)).parametersRequired)
    }
  }

  @Test func recursiveReferencesRemainFiniteAndComplete() throws {
    let schema = try fixture(
      parameters: .object(["$ref": .string("#/definitions/Node")]),
      definitions: [
        "Node": .object([
          "type": .string("object"),
          "properties": .object([
            "next": .object(["$ref": .string("#/definitions/Node")]),
            "leaf": .object(["$ref": .string("#/definitions/A~1B~0")]),
          ]),
        ]),
        "A/B~": .object(["type": .string("string")]),
        "Unused": .object(["type": .string("number")]),
      ])
    let message = try #require(schema.messages.first)
    let standalone = try schema.standalone(#require(message.parameters))
    guard case .object(let root) = standalone, case .object(let definitions) = root["definitions"]
    else {
      Issue.record("Missing self-contained definitions.")
      return
    }
    #expect(Set(definitions.keys) == ["Node", "A/B~"])
    #expect(root["$ref"] == .string("#/definitions/Node"))
  }

  @Test(arguments: [
    "#/definitions/Missing", "https://example.invalid/schema", "#/definitions/A~2",
    "#/definitions/A/child",
  ])
  func rejectsUnresolvableReferences(reference: String) throws {
    #expect(throws: SchemaError.self) {
      try fixture(
        parameters: .object(["$ref": .string(reference)]), definitions: ["A~2": .object([:])])
    }
  }

  @Test func schemaKeywordsDoNotInterpretLiteralValues() throws {
    let literal: AppServerJSON = .object([
      "$ref": .string("not-a-schema"), "data": .string("data:text/plain;base64,SGk="),
    ])
    let params: AppServerJSON = .object([
      "type": .string("object"), "default": literal, "examples": .array([literal]),
      "const": literal, "enum": .array([literal]), "x-vendor-extension": literal,
    ])
    let schema = try fixture(parameters: params)
    guard case .object(let standalone) = try schema.standalone(params) else {
      Issue.record("Expected schema object.")
      return
    }
    #expect(standalone["default"] == literal)
    #expect(standalone["x-vendor-extension"] == literal)
  }

  @Test func requiredAndAbsentParamsRemainDistinct() throws {
    #expect(try fixture(parameters: nil, required: false).messages.first?.parameters == nil)
    #expect(
      try fixture(parameters: .object([:]), required: false).messages.first?.parametersRequired
        == false)
    #expect(throws: SchemaError.self) { try fixture(parameters: nil, required: true) }
  }

  @Test func malformedOrDuplicateMethodsAreRejected() throws {
    let valid = try fixtureData(parameters: nil, required: false)
    let value = try JSONDecoder().decode(AppServerJSON.self, from: valid)
    guard case .object(var object) = value, case .array(let variants) = object["oneOf"] else {
      return
    }
    object["oneOf"] = .array(variants + variants)
    #expect(throws: SchemaError.self) {
      try AppServerSchema(data: JSONEncoder().encode(AppServerJSON.object(object)))
    }
    #expect(throws: SchemaError.self) {
      try AppServerSchema(data: Data(repeating: 32, count: 2 * 1_024 * 1_024 + 1))
    }
    #expect(throws: (any Error).self) { try AppServerSchema(data: Data("{".utf8)) }
  }

  private func fixture(
    parameters: AppServerJSON?, required: Bool = true, definitions: [String: AppServerJSON] = [:]
  ) throws -> AppServerSchema {
    try AppServerSchema(
      data: fixtureData(parameters: parameters, required: required, definitions: definitions))
  }

  @Test func comparisonReportsChangedJSONPointersAndParameterRequirement() throws {
    let params: AppServerJSON = .object(["$ref": .string("#/definitions/P")])
    let baseline = try fixture(
      parameters: params, definitions: ["P": .object(["type": .string("string")])])
    let current = try fixture(
      parameters: params, required: false, definitions: ["P": .object(["type": .string("integer")])]
    )
    let comparison = try SchemaComparison(baseline: baseline, current: current)
    let method = try #require(comparison.methods.first)
    #expect(method.change == "changed")
    #expect(method.baselineParametersRequired == true)
    #expect(method.currentParametersRequired == false)
    #expect(method.changedPointers == ["/definitions/P/type", "/required/1"])
    let unchanged = try SchemaComparison(baseline: baseline, current: baseline)
    #expect(unchanged.methods.first?.change == "unchanged")
    #expect(unchanged.methods.first?.changedPointers == [])
  }

  private func fixtureData(
    parameters: AppServerJSON?, required: Bool, definitions: [String: AppServerJSON] = [:]
  ) throws -> Data {
    var properties: [String: AppServerJSON] = [
      "method": .object(["type": .string("string"), "enum": .array([.string("test/read")])])
    ]
    properties["params"] = parameters
    return try JSONEncoder().encode(
      AppServerJSON.object([
        "definitions": .object(definitions),
        "oneOf": .array([
          .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array([.string("method")] + (required ? [.string("params")] : [])),
          ])
        ]),
      ]))
  }
}
