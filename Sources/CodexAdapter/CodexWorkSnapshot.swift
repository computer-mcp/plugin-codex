import Foundation
import MCP

/// One complete observation per read; failed or overlapping reads cannot imply idle work.
actor CodexWorkSnapshot {
  static let uri = "computer-mcp://runtime/work/v1"
  static let metadataKey = "io.github.computer-mcp/work"

  private let collect: @Sendable () async throws -> [CodexWorkResource]
  private let instanceID = UUID().uuidString.lowercased()
  private var revision: Int64 = 0
  private var previous: [CodexWorkResource]?
  private var reading: Task<MCP.ReadResource.Result, any Error>?
  private var closed = false

  init(collect: @escaping @Sendable () async throws -> [CodexWorkResource]) {
    self.collect = collect
  }

  static func declaring(_ tool: MCP.Tool) throws -> MCP.Tool {
    var tool = tool
    var fields = tool._meta?.fields ?? [:]
    fields[metadataKey] = .object(["format_version": .int(1), "uri": .string(uri)])
    if let continuation = try CodexWorkContinuation.declaration(for: tool.name) {
      fields[CodexWorkContinuation.metadataKey] = continuation
    }
    tool._meta = .init(additionalFields: fields)
    return tool
  }

  func read() async throws -> MCP.ReadResource.Result {
    guard !closed else { throw MCPError.internalError("Work observation is closed.") }
    // A read admitted after a completed call must not reuse an earlier observation.
    guard reading == nil else {
      throw MCPError.internalError("Work observation is already in progress; retry the read.")
    }
    let task = Task {
      let resources = try await collect()
      try Task.checkCancellation()
      return try publish(resources)
    }
    reading = task
    defer { reading = nil }
    return try await task.value
  }

  func shutdown() async {
    closed = true
    reading?.cancel()
    _ = await reading?.result
  }

  private func publish(_ resources: [CodexWorkResource]) throws -> MCP.ReadResource.Result {
    guard !closed, resources.count <= 1024 else {
      throw MCPError.internalError("Complete work observation is unavailable.")
    }
    let rows = resources.sorted { ($0.kind, $0.id) < ($1.kind, $1.id) }
    for (index, row) in rows.enumerated() {
      guard Self.isIdentifier(row.kind), Self.isIdentifier(row.id),
        index == 0 || rows[index - 1].kind != row.kind || rows[index - 1].id != row.id
      else {
        throw MCPError.internalError("Work resource identity is invalid or ambiguous.")
      }
    }
    let changed = previous != nil && previous != rows
    guard !changed || revision < Int64.max else {
      throw MCPError.internalError("Work observation revision is exhausted.")
    }
    let nextRevision = revision + (changed ? 1 : 0)
    let value = JSONValue.object([
      "format_version": .integer(1), "instance_id": .string(instanceID),
      "revision": .integer(nextRevision), "resources": .array(rows.map(\.json)),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard data.count <= 524_288 else {
      throw MCPError.internalError("Complete work observation exceeds its byte bound.")
    }
    previous = rows
    revision = nextRevision
    return .init(contents: [
      .text(
        String(decoding: data, as: UTF8.self), uri: Self.uri,
        mimeType: "application/json")
    ])
  }

  private static func isIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1024
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}
