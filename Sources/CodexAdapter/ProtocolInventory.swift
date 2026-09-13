import Foundation

struct ProtocolInventory: Sendable {
  enum Channel: String, CaseIterable, Codable, Sendable { case stable, experimental }
  enum Direction: String, CaseIterable, Codable, Sendable {
    case clientRequest = "ClientRequest"
    case clientNotification = "ClientNotification"
    case serverRequest = "ServerRequest"
    case serverNotification = "ServerNotification"
  }

  struct Receipt: Decodable, Sendable {
    struct File: Decodable, Sendable {
      let sha256: String
      let messages: Int
    }
    let codexVersion: String
    let files: [String: File]
  }

  let receipt: Receipt
  private let schemas: [String: AppServerSchema]

  init(directory: URL) throws {
    receipt = try JSONDecoder().decode(
      Receipt.self, from: Self.read(directory.appendingPathComponent("receipt.json"), limit: 16_384)
    )
    guard receipt.files.count == Channel.allCases.count * Direction.allCases.count,
      receipt.codexVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
    else { throw SchemaError.invalid("Invalid schema receipt.") }
    var schemas: [String: AppServerSchema] = [:]
    for channel in Channel.allCases {
      for direction in Direction.allCases {
        let name = Self.filename(channel, direction)
        guard let expected = receipt.files[name] else {
          throw SchemaError.invalid("Missing receipt for \(name).")
        }
        let data = try Self.read(directory.appendingPathComponent(name), limit: 2 * 1_024 * 1_024)
        guard AppServerSchema.digest(data) == expected.sha256 else {
          throw SchemaError.invalid("Schema integrity mismatch: \(name).")
        }
        let schema = try AppServerSchema(data: data)
        guard schema.messages.count == expected.messages else {
          throw SchemaError.invalid("Schema message count mismatch: \(name).")
        }
        schemas[name] = schema
      }
    }
    self.schemas = schemas
  }

  static func bundled() throws -> Self {
    guard let directory = Bundle.module.url(forResource: "Protocol", withExtension: nil) else {
      throw SchemaError.invalid("Missing bundled protocol inventory.")
    }
    return try Self(directory: directory)
  }

  func schema(channel: Channel, direction: Direction) -> AppServerSchema {
    // Initialization validates the full Cartesian product, before publication.
    schemas[Self.filename(channel, direction)]!
  }

  private static func filename(_ channel: Channel, _ direction: Direction) -> String {
    "\(channel.rawValue)/\(direction.rawValue).json"
  }

  static func read(_ url: URL, limit: Int) throws -> Data {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else {
      throw SchemaError.invalid("Schema input exceeds its size limit.")
    }
    return data
  }
}
