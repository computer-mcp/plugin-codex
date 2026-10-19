import Darwin
import Foundation

struct CodexRuntimeRequestFailure: Codable, Equatable, Sendable {
  let kind: String
  let message: String
  let occurredAt: Date
  let connectionGeneration: Int
  let recoverable: Bool

  private enum CodingKeys: String, CodingKey {
    case kind
    case message
    case occurredAt = "occurred_at"
    case connectionGeneration = "connection_generation"
    case recoverable
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

struct CodexRuntimeLeaseRecord: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let owner: CodexRuntimeOwner?
  let workspacePath: String
  var state: String
  var process: CodexAppServerProcessSnapshot?
  let createdAt: Date
  var updatedAt: Date
  var shutdownReason: String?
  var cleanedAt: Date?
  var runtimeState: String? = nil
  var connectionState: String? = nil
  var processState: String? = nil
  var currentRequestState: String? = nil
  var lastRequestFailure: CodexRuntimeRequestFailure? = nil

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }

}

enum CodexRuntimeMaintenance {
  static func preview(
    database: CodexDatabase?,
    workspaceID: String?
  ) throws -> JSONValue {
    let records = try visibleRecords(database: database, workspaceID: workspaceID)
    return .object([
      "candidates": .array(records.map(candidate)),
      "signals_sent": .bool(false),
      "safety": .string(
        "Cleanup targets only persisted Computer MCP runtime records. Live processes remain owned by their per-runtime watchdog; unrelated Codex processes are never signaled."
      ),
    ])
  }

  static func cleanup(
    database: CodexDatabase?,
    workspaceID: String?
  ) async throws -> JSONValue {
    guard let database else {
      throw CodexToolError.disabled(
        "codex.app.runtime_persistence_unavailable: Runtime cleanup requires the Gateway Database."
      )
    }
    var cleaned: [JSONValue] = []
    var pending: [JSONValue] = []
    for var record in try visibleRecords(database: database, workspaceID: workspaceID) {
      guard CodexRuntimeDirectory.shared.runtime(id: record.id) == nil else { continue }
      if codexRuntimeProcessMayExist(record.process?.processID)
        || codexRuntimeProcessMayExist(record.process?.supervisorProcessID)
      {
        pending.append(candidate(record))
        continue
      }
      record.state = "cleaned"
      record.updatedAt = Date()
      record.cleanedAt = record.updatedAt
      record.shutdownReason = record.shutdownReason ?? "stale_record_cleaned"
      record.runtimeState = "stopped"
      record.connectionState = "stopped"
      record.processState = "stopped"
      record.currentRequestState = "idle"
      try database.saveCodexRuntimeLease(record)
      cleaned.append(record.json)
    }
    return .object([
      "cleaned": .array(cleaned),
      "watchdog_pending": .array(pending),
      "signals_sent": .bool(false),
    ])
  }

  private static func visibleRecords(
    database: CodexDatabase?,
    workspaceID: String?
  ) throws -> [CodexRuntimeLeaseRecord] {
    guard let database else { return [] }
    return try database.codexRuntimeLeases(limit: 5_000).filter {
      $0.owner?.workspaceID == workspaceID
        && ($0.runtimeState == "running"
          || ["starting", "running", "failed"].contains($0.state))
    }
  }

  private static func candidate(_ record: CodexRuntimeLeaseRecord) -> JSONValue {
    let directoryActive = CodexRuntimeDirectory.shared.runtime(id: record.id) != nil
    let processActive =
      codexRuntimeProcessMayExist(record.process?.processID)
      || codexRuntimeProcessMayExist(record.process?.supervisorProcessID)
    return .object([
      "runtime": record.json,
      "directory_active": .bool(directoryActive),
      "process_active": .bool(processActive),
      "classification": .string(
        directoryActive ? "active" : processActive ? "watchdog_pending" : "stale_record"
      ),
      "cleanup_ready": .bool(!directoryActive && !processActive),
    ])
  }

}

/// Read-only evidence for persisted receipts. Unknown access and reused IDs retain ownership;
/// a numeric ID never grants authority to signal the process or confirm descendant cleanup.
func codexRuntimeProcessMayExist(_ processID: Int32?) -> Bool {
  guard let processID, processID > 1 else { return false }
  errno = 0
  return Darwin.kill(processID, 0) == 0 || errno != ESRCH
}
