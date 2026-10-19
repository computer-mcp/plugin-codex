import CodexAppServerRuntime
import CryptoKit
import Foundation

typealias AppServerJSON = CodexAppServerConnectionFoundation.JSONValue

enum SchemaError: Error, Equatable, LocalizedError {
  case invalid(String)

  var errorDescription: String? {
    switch self {
    case .invalid(let message): message
    }
  }
}

/// One version-specific direction of the App Server protocol, not a permission list.
struct AppServerSchema: Sendable {
  struct Message: Sendable {
    let method: String
    let declaration: AppServerJSON
    let parameters: AppServerJSON?
    let parametersRequired: Bool
  }

  let messages: [Message]
  let sha256: String
  private let definitions: [String: AppServerJSON]

  init(data: Data) throws {
    guard data.count <= 2 * 1_024 * 1_024 else {
      throw SchemaError.invalid("Schema exceeds 2 MiB.")
    }
    let root = try JSONDecoder().decode(AppServerJSON.self, from: data)
    guard case .object(let object) = root,
      case .array(let variants) = object["oneOf"], !variants.isEmpty, variants.count <= 1_024
    else { throw SchemaError.invalid("Expected a bounded message union.") }
    if let value = object["definitions"] {
      guard case .object(let definitions) = value else {
        throw SchemaError.invalid("Invalid schema definitions.")
      }
      self.definitions = definitions
    } else {
      definitions = [:]
    }
    var names = Set<String>()
    messages = try variants.map { declaration in
      guard case .object(let fields) = declaration,
        case .object(let properties) = fields["properties"],
        case .object(let methodSchema) = properties["method"],
        case .array(let methods) = methodSchema["enum"], methods.count == 1,
        case .string(let method) = methods[0], !method.isEmpty, method.utf8.count <= 256,
        method == method.trimmingCharacters(in: .whitespacesAndNewlines),
        !method.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        names.insert(method).inserted,
        case .array(let required) = fields["required"], required.contains(.string("method"))
      else { throw SchemaError.invalid("Invalid or duplicate method declaration.") }
      guard required.allSatisfy({ if case .string = $0 { true } else { false } }),
        !required.contains(.string("params")) || properties["params"] != nil
      else { throw SchemaError.invalid("Invalid required fields for \(method).") }
      return Message(
        method: method, declaration: declaration, parameters: properties["params"],
        parametersRequired: required.contains(.string("params")))
    }.sorted { $0.method < $1.method }
    sha256 = Self.digest(data)
    // Resolve every declaration once so malformed unselected entries cannot hide in the catalog.
    for message in messages { _ = try standalone(message.declaration) }
  }

  func message(named method: String) -> Message? { messages.first { $0.method == method } }

  /// Keeps recursive references intact and includes only their reachable definitions.
  func standalone(_ schema: AppServerJSON) throws -> AppServerJSON {
    var requiredDefinitions: [String: AppServerJSON] = [:]
    var pending = [schema]
    var visited = 0
    while let value = pending.popLast() {
      visited += 1
      guard visited <= 200_000 else {
        throw SchemaError.invalid("Schema traversal limit exceeded.")
      }
      switch value {
      case .object(let fields):
        if let reference = fields["$ref"] {
          guard case .string(let path) = reference, path.hasPrefix("#/definitions/") else {
            throw SchemaError.invalid("Only local definition references are supported.")
          }
          let token = String(path.dropFirst("#/definitions/".count))
          guard !token.contains("/"),
            token.range(of: #"~(?:[^01]|$)"#, options: .regularExpression) == nil
          else {
            throw SchemaError.invalid("Invalid definition pointer.")
          }
          let name = token.replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
          guard let target = definitions[name] else {
            throw SchemaError.invalid("Unresolved definition: \(name).")
          }
          if requiredDefinitions[name] == nil {
            requiredDefinitions[name] = target
            pending.append(target)
          }
        }
        // Values in defaults, const, enum, and examples are data, not schema locations.
        for key in [
          "additionalItems", "additionalProperties", "contains", "propertyNames", "not", "if",
          "then", "else", "items", "allOf", "anyOf", "oneOf",
        ] {
          if let child = fields[key] { pending.append(child) }
        }
        for key in [
          "properties", "patternProperties", "definitions", "$defs", "dependentSchemas",
          "dependencies",
        ] {
          if case .object(let children) = fields[key] {
            pending.append(contentsOf: children.values)
          }
        }
      case .array(let values): pending.append(contentsOf: values)
      default: break
      }
    }
    guard case .object(var result) = schema else {
      throw SchemaError.invalid("Expected a JSON Schema object.")
    }
    result["$schema"] = .string("http://json-schema.org/draft-07/schema#")
    if !requiredDefinitions.isEmpty { result["definitions"] = .object(requiredDefinitions) }
    return .object(result)
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
