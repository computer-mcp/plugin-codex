import Foundation
import GRDB

/// Adapter-owned domain records. Host grants, credentials, workspaces and audit stay with the host.
final class CodexDatabase: @unchecked Sendable {
  private let writer: any DatabaseWriter
  let fileURL: URL?

  init(path: String) throws {
    fileURL = URL(fileURLWithPath: path).standardizedFileURL
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    writer = try DatabaseQueue(path: path, configuration: configuration)
    try Self.migrator.migrate(writer)
    try reconcileCodexRuntimeLeaseSemantics()
  }

  init(inMemory: Void) throws {
    fileURL = nil
    writer = try DatabaseQueue()
    try Self.migrator.migrate(writer)
    try reconcileCodexRuntimeLeaseSemantics()
  }

  func saveCodexApproval(_ approval: CodexApprovalRecord) throws {
    try writer.write { database in
      try CodexApprovalRecordRow(approval).save(database)
    }
  }

  func codexApproval(id: String) throws -> CodexApprovalRecord? {
    try writer.read { database in
      try CodexApprovalRecordRow.fetchOne(database, key: id)?.value()
    }
  }

  func codexApprovals(
    workspaceID: String? = nil,
    limit: Int = 500
  ) throws -> [CodexApprovalRecord] {
    try writer.read { database in
      var request =
        CodexApprovalRecordRow
        .order(Column("createdAt").desc, Column("id").desc)
      if let workspaceID {
        request = request.filter(Column("workspaceID") == workspaceID)
      }
      return try request.limit(max(1, min(limit, 5_000))).fetchAll(database).map {
        try $0.value()
      }
    }
  }

  func saveCodexRuntimeLease(_ lease: CodexRuntimeLeaseRecord) throws {
    try writer.write { database in
      try CodexRuntimeLeaseRow(lease).save(database)
    }
  }

  func codexRuntimeLeases(limit: Int = 500) throws -> [CodexRuntimeLeaseRecord] {
    try writer.read { database in
      try CodexRuntimeLeaseRow
        .order(Column("updatedAt").desc, Column("id").desc)
        .limit(max(1, min(limit, 5_000)))
        .fetchAll(database)
        .map { try $0.value().reconciledStateSemantics() }
    }
  }

  private func reconcileCodexRuntimeLeaseSemantics() throws {
    try writer.write { database in
      for row in try CodexRuntimeLeaseRow.fetchAll(database) {
        let current = try row.value()
        let reconciled = current.reconciledStateSemantics()
        if reconciled != current {
          try CodexRuntimeLeaseRow(reconciled).save(database)
        }
      }
    }
  }

  func saveCodexThreadOwnership(_ ownership: CodexThreadOwnershipRecord) throws {
    try writer.write { database in
      try CodexThreadOwnershipRow(ownership).save(database)
    }
  }

  func codexThreadOwnership(threadID: String) throws -> CodexThreadOwnershipRecord? {
    try writer.read { database in
      try CodexThreadOwnershipRow.fetchOne(database, key: threadID)?.value()
    }
  }

  func codexThreadOwnerships(
    workspaceID: String? = nil,
    limit: Int = 500
  ) throws -> [CodexThreadOwnershipRecord] {
    try writer.read { database in
      var request = CodexThreadOwnershipRow.order(
        Column("updatedAt").desc,
        Column("threadID").desc
      )
      if let workspaceID {
        request = request.filter(Column("workspaceID") == workspaceID)
      }
      return try request.limit(max(1, min(limit, 5_000))).fetchAll(database).map {
        try $0.value()
      }
    }
  }

  func applyCodexThreadOwnershipReconciliation(
    plan: CodexThreadOwnershipReconciliationPlan,
    now: Date
  ) throws -> CodexThreadOwnershipReconciliationResult {
    try writer.write { database in
      var releasedThreadIDs: [String] = []
      for candidate in plan.candidates {
        guard var row = try CodexThreadOwnershipRow.fetchOne(database, key: candidate.threadID),
          row.runtimeID == candidate.runtimeID,
          row.state == CodexThreadOwnershipState.loaded.rawValue
        else {
          throw CodexThreadOwnershipReconciliationError.planChanged(
            expected: plan.planDigest,
            actual: "ownership-state-changed"
          )
        }
        row.state = CodexThreadOwnershipState.released.rawValue
        row.updatedAt = now
        try row.save(database)
        releasedThreadIDs.append(candidate.threadID)
      }
      let result = CodexThreadOwnershipReconciliationResult(
        schemaVersion: 1,
        receiptID: UUID().uuidString,
        planDigest: plan.planDigest,
        releasedThreadIDs: releasedThreadIDs.sorted(),
        appliedAt: now,
        signalsSent: false,
        externalStateMutated: false
      )
      let encoder = CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
      try CodexThreadOwnershipReconciliationReceiptRow(
        id: result.receiptID,
        planDigest: result.planDigest,
        appliedAt: now,
        payloadJSON: String(decoding: try encoder.encode(result), as: UTF8.self)
      ).insert(database)
      return result
    }
  }

  func saveCodexOrchestrationRun(_ run: CodexOrchestrationRun) throws {
    try writer.write { database in
      try CodexOrchestrationRunRow(run).save(database)
    }
  }

  func codexOrchestrationRun(id: String) throws -> CodexOrchestrationRun? {
    try writer.read { database in
      try CodexOrchestrationRunRow.fetchOne(database, key: id)?.value()
    }
  }

  func codexOrchestrationRuns(
    workspaceID: String? = nil,
    limit: Int = 500
  ) throws -> [CodexOrchestrationRun] {
    try writer.read { database in
      var request =
        CodexOrchestrationRunRow
        .order(Column("updatedAt").desc, Column("id").desc)
      if let workspaceID {
        request = request.filter(Column("workspaceID") == workspaceID)
      }
      return try request.limit(max(1, min(limit, 5_000))).fetchAll(database).map {
        try $0.value()
      }
    }
  }

  func updateCodexOrchestrationRun(
    id: String,
    workspaceID: String?,
    expectedRevision: Int,
    mutate: (inout CodexOrchestrationRun) throws -> Void
  ) throws -> CodexOrchestrationRun {
    try writer.write { database in
      guard let row = try CodexOrchestrationRunRow.fetchOne(database, key: id) else {
        throw CodexOrchestrationError.unknown(id)
      }
      var run = try row.value()
      guard workspaceID == nil || run.workspaceID == workspaceID else {
        throw CodexOrchestrationError.unknown(id)
      }
      guard run.revision == expectedRevision else {
        throw CodexOrchestrationError.revisionConflict(
          expected: expectedRevision,
          actual: run.revision
        )
      }
      try mutate(&run)
      run.revision += 1
      try CodexOrchestrationRunRow(run).save(database)
      return run
    }
  }

  func codexWorktreeLease(id: String) throws -> CodexWorktreeLease? {
    try writer.read { database in
      try CodexWorktreeLeaseRow.fetchOne(database, key: id)?.value()
    }
  }

  func codexWorktreeLeases(
    workspaceID: String? = nil,
    states: Set<CodexWorktreeLeaseState> = [],
    limit: Int = 500
  ) throws -> [CodexWorktreeLease] {
    try writer.read { database in
      var request =
        CodexWorktreeLeaseRow
        .order(Column("heartbeatAt").desc, Column("id").desc)
      if let workspaceID {
        request = request.filter(Column("workspaceID") == workspaceID)
      }
      if !states.isEmpty {
        request = request.filter(states.map(\.rawValue).contains(Column("state")))
      }
      return try request.limit(max(1, min(limit, 5_000))).fetchAll(database).map {
        try $0.value()
      }
    }
  }

  func acquireCodexWorktreeLease(
    workspaceID: String,
    workspacePath: String,
    mode: CodexWorktreeLeaseMode,
    agentID: String,
    threadID: String?,
    runID: String?,
    parentLeaseID: String?,
    branch: String?,
    ttlSeconds: Int,
    now: Date
  ) throws -> CodexWorktreeLease {
    try writer.write { database in
      let rows =
        try CodexWorktreeLeaseRow
        .filter(Column("workspaceID") == workspaceID)
        .filter(Column("state") == CodexWorktreeLeaseState.active.rawValue)
        .fetchAll(database)
      for row in rows {
        var existing = try row.value()
        if existing.expiresAt <= now {
          existing.state = .expired
          existing.releasedAt = now
          existing.releaseReason = "lease_ttl_expired"
          existing.revision += 1
          try CodexWorktreeLeaseRow(existing).save(database)
          continue
        }
        if existing.agentID == agentID, existing.threadID == threadID,
          existing.runID == runID
        {
          return existing
        }
        throw CodexWorktreeLeaseError.conflict(existing)
      }
      let lease = CodexWorktreeLease(
        id: UUID().uuidString,
        workspaceID: workspaceID,
        workspacePath: workspacePath,
        mode: mode,
        agentID: agentID,
        threadID: threadID,
        runID: runID,
        parentLeaseID: parentLeaseID,
        branch: branch,
        state: .active,
        createdAt: now,
        heartbeatAt: now,
        expiresAt: now.addingTimeInterval(TimeInterval(ttlSeconds)),
        releasedAt: nil,
        releaseReason: nil,
        revision: 1
      )
      try CodexWorktreeLeaseRow(lease).save(database)
      return lease
    }
  }

  func updateCodexWorktreeLease(
    id: String,
    workspaceID: String?,
    expectedRevision: Int,
    mutate: (inout CodexWorktreeLease) throws -> Void
  ) throws -> CodexWorktreeLease {
    try writer.write { database in
      guard let row = try CodexWorktreeLeaseRow.fetchOne(database, key: id) else {
        throw CodexWorktreeLeaseError.unknown(id)
      }
      var lease = try row.value()
      guard workspaceID == nil || lease.workspaceID == workspaceID else {
        throw CodexWorktreeLeaseError.unknown(id)
      }
      guard lease.revision == expectedRevision else {
        throw CodexWorktreeLeaseError.revisionConflict(
          expected: expectedRevision,
          actual: lease.revision
        )
      }
      try mutate(&lease)
      lease.revision += 1
      try CodexWorktreeLeaseRow(lease).save(database)
      return lease
    }
  }

  func saveCodexManagedWorktree(_ worktree: CodexManagedWorktree) throws {
    try writer.write { database in
      try CodexManagedWorktreeRow(worktree).save(database)
    }
  }

  func codexManagedWorktree(id: String) throws -> CodexManagedWorktree? {
    try writer.read { database in
      try CodexManagedWorktreeRow.fetchOne(database, key: id)?.value()
    }
  }

  func codexManagedWorktrees(
    sourceWorkspaceID: String? = nil,
    limit: Int = 100
  ) throws -> [CodexManagedWorktree] {
    try writer.read { database in
      var request =
        CodexManagedWorktreeRow
        .order(Column("updatedAt").desc, Column("id").desc)
      if let sourceWorkspaceID {
        request = request.filter(Column("sourceWorkspaceID") == sourceWorkspaceID)
      }
      return try request.limit(max(1, min(limit, 5_000))).fetchAll(database).map {
        try $0.value()
      }
    }
  }

  func updateCodexManagedWorktree(
    id: String,
    sourceWorkspaceID: String?,
    expectedRevision: Int,
    mutate: (inout CodexManagedWorktree) throws -> Void
  ) throws -> CodexManagedWorktree {
    try writer.write { database in
      guard let row = try CodexManagedWorktreeRow.fetchOne(database, key: id) else {
        throw CodexManagedWorktreeError.unknown(id)
      }
      var worktree = try row.value()
      guard sourceWorkspaceID == nil || worktree.sourceWorkspaceID == sourceWorkspaceID else {
        throw CodexManagedWorktreeError.unknown(id)
      }
      guard worktree.revision == expectedRevision else {
        throw CodexManagedWorktreeError.revisionConflict(
          expected: expectedRevision,
          actual: worktree.revision
        )
      }
      try mutate(&worktree)
      worktree.revision += 1
      try CodexManagedWorktreeRow(worktree).save(database)
      return worktree
    }
  }

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("codex-approval-broker") { database in
      try database.create(table: "codexApprovals") { table in
        table.column("id", .text).primaryKey()
        table.column("upstreamRequestID", .text).notNull()
        table.column("kind", .text).notNull()
        table.column("risk", .text).notNull()
        table.column("state", .text).notNull()
        table.column("workspaceID", .text)
        table.column("workspacePath", .text).notNull()
        table.column("runtimeID", .text).notNull()
        table.column("threadID", .text)
        table.column("turnID", .text)
        table.column("itemID", .text)
        table.column("correlationID", .text).notNull()
        table.column("socketConnectionID", .text)
        table.column("tunnelInstanceID", .text)
        table.column("detailsJSON", .text).notNull()
        table.column("proposedActionJSON", .text).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("expiresAt", .datetime).notNull()
        table.column("resolvedAt", .datetime)
        table.column("decision", .text)
        table.column("scope", .text)
        table.column("resolutionReason", .text)
      }
      try database.create(
        index: "codexApprovals_on_workspace_state_createdAt",
        on: "codexApprovals",
        columns: ["workspaceID", "state", "createdAt"]
      )
      try database.create(
        index: "codexApprovals_on_runtimeID",
        on: "codexApprovals",
        columns: ["runtimeID"]
      )
      try database.create(
        index: "codexApprovals_on_correlationID",
        on: "codexApprovals",
        columns: ["correlationID"]
      )
    }
    migrator.registerMigration("codex-runtime-leases") { database in
      try database.create(table: "codexRuntimeLeases") { table in
        table.column("id", .text).primaryKey()
        table.column("workspaceID", .text)
        table.column("state", .text).notNull()
        table.column("updatedAt", .datetime).notNull()
        table.column("payloadJSON", .text).notNull()
      }
      try database.create(
        index: "codexRuntimeLeases_on_workspace_state_updatedAt",
        on: "codexRuntimeLeases",
        columns: ["workspaceID", "state", "updatedAt"]
      )
    }
    migrator.registerMigration("codex-thread-ownership") { database in
      try database.create(table: "codexThreadOwnership") { table in
        table.column("threadID", .text).primaryKey()
        table.column("workspaceID", .text)
        table.column("workspacePath", .text).notNull()
        table.column("runtimeID", .text).notNull()
        table.column("state", .text).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      try database.create(
        index: "codexThreadOwnership_on_workspace_state_updatedAt",
        on: "codexThreadOwnership",
        columns: ["workspaceID", "state", "updatedAt"]
      )
    }
    migrator.registerMigration("codex-ownership-reconciliation-receipts") { database in
      try database.create(table: "codexOwnershipReconciliationReceipts") { table in
        table.column("id", .text).primaryKey()
        table.column("planDigest", .text).notNull()
        table.column("appliedAt", .datetime).notNull()
        table.column("payloadJSON", .text).notNull()
      }
    }

    migrator.registerMigration("codex-orchestration-runs") { database in
      try database.create(table: "codexOrchestrationRuns") { table in
        table.column("id", .text).primaryKey()
        table.column("workspaceID", .text).notNull()
        table.column("state", .text).notNull()
        table.column("updatedAt", .datetime).notNull()
        table.column("payloadJSON", .text).notNull()
      }
      try database.create(
        index: "codexOrchestrationRuns_on_workspace_state_updatedAt",
        on: "codexOrchestrationRuns",
        columns: ["workspaceID", "state", "updatedAt"]
      )
    }
    migrator.registerMigration("codex-worktree-leases") { database in
      try database.create(table: "codexWorktreeLeases") { table in
        table.column("id", .text).primaryKey()
        table.column("workspaceID", .text).notNull()
        table.column("state", .text).notNull()
        table.column("heartbeatAt", .datetime).notNull()
        table.column("payloadJSON", .text).notNull()
      }
      try database.create(
        index: "codexWorktreeLeases_on_workspace_state_heartbeatAt",
        on: "codexWorktreeLeases",
        columns: ["workspaceID", "state", "heartbeatAt"]
      )
    }
    migrator.registerMigration("codex-managed-worktrees") { database in
      try database.create(table: "codexManagedWorktrees") { table in
        table.column("id", .text).primaryKey()
        table.column("sourceWorkspaceID", .text).notNull()
        table.column("workspaceID", .text).notNull().unique()
        table.column("state", .text).notNull()
        table.column("updatedAt", .datetime).notNull()
        table.column("payloadJSON", .text).notNull()
      }
      try database.create(
        index: "codexManagedWorktrees_on_source_state_updatedAt",
        on: "codexManagedWorktrees",
        columns: ["sourceWorkspaceID", "state", "updatedAt"]
      )
    }
    return migrator
  }
}

private struct CodexManagedWorktreeRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexManagedWorktrees"

  var id: String
  var sourceWorkspaceID: String
  var workspaceID: String
  var state: String
  var updatedAt: Date
  var payloadJSON: String

  init(_ value: CodexManagedWorktree) throws {
    id = value.id
    sourceWorkspaceID = value.sourceWorkspaceID
    workspaceID = value.workspaceID
    state = value.state.rawValue
    updatedAt = value.updatedAt
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    payloadJSON = String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  func value() throws -> CodexManagedWorktree {
    guard let data = payloadJSON.data(using: .utf8) else {
      throw CodexDatabaseError.invalidStoredValue("Codex managed worktree is not UTF-8.")
    }
    return try JSONDecoder().decode(CodexManagedWorktree.self, from: data)
  }
}

enum CodexDatabaseError: Error, LocalizedError {
  case invalidStoredValue(String)
  var errorDescription: String? {
    switch self {
    case .invalidStoredValue(let message): return message
    }
  }
}

private struct CodexApprovalRecordRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexApprovals"

  var id: String
  var upstreamRequestID: String
  var kind: String
  var risk: String
  var state: String
  var workspaceID: String?
  var workspacePath: String
  var runtimeID: String
  var threadID: String?
  var turnID: String?
  var itemID: String?
  var correlationID: String
  var socketConnectionID: String?
  var tunnelInstanceID: String?
  var detailsJSON: String
  var proposedActionJSON: String
  var createdAt: Date
  var expiresAt: Date
  var resolvedAt: Date?
  var decision: String?
  var scope: String?
  var resolutionReason: String?

  init(_ value: CodexApprovalRecord) throws {
    id = value.id
    upstreamRequestID = value.upstreamRequestID
    kind = value.kind.rawValue
    risk = value.risk.rawValue
    state = value.state.rawValue
    workspaceID = value.workspaceID
    workspacePath = value.workspacePath
    runtimeID = value.runtimeID
    threadID = value.threadID
    turnID = value.turnID
    itemID = value.itemID
    correlationID = value.correlationID
    socketConnectionID = value.socketConnectionID
    tunnelInstanceID = value.tunnelInstanceID
    detailsJSON = try Self.encode(value.details)
    proposedActionJSON = try Self.encode(value.proposedAction)
    createdAt = value.createdAt
    expiresAt = value.expiresAt
    resolvedAt = value.resolvedAt
    decision = value.decision?.rawValue
    scope = value.scope
    resolutionReason = value.resolutionReason
  }

  func value() throws -> CodexApprovalRecord {
    guard let kind = CodexApprovalKind(rawValue: kind),
      let risk = CodexOperationRisk(rawValue: risk),
      let state = CodexApprovalState(rawValue: state)
    else {
      throw CodexDatabaseError.invalidStoredValue(
        "Codex approval contains unknown enum values."
      )
    }
    let decision = try decision.map { rawValue in
      guard let value = CodexApprovalDecision(rawValue: rawValue) else {
        throw CodexDatabaseError.invalidStoredValue(
          "Codex approval contains an unknown decision."
        )
      }
      return value
    }
    return CodexApprovalRecord(
      id: id,
      upstreamRequestID: upstreamRequestID,
      kind: kind,
      risk: risk,
      state: state,
      workspaceID: workspaceID,
      workspacePath: workspacePath,
      runtimeID: runtimeID,
      threadID: threadID,
      turnID: turnID,
      itemID: itemID,
      correlationID: correlationID,
      socketConnectionID: socketConnectionID,
      tunnelInstanceID: tunnelInstanceID,
      details: try Self.decode(detailsJSON),
      proposedAction: try Self.decode(proposedActionJSON),
      createdAt: createdAt,
      expiresAt: expiresAt,
      resolvedAt: resolvedAt,
      decision: decision,
      scope: scope,
      resolutionReason: resolutionReason
    )
  }

  private static func encode(_ value: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard let result = String(data: data, encoding: .utf8) else {
      throw CodexDatabaseError.invalidStoredValue("Could not encode Codex approval JSON.")
    }
    return result
  }

  private static func decode(_ value: String) throws -> JSONValue {
    guard let data = value.data(using: .utf8) else {
      throw CodexDatabaseError.invalidStoredValue("Codex approval JSON is not UTF-8.")
    }
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }
}

private struct CodexRuntimeLeaseRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexRuntimeLeases"

  var id: String
  var workspaceID: String?
  var state: String
  var updatedAt: Date
  var payloadJSON: String

  init(_ value: CodexRuntimeLeaseRecord) throws {
    id = value.id
    workspaceID = value.owner?.workspaceID
    state = value.state
    updatedAt = value.updatedAt
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    payloadJSON = String(decoding: data, as: UTF8.self)
  }

  func value() throws -> CodexRuntimeLeaseRecord {
    guard let data = payloadJSON.data(using: .utf8) else {
      throw CodexDatabaseError.invalidStoredValue("Codex runtime lease is not UTF-8.")
    }
    return try JSONDecoder().decode(CodexRuntimeLeaseRecord.self, from: data)
  }
}

private struct CodexThreadOwnershipRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexThreadOwnership"

  var threadID: String
  var workspaceID: String?
  var workspacePath: String
  var runtimeID: String
  var state: String
  var createdAt: Date
  var updatedAt: Date

  init(_ value: CodexThreadOwnershipRecord) {
    threadID = value.threadID
    workspaceID = value.workspaceID
    workspacePath = value.workspacePath
    runtimeID = value.runtimeID
    state = value.state.rawValue
    createdAt = value.createdAt
    updatedAt = value.updatedAt
  }

  func value() throws -> CodexThreadOwnershipRecord {
    guard let state = CodexThreadOwnershipState(rawValue: state) else {
      throw CodexDatabaseError.invalidStoredValue(
        "Codex thread ownership contains an unknown state."
      )
    }
    return CodexThreadOwnershipRecord(
      threadID: threadID,
      workspaceID: workspaceID,
      workspacePath: workspacePath,
      runtimeID: runtimeID,
      state: state,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

private struct CodexThreadOwnershipReconciliationReceiptRow: Codable, FetchableRecord,
  PersistableRecord
{
  static let databaseTableName = "codexOwnershipReconciliationReceipts"

  var id: String
  var planDigest: String
  var appliedAt: Date
  var payloadJSON: String
}

private struct CodexOrchestrationRunRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexOrchestrationRuns"

  var id: String
  var workspaceID: String
  var state: String
  var updatedAt: Date
  var payloadJSON: String

  init(_ value: CodexOrchestrationRun) throws {
    id = value.id
    workspaceID = value.workspaceID
    state = value.state.rawValue
    updatedAt = value.updatedAt
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    payloadJSON = String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  func value() throws -> CodexOrchestrationRun {
    guard let data = payloadJSON.data(using: .utf8) else {
      throw CodexDatabaseError.invalidStoredValue("Codex orchestration run is not UTF-8.")
    }
    return try JSONDecoder().decode(CodexOrchestrationRun.self, from: data)
  }
}

private struct CodexWorktreeLeaseRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexWorktreeLeases"

  var id: String
  var workspaceID: String
  var state: String
  var heartbeatAt: Date
  var payloadJSON: String

  init(_ value: CodexWorktreeLease) throws {
    id = value.id
    workspaceID = value.workspaceID
    state = value.state.rawValue
    heartbeatAt = value.heartbeatAt
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    payloadJSON = String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  func value() throws -> CodexWorktreeLease {
    guard let data = payloadJSON.data(using: .utf8) else {
      throw CodexDatabaseError.invalidStoredValue("Codex worktree lease is not UTF-8.")
    }
    return try JSONDecoder().decode(CodexWorktreeLease.self, from: data)
  }
}

extension CodexDatabase {
  /// Decode using the existing row contract without rewriting payload JSON.
  /// Indexed identity and scope must agree with the payload consumed at runtime.
  static func validateMigrationRow(_ row: Row, table: String) throws {
    let valid: Bool
    switch table {
    case "codexApprovals":
      _ = try CodexApprovalRecordRow(row: row).value()
      valid = true
    case "codexThreadOwnership":
      _ = try CodexThreadOwnershipRow(row: row).value()
      valid = true
    case "codexRuntimeLeases":
      let record = try CodexRuntimeLeaseRow(row: row)
      let value = try record.value()
      valid =
        record.id == value.id && record.workspaceID == value.owner?.workspaceID
        && record.state == value.state
    case "codexOrchestrationRuns":
      let record = try CodexOrchestrationRunRow(row: row)
      let value = try record.value()
      valid =
        record.id == value.id && record.workspaceID == value.workspaceID
        && record.state == value.state.rawValue
    case "codexWorktreeLeases":
      let record = try CodexWorktreeLeaseRow(row: row)
      let value = try record.value()
      valid =
        record.id == value.id && record.workspaceID == value.workspaceID
        && record.state == value.state.rawValue
    case "codexManagedWorktrees":
      let record = try CodexManagedWorktreeRow(row: row)
      let value = try record.value()
      valid =
        record.id == value.id && record.workspaceID == value.workspaceID
        && record.sourceWorkspaceID == value.sourceWorkspaceID
        && record.state == value.state.rawValue
    case "codexOwnershipReconciliationReceipts":
      let record = try CodexThreadOwnershipReconciliationReceiptRow(row: row)
      let value = try JSONDecoder().decode(
        CodexThreadOwnershipReconciliationResult.self, from: Data(record.payloadJSON.utf8))
      valid = record.id == value.receiptID && record.planDigest == value.planDigest
    default:
      valid = false
    }
    guard valid else {
      throw CodexDatabaseError.invalidStoredValue(
        "Domain record identity or scope differs from its payload.")
    }
  }
}
