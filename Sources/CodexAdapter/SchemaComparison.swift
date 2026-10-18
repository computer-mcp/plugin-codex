import Foundation

struct SchemaComparison: Encodable {
  struct Method: Encodable {
    let method: String
    let change: String
    let baselineParametersRequired: Bool?
    let currentParametersRequired: Bool?
    let changedPointers: [String]
  }

  let baselineSHA256: String
  let currentSHA256: String
  let baselineCount: Int
  let currentCount: Int
  let methods: [Method]

  init(baseline: AppServerSchema, current: AppServerSchema) throws {
    baselineSHA256 = baseline.sha256
    currentSHA256 = current.sha256
    baselineCount = baseline.messages.count
    currentCount = current.messages.count
    let names = Set(baseline.messages.map(\.method)).union(current.messages.map(\.method))
    methods = try names.sorted().map { name in
      let old = baseline.message(named: name)
      let new = current.message(named: name)
      let change: String
      var changedPointers: [String] = []
      switch (old, new) {
      case (.none, .some): change = "added"
      case (.some, .none): change = "removed"
      case (.some(let old), .some(let new)):
        changedPointers = try Self.differences(
          baseline.standalone(old.declaration), current.standalone(new.declaration))
        change = changedPointers.isEmpty ? "unchanged" : "changed"
      case (.none, .none): preconditionFailure("Union contained an unknown method.")
      }
      return Method(
        method: name, change: change, baselineParametersRequired: old?.parametersRequired,
        currentParametersRequired: new?.parametersRequired, changedPointers: changedPointers)
    }
  }

  private static func differences(
    _ baseline: AppServerJSON, _ current: AppServerJSON, path: String = ""
  ) -> [String] {
    guard baseline != current else { return [] }
    switch (baseline, current) {
    case (.object(let old), .object(let new)):
      return Set(old.keys).union(new.keys).sorted().flatMap { key in
        let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(
          of: "/", with: "~1")
        let pointer = path + "/" + escaped
        guard let left = old[key], let right = new[key] else { return [pointer] }
        return differences(left, right, path: pointer)
      }
    case (.array(let old), .array(let new)):
      return (0..<max(old.count, new.count)).flatMap { index in
        let pointer = path + "/\(index)"
        guard index < old.count, index < new.count else { return [pointer] }
        return differences(old[index], new[index], path: pointer)
      }
    default: return [path]
    }
  }

  static func compareDirectories(baseline: URL, current: URL) throws -> Data {
    var comparisons: [String: SchemaComparison] = [:]
    for direction in ProtocolInventory.Direction.allCases {
      let name = direction.rawValue + ".json"
      comparisons[direction.rawValue] = try SchemaComparison(
        baseline: AppServerSchema(
          data: ProtocolInventory.read(
            baseline.appendingPathComponent(name), limit: 2 * 1_024 * 1_024)),
        current: AppServerSchema(
          data: ProtocolInventory.read(
            current.appendingPathComponent(name), limit: 2 * 1_024 * 1_024)))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(comparisons)
  }
}
