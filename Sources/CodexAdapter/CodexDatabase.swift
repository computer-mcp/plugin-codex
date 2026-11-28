import Foundation
import GRDB

/// Adapter-owned domain records. Host grants, credentials, workspaces and audit stay with the host.
final class CodexDatabase: @unchecked Sendable {
  private let writer: any DatabaseWriter
  let worktreeLeaseWriter: any DatabaseWriter
  let sharesWorktreeLeases: Bool
  let fileURL: URL?

  init(path: String, worktreeLeasePath: String? = nil) throws {
    fileURL = URL(fileURLWithPath: path).standardizedFileURL
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    writer = try DatabaseQueue(path: path, configuration: configuration)
    sharesWorktreeLeases = worktreeLeasePath != nil
    if let worktreeLeasePath {
      worktreeLeaseWriter = try DatabaseQueue(path: worktreeLeasePath, configuration: configuration)
    } else {
      worktreeLeaseWriter = writer
    }
    let primaryMigrator = Self.primaryMigrator(includesLocalWorktrees: !sharesWorktreeLeases)
    try Self.validateMigrations(primaryMigrator, in: writer)
    if sharesWorktreeLeases {
      try Self.validateMigrations(Self.worktreeLeaseMigrator, in: worktreeLeaseWriter)
      try Self.worktreeLeaseMigrator.migrate(worktreeLeaseWriter)
    }
    try primaryMigrator.migrate(writer)
  }

  init(inMemory: Void) throws {
    fileURL = nil
    writer = try DatabaseQueue()
    worktreeLeaseWriter = writer
    sharesWorktreeLeases = false
    try Self.migrator.migrate(writer)
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
        .map { try $0.value() }
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
    try worktreeLeaseWriter.read { database in
      try CodexWorktreeLeaseRow.fetchOne(database, key: id)?.value()
    }
  }

  func codexWorktreeLeases(
    workspaceID: String? = nil,
    states: Set<CodexWorktreeLeaseState> = [],
    limit: Int = 500
  ) throws -> [CodexWorktreeLease] {
    try worktreeLeaseWriter.read { database in
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
    now: Date,
    scope: CodexProjectScope?
  ) throws -> CodexWorktreeLease {
    try worktreeLeaseWriter.write { database in
      guard scope == nil || scope?.projectID == workspaceID else {
        throw CodexWorktreeLeaseError.invalid("The lease must use the selected project.")
      }
      let association = try scope.flatMap { try Self.boundHostChild(in: database, scope: $0) }
      let parent = try parentLeaseID.flatMap { try Self.worktreeLease(in: database, id: $0) }
      if parentLeaseID != nil {
        guard let parent, parent.state == .active, parent.expiresAt > now else {
          throw CodexWorktreeLeaseError.invalid("parent_lease_id must identify an active lease")
        }
        guard parent.workspaceID != workspaceID || parent.mode == .exclusive else {
          throw CodexWorktreeLeaseError.invalid(
            "an isolated child must use a separately registered worktree project")
        }
        if sharesWorktreeLeases, parent.workspaceID != workspaceID, association == nil {
          throw CodexWorktreeLeaseError.invalid(
            "The parent lease requires a completed host worktree association.")
        }
      }

      if let association {
        guard
          association.state == .active
            || (association.state == .removalPlanned
              && association.planExpiresAt.map({ $0 <= now }) == true)
        else {
          throw CodexWorktreeLeaseError.invalid("The host worktree is pending removal or removed.")
        }
        guard let host = association.creation, association.creationOperationID != nil,
          let parent,
          parent.workspaceID == association.source.projectID, host.path == workspacePath,
          branch == nil || branch == host.branch
        else {
          throw CodexWorktreeLeaseError.invalid(
            "The lease must use the selected host worktree and its source parent.")
        }
      }

      let proposed = CodexWorktreeLease(
        workspaceID: workspaceID, workspacePath: workspacePath, mode: mode, agentID: agentID,
        threadID: threadID, runID: runID, parentLeaseID: parentLeaseID,
        branch: association?.creation?.branch ?? branch, ttlSeconds: ttlSeconds, now: now,
        association: association)
      let acquired = try Self.acquireWorktreeLease(in: database, proposed: proposed, now: now)
      if var association,
        association.lease != .acquired(acquired.id) || association.state == .removalPlanned
      {
        association.lease = .acquired(acquired.id)
        association.state = .active
        association.force = nil
        association.planExpiresAt = nil
        association.revision += 1
        association.updatedAt = now
        try Self.saveHostWorktree(association, in: database)
      }
      return acquired
    }
  }

  static func worktreeLease(in database: Database, id: String) throws -> CodexWorktreeLease? {
    try CodexWorktreeLeaseRow.fetchOne(database, key: id)?.value()
  }

  static func activeWorktreeLeases(in database: Database, projectID: String, now: Date) throws
    -> [CodexWorktreeLease]
  {
    let rows =
      try CodexWorktreeLeaseRow
      .filter(Column("workspaceID") == projectID)
      .filter(Column("state") == CodexWorktreeLeaseState.active.rawValue)
      .fetchAll(database)
    var active: [CodexWorktreeLease] = []
    for row in rows {
      var lease = try row.value()
      if lease.expiresAt > now {
        active.append(lease)
      } else {
        lease.state = .expired
        lease.releasedAt = now
        lease.releaseReason = "lease_ttl_expired"
        lease.revision += 1
        try CodexWorktreeLeaseRow(lease).save(database)
      }
    }
    return active
  }

  static func acquireWorktreeLease(
    in database: Database, proposed: CodexWorktreeLease, now: Date
  ) throws -> CodexWorktreeLease {
    let active = try activeWorktreeLeases(in: database, projectID: proposed.workspaceID, now: now)
    if let existing = active.first {
      guard active.count == 1, existing.agentID == proposed.agentID,
        existing.threadID == proposed.threadID, existing.runID == proposed.runID,
        proposed.hostWorktreeID == nil
          || (existing.hostWorktreeID == proposed.hostWorktreeID
            && existing.creationOperationID == proposed.creationOperationID
            && existing.managedWorktreeID == proposed.managedWorktreeID
            && existing.parentLeaseID == proposed.parentLeaseID
            && existing.workspacePath == proposed.workspacePath
            && existing.mode == proposed.mode && existing.branch == proposed.branch)
      else { throw CodexWorktreeLeaseError.conflict(existing) }
      return existing
    }
    try CodexWorktreeLeaseRow(proposed).insert(database)
    return proposed
  }

  func updateCodexWorktreeLease(
    id: String,
    workspaceID: String?,
    expectedRevision: Int,
    mutate: (inout CodexWorktreeLease) throws -> Void
  ) throws -> CodexWorktreeLease {
    try worktreeLeaseWriter.write { database in
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

  func unmanagedWorktrees(owner: CodexRuntimeOwner, limit: Int) throws -> [JSONValue] {
    guard let project = owner.workspaceID else { return [] }
    return try writer.read { database in
      let rows =
        try CodexManagedWorktreeRow
        .filter(Column("sourceWorkspaceID") == project)
        .filter(Column("state") == CodexManagedWorktreeState.unmanaged.rawValue)
        .order(Column("updatedAt").desc, Column("id").desc)
        .fetchCursor(database)
      var history: [JSONValue] = []
      while history.count < limit, let row = try rows.next() {
        if let item = try row.history(for: owner) { history.append(item) }
      }
      return history
    }
  }

  func unmanagedWorktree(id: String, owner: CodexRuntimeOwner) throws -> JSONValue? {
    try writer.read { database in
      try CodexManagedWorktreeRow.fetchOne(database, key: id)?.history(for: owner)
    }
  }

  static var migrator: DatabaseMigrator { primaryMigrator(includesLocalWorktrees: true) }

  private static func primaryMigrator(includesLocalWorktrees: Bool) -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("codex-initial") { database in
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
        table.column("ownerJSON", .text)
        table.column("responseJSON", .text)
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
      try database.create(table: "codexThreadOwnership") { table in
        table.column("threadID", .text).primaryKey()
        table.column("workspaceID", .text)
        table.column("workspacePath", .text).notNull()
        table.column("runtimeID", .text).notNull()
        table.column("state", .text).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
        table.column("ownerJSON", .text)
      }
      try database.create(
        index: "codexThreadOwnership_on_workspace_state_updatedAt",
        on: "codexThreadOwnership",
        columns: ["workspaceID", "state", "updatedAt"]
      )
      try database.create(table: "codexOwnershipReconciliationReceipts") { table in
        table.column("id", .text).primaryKey()
        table.column("planDigest", .text).notNull()
        table.column("appliedAt", .datetime).notNull()
        table.column("payloadJSON", .text).notNull()
      }
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
      try createWorktreeLeaseTable(database)
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
    migrator.registerMigration("codex-projects-v1-history") { database in
      for var row in try CodexManagedWorktreeRow.fetchAll(database) {
        var payload = try row.payload()
        payload["previous_state"] = payload["state"] ?? .string(row.state)
        payload["state"] = .string(CodexManagedWorktreeState.unmanaged.rawValue)
        row.state = CodexManagedWorktreeState.unmanaged.rawValue
        row.payloadJSON = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        try row.update(database)
      }
    }
    if includesLocalWorktrees {
      migrator.registerMigration(
        "codex-projects-v1-local-worktrees", migrate: createHostWorktreeTables)
    }
    return migrator
  }

  private static var worktreeLeaseMigrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("codex-worktree-leases-initial", migrate: createWorktreeLeaseTable)
    migrator.registerMigration(
      "codex-projects-v1-shared-worktrees", migrate: createHostWorktreeTables)
    return migrator
  }

  private static func validateMigrations(
    _ migrator: DatabaseMigrator, in writer: any DatabaseWriter
  ) throws {
    let unknown = try writer.read { database in
      try migrator.appliedIdentifiers(database).subtracting(migrator.migrations).sorted()
    }
    guard unknown.isEmpty else { throw IncompatibleMigrations(identifiers: unknown) }
  }

  struct IncompatibleMigrations: Error, LocalizedError {
    let identifiers: [String]

    var errorDescription: String? {
      "Unsupported adapter database migrations: \(identifiers.joined(separator: ", ")). Use a new adapter state directory."
    }
  }

  private static func createWorktreeLeaseTable(_ database: Database) throws {
    try database.create(table: "codexWorktreeLeases") { table in
      table.column("id", .text).primaryKey()
      table.column("workspaceID", .text).notNull()
      table.column("state", .text).notNull()
      table.column("heartbeatAt", .datetime).notNull()
      table.column("payloadJSON", .text).notNull()
    }
    try database.create(
      index: "codexWorktreeLeases_on_workspace_state_heartbeatAt",
      on: "codexWorktreeLeases", columns: ["workspaceID", "state", "heartbeatAt"])
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

  func payload() throws -> [String: JSONValue] {
    try JSONDecoder().decode([String: JSONValue].self, from: Data(payloadJSON.utf8))
  }

  func history(for owner: CodexRuntimeOwner) throws -> JSONValue? {
    guard state == CodexManagedWorktreeState.unmanaged.rawValue,
      sourceWorkspaceID == owner.workspaceID
    else { return nil }
    let fields = try payload()
    guard fields["principal_id"]?.stringValue == owner.principalID,
      owner.principalID == nil || fields["profile_id"]?.stringValue == owner.profileID
    else { return nil }
    return .object(fields)
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
  var ownerJSON: String?
  var responseJSON: String?

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
    decision = try value.decision.map(Self.encode)
    ownerJSON = try value.owner.map {
      String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
    }
    responseJSON = try value.response.map(Self.encode)
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
    // Historical rows stored the caller decision as an unquoted string.
    let decision = decision.map { (try? Self.decode($0)) ?? .string($0) }
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
      resolutionReason: resolutionReason,
      owner: try ownerJSON.map {
        try JSONDecoder().decode(CodexRuntimeOwner.self, from: Data($0.utf8))
      },
      response: try responseJSON.map(Self.decode)
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
  var ownerJSON: String?

  init(_ value: CodexThreadOwnershipRecord) throws {
    threadID = value.threadID
    workspaceID = value.workspaceID
    workspacePath = value.workspacePath
    runtimeID = value.runtimeID
    state = value.state.rawValue
    createdAt = value.createdAt
    updatedAt = value.updatedAt
    ownerJSON = try value.owner.map {
      String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
    }
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
      updatedAt: updatedAt,
      owner: try ownerJSON.map {
        try JSONDecoder().decode(CodexRuntimeOwner.self, from: Data($0.utf8))
      }
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
