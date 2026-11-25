import CryptoKit
import Foundation
import Logging
import MCP

enum CodexProjectContract {
  static let identifier = "projects-v1"
  static let capabilityKey = "io.github.computer-mcp/host-service-contract"

  struct Unsupported: LocalizedError {
    let observed: String?

    var errorDescription: String? {
      "[host.unsupported_contract] Required projects-v1, observed \(observed ?? "none"). "
        + "Update Computer MCP and the Codex plugin together, then restart the provider."
    }

    var fields: JSONValue {
      .object([
        "code": .string("host.unsupported_contract"),
        "message": .string(errorDescription ?? ""),
        "required_contract": .string(CodexProjectContract.identifier),
        "observed_contract": observed.map(JSONValue.string) ?? .null,
      ])
    }
  }
}

/// The pinned SDK models standard capabilities only. Add the contract to the wire
/// result while retaining the SDK's initialize handler and protocol negotiation.
actor CodexProjectHandshakeTransport: MCP.Transport {
  private let transport: any MCP.Transport

  private let contract: String
  init(_ transport: any MCP.Transport, contract: String = CodexProjectContract.identifier) {
    self.transport = transport
    self.contract = contract
  }

  nonisolated let logger = Logger(
    label: "codex.project-handshake", factory: { _ in SwiftLogNoOpLogHandler() })
  private var frames: AsyncThrowingStream<Data, Error>?
  private var advertised = false

  func connect() async throws {
    try await transport.connect()
    frames = await transport.receive()
  }

  func disconnect() async { await transport.disconnect() }

  func receive() -> AsyncThrowingStream<Data, Error> {
    frames ?? AsyncThrowingStream { $0.finish(throwing: MCPError.connectionClosed) }
  }

  func send(_ data: Data) async throws {
    guard !advertised,
      var message = try? JSONDecoder().decode([String: JSONValue].self, from: data),
      var result = message["result"]?.objectValue,
      result["serverInfo"] != nil, result["protocolVersion"] != nil,
      var capabilities = result["capabilities"]?.objectValue
    else {
      try await transport.send(data)
      return
    }
    var experimental = capabilities["experimental"]?.objectValue ?? [:]
    experimental[CodexProjectContract.capabilityKey] = .string(contract)
    capabilities["experimental"] = .object(experimental)
    result["capabilities"] = .object(capabilities)
    message["result"] = .object(result)
    try await transport.send(JSONEncoder().encode(message))
    advertised = true
  }
}

struct CodexHostInvocation: Sendable {
  static let invocationKey = "io.github.computer-mcp/host-invocation"
  static let operationKey = "io.github.computer-mcp/host-operation"

  let invocationID: UUID?
  let operationID: UUID?

  init(_ metadata: MCP.Metadata?) throws {
    func uuid(_ key: String) throws -> UUID? {
      guard let value = metadata?[key] else { return nil }
      guard let raw = value.stringValue, let id = UUID(uuidString: raw),
        id.uuidString.lowercased() == raw.lowercased()
      else { throw MCPError.invalidParams("Host lifecycle metadata must contain UUIDs.") }
      return id
    }
    invocationID = try uuid(Self.invocationKey)
    operationID = try uuid(Self.operationKey)
  }

  static func digest(_ arguments: [String: JSONValue]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(JSONValue.object(arguments)))
      .map { String(format: "%02x", $0) }.joined()
  }
}

struct CodexHostOperationIDs: Codable, Equatable, Sendable {
  let invocationID: UUID
  let operationID: UUID

  var arguments: [String: JSONValue] {
    [
      "invocation_id": .string(invocationID.uuidString),
      "operation_id": .string(operationID.uuidString),
    ]
  }
}

enum CodexProjectInspection: Sendable {
  case invocation(UUID)
  case operation(UUID)
}

struct CodexHostToolResponse: Codable, Equatable, Sendable {
  let raw: JSONValue

  var structured: [String: JSONValue]? {
    raw.objectValue?["structuredContent"]?.objectValue
  }
  var result: JSONValue? { structured?["result"] }
  var refusal: JSONValue? { structured?["error"] }
  var isError: Bool? { raw.objectValue?["isError"]?.boolValue }

  func toolResult(_ result: JSONValue) throws -> MCP.CallTool.Result {
    let original = try? JSONDecoder().decode(
      MCP.CallTool.Result.self, from: JSONEncoder().encode(raw))
    return try MCP.CallTool.Result(
      content: original?.content ?? [],
      structuredContent: JSONValue.object(["result": result]),
      isError: result.objectValue?["observation_error"] != nil || isError == true,
      _meta: original?._meta)
  }
}

protocol CodexProjectServices: Sendable {
  func validateContract() async throws
  func describe(_ inspection: CodexProjectInspection) async throws -> CodexHostToolResponse
  func add(_ selection: CodexWorktreeSelection, ids: CodexHostOperationIDs) async throws
    -> CodexHostToolResponse
  func list(invocationID: UUID) async throws -> CodexHostToolResponse
  func remove(force: Bool, ids: CodexHostOperationIDs) async throws -> CodexHostToolResponse
}
