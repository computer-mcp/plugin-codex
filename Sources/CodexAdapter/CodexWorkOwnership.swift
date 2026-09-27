import Foundation
import MCP

/// Captured by the actual resource owner before starting asynchronous work.
enum CodexWorkInvocation {
  static let metadataKey = "io.github.computer-mcp/work-invocation"
  @TaskLocal static var current: UUID?

  static func parse(_ metadata: MCP.Metadata?) throws -> UUID? {
    guard let value = metadata?[metadataKey] else { return nil }
    guard let text = value.stringValue, text.utf8.count == 36,
      let id = UUID(uuidString: text), id.uuidString.lowercased() == text.lowercased()
    else {
      throw MCPError.invalidParams("Work invocation must be a UUID.")
    }
    return id
  }
}

struct CodexWorkResource: Equatable, Sendable {
  enum State: String, Sendable {
    case active
    case uncertain
  }

  let kind: String
  let id: String
  let acquiredBy: UUID
  let state: State

  init(kind: String, id: String, acquiredBy: UUID?, state: State = .active) throws {
    guard let acquiredBy else {
      throw MCPError.internalError("Work ownership is unavailable for an unbound resource.")
    }
    self.kind = kind
    self.id = id
    self.acquiredBy = acquiredBy
    self.state = state
  }

  var json: JSONValue {
    .object([
      "kind": .string(kind), "id": .string(id),
      "acquired_by": .string(acquiredBy.uuidString.lowercased()),
      "state": .string(state.rawValue),
    ])
  }
}
