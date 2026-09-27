import Foundation
import MCP
import Testing

@testable import CodexAdapter

struct JSONIntegerTests {
  @Test(arguments: [
    Int64.min, 9_007_199_254_740_991, 9_007_199_254_740_992,
    9_007_199_254_740_993, Int64.max,
  ])
  func nativeAndMCPRoundTrip(value: Int64) throws {
    let input = Data("{\"value\":\(value)}".utf8)
    let json = try JSONDecoder().decode(JSONValue.self, from: input)
    #expect(json.objectValue?["value"] == .integer(value))
    #expect(json.objectValue?["value"]?.intValue == Int(value))
    let encoded = try JSONEncoder().encode(json)
    let mcp = try JSONDecoder().decode(MCP.Value.self, from: encoded)
    #expect(mcp.objectValue?["value"] == .int(Int(value)))
    let native = try JSONDecoder().decode(AppServerJSON.self, from: encoded)
    #expect(native == .object(["value": .number(.integer(value))]))
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(native)) == json)
  }

  @Test(arguments: ["9223372036854775808", "-9223372036854775809", "18446744073709551615"])
  func unsupportedIntegerRangeIsExplicit(text: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
  }

  @Test func numericIdentityDoesNotRoundIntegers() throws {
    #expect(JSONValue.integer(9_007_199_254_740_993) != .number(9_007_199_254_740_992))
    #expect(JSONValue.integer(2) == .number(2))
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data("1.25".utf8)) == .number(1.25))
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8)) == .bool(true))
  }
}
