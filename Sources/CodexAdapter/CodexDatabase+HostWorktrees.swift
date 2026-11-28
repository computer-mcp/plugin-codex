import Foundation
import GRDB

extension CodexDatabase {
  static func createHostWorktreeTables(_ database: Database) throws {
    try database.create(table: "codexHostWorktrees") { table in
      table.column("id", .text).primaryKey()
      table.column("principalID", .text).notNull()
      table.column("profileID", .text).notNull()
      table.column("sourceProjectID", .text).notNull()
      table.column("childProjectID", .text)
      table.column("updatedAt", .datetime).notNull()
      table.column("payloadJSON", .text).notNull()
      table.uniqueKey(["principalID", "profileID", "childProjectID"])
    }
    try database.create(
      index: "codexHostWorktrees_on_source",
      on: "codexHostWorktrees",
      columns: ["principalID", "profileID", "sourceProjectID", "updatedAt"])
    try database.create(table: "codexWorktreeOperations") { table in
      table.column("id", .text).primaryKey()
      table.column("invocationID", .text).notNull().unique()
      table.column("domainID", .text).notNull().references("codexHostWorktrees")
      table.column("payloadJSON", .text).notNull()
    }
  }

  func hostWorktrees(in scope: CodexProjectScope, limit: Int) throws -> [CodexHostWorktree] {
    try worktreeLeaseWriter.read { database in
      try CodexHostWorktreeRow.visible(in: scope)
        .order(Column("updatedAt").desc, Column("id").desc)
        .limit(limit).fetchAll(database).map { try $0.value() }
    }
  }

  func hostWorktree(id: String, in scope: CodexProjectScope) throws
    -> (CodexHostWorktree, CodexWorktreeOperation?)?
  {
    try worktreeLeaseWriter.read { database in
      guard let worktree = try Self.visibleWorktree(id: id, scope: scope, in: database)
      else { return nil }
      let operation = try worktree.currentOperationID.map {
        try Self.operation(id: $0, worktree: worktree, in: database)
      }
      return (worktree, operation)
    }
  }

  func saveProvisionPlan(_ worktree: CodexHostWorktree, in scope: CodexProjectScope, now: Date)
    throws
  {
    try worktreeLeaseWriter.write { database in
      guard try Self.boundHostChild(in: database, scope: scope) == nil else {
        throw CodexManagedWorktreeError.invalid("Select the source project to plan creation.")
      }
      guard worktree.source == scope,
        try Self.hasActiveParent(worktree, in: database, now: now)
      else { throw CodexManagedWorktreeError.invalid("An active source parent lease is required.") }
      try CodexHostWorktreeRow(worktree).insert(database)
    }
  }

  func saveRemovalPlan(
    id: String, in scope: CodexProjectScope, force: Bool, now: Date
  ) throws -> CodexHostWorktree {
    try worktreeLeaseWriter.write { database in
      guard var worktree = try Self.visibleWorktree(id: id, scope: scope, in: database),
        worktree.creation?.projectID == scope.projectID
      else { throw CodexManagedWorktreeError.unknown(id) }
      guard
        worktree.state == .active
          || (worktree.state == .removalPlanned
            && worktree.planExpiresAt.map({ $0 <= now }) == true)
      else {
        throw CodexManagedWorktreeError.state("the worktree is unavailable for removal planning")
      }
      try Self.requireNoActiveLeases(in: database, scope: scope, now: now)
      worktree.state = .removalPlanned
      worktree.currentOperationID = nil
      worktree.force = force
      worktree.planExpiresAt = now.addingTimeInterval(300)
      worktree.revision += 1
      worktree.updatedAt = now
      try Self.saveHostWorktree(worktree, in: database)
      return worktree
    }
  }

  func beginWorktreeOperation(
    id: String, in scope: CodexProjectScope, action: CodexWorktreeAction,
    revision: Int, arguments: [String: JSONValue], ids: CodexHostOperationIDs, now: Date
  ) throws -> (CodexHostWorktree, CodexWorktreeOperation) {
    let digest = try CodexHostInvocation.digest(arguments)
    return try worktreeLeaseWriter.write { database in
      guard var worktree = try Self.visibleWorktree(id: id, scope: scope, in: database),
        action == .provision
          ? worktree.source == scope : worktree.creation?.projectID == scope.projectID
      else { throw CodexManagedWorktreeError.unknown(id) }
      guard worktree.revision == revision else {
        throw CodexManagedWorktreeError.revisionConflict(
          expected: revision, actual: worktree.revision)
      }
      guard worktree.state == (action == .provision ? .planned : .removalPlanned),
        worktree.planExpiresAt.map({ $0 > now }) == true
      else { throw CodexManagedWorktreeError.state("the plan is not current") }
      var reviewed = arguments
      if action == .remove, reviewed["force"] == nil { reviewed["force"] = .bool(false) }
      guard reviewed == worktree.performArguments else {
        throw CodexManagedWorktreeError.invalid(
          "perform arguments must match the reviewed plan, including optional creation fields")
      }
      if action == .provision {
        guard try Self.hasActiveParent(worktree, in: database, now: now) else {
          throw CodexManagedWorktreeError.state("the source parent lease is inactive")
        }
      } else {
        try Self.requireNoActiveLeases(in: database, scope: scope, now: now)
      }
      let operation = CodexWorktreeOperation(
        ids: ids, domainID: worktree.id, action: action, source: worktree.source,
        selectedProjectID: scope.projectID, arguments: arguments, argumentsDigest: digest)
      try CodexWorktreeOperationRow(operation).insert(database)
      worktree.currentOperationID = ids.operationID
      worktree.state = action.pendingState
      worktree.planExpiresAt = nil
      worktree.revision += 1
      worktree.updatedAt = now
      try Self.saveHostWorktree(worktree, in: database)
      return (worktree, operation)
    }
  }

  func settleWorktreeOperation(
    id: String, in scope: CodexProjectScope, operationID: UUID, envelope: JSONValue,
    response: CodexHostToolResponse, now: Date
  ) throws -> (CodexHostWorktree, CodexWorktreeOperation) {
    try worktreeLeaseWriter.write { database in
      guard var worktree = try Self.visibleWorktree(id: id, scope: scope, in: database)
      else { throw CodexManagedWorktreeError.unknown(id) }
      var operation = try Self.operation(id: operationID, worktree: worktree, in: database)
      let state = try operation.state(of: envelope)
      if operation.observedState?.isTerminal == true {
        guard
          !state.isTerminal
            || (operation.observedState == state
              && operation.envelope == envelope)
        else { throw CodexWorktreeObservationError.conflictingTerminalState }
        return (worktree, operation)
      }
      guard worktree.currentOperationID == operationID,
        worktree.state == operation.action.pendingState
      else { throw CodexWorktreeObservationError.invalidEnvelope }
      if (state == .reserved && operation.observedState == .running)
        || ((state == .reserved || state == .running)
          && operation.observedState == .recoveryRequired)
      {
        return (worktree, operation)
      }
      operation.observedState = state
      operation.envelope = envelope
      operation.response = response
      operation.observationError = nil
      operation.uncertainResponse = nil
      if state == .completed {
        let result = envelope.objectValue?["result"] ?? .null
        switch operation.action {
        case .provision:
          let creation = try CodexWorktreeCreation(result, worktree: worktree)
          worktree.creation = creation
          worktree.creationOperationID = operationID
          worktree.lease = try Self.settleCreationLease(
            worktree, creation: creation, in: database, now: now)
          worktree.state = .active
        case .remove:
          try Self.validateRemoval(result, worktree: worktree)
          worktree.state = .removed
          worktree.force = nil
        }
      } else if state == .failed {
        worktree.state = operation.action == .provision ? .failed : .active
        worktree.force = nil
      }
      if state.isTerminal {
        worktree.revision += 1
        worktree.updatedAt = now
        try Self.saveHostWorktree(worktree, in: database)
      }
      try CodexWorktreeOperationRow(operation).update(database)
      return (worktree, operation)
    }
  }

  func recordWorktreeObservationFailure(
    id: String, in scope: CodexProjectScope, operationID: UUID,
    response: CodexHostToolResponse?, message: String
  ) throws -> (CodexHostWorktree, CodexWorktreeOperation) {
    try worktreeLeaseWriter.write { database in
      guard let worktree = try Self.visibleWorktree(id: id, scope: scope, in: database)
      else { throw CodexManagedWorktreeError.unknown(id) }
      var operation = try Self.operation(id: operationID, worktree: worktree, in: database)
      if worktree.currentOperationID == operationID, operation.observedState?.isTerminal != true {
        operation.observationError = message
        if let response { operation.uncertainResponse = response }
        try CodexWorktreeOperationRow(operation).update(database)
      }
      return (worktree, operation)
    }
  }

  static func boundHostChild(in database: Database, scope: CodexProjectScope) throws
    -> CodexHostWorktree?
  {
    guard
      let worktree = try CodexHostWorktreeRow.subject(in: scope)
        .filter(Column("childProjectID") == scope.projectID).fetchOne(database)?.value()
    else { return nil }
    guard let id = worktree.creationOperationID,
      let creation = worktree.creation, creation.projectID == scope.projectID
    else { throw CodexWorktreeObservationError.invalidCompletion }
    let operation = try operation(id: id, worktree: worktree, in: database)
    guard operation.action == .provision, operation.observedState == .completed,
      operation.selectedProjectID == worktree.source.projectID,
      try operation.state(of: operation.envelope) == .completed,
      operation.envelope?.objectValue?["result"] == creation.result
    else { throw CodexWorktreeObservationError.invalidCompletion }
    return worktree
  }

  static func saveHostWorktree(_ worktree: CodexHostWorktree, in database: Database) throws {
    try CodexHostWorktreeRow(worktree).update(database)
  }

  private static func visibleWorktree(
    id: String, scope: CodexProjectScope, in database: Database
  ) throws -> CodexHostWorktree? {
    try CodexHostWorktreeRow.visible(in: scope)
      .filter(Column("id") == id).fetchOne(database)?.value()
  }

  private static func operation(id: UUID, worktree: CodexHostWorktree, in database: Database) throws
    -> CodexWorktreeOperation
  {
    guard let record = try CodexWorktreeOperationRow.fetchOne(database, key: id.uuidString),
      record.domainID == worktree.id
    else { throw CodexWorktreeObservationError.invalidEnvelope }
    let operation = try record.value()
    guard operation.domainID == worktree.id, operation.source == worktree.source,
      operation.ids.operationID == id
    else { throw CodexWorktreeObservationError.invalidEnvelope }
    return operation
  }

  private static func hasActiveParent(
    _ worktree: CodexHostWorktree, in database: Database, now: Date
  ) throws -> Bool {
    guard let parent = try worktreeLease(in: database, id: worktree.parentLeaseID)
    else { return false }
    return parent.workspaceID == worktree.source.projectID && parent.state == .active
      && parent.expiresAt > now
  }

  private static func requireNoActiveLeases(
    in database: Database, scope: CodexProjectScope, now: Date
  ) throws {
    guard try activeWorktreeLeases(in: database, projectID: scope.projectID, now: now).isEmpty
    else { throw CodexManagedWorktreeError.state("the child has an active writer lease") }
  }

  private static func settleCreationLease(
    _ worktree: CodexHostWorktree, creation: CodexWorktreeCreation, in database: Database, now: Date
  ) throws -> CodexWorktreeLeaseOutcome {
    guard try hasActiveParent(worktree, in: database, now: now)
    else { return .unavailable("source_parent_inactive") }
    let lease = CodexWorktreeLease(
      workspaceID: creation.projectID, workspacePath: creation.path, mode: .isolatedWorktree,
      agentID: worktree.agentID, threadID: worktree.threadID, runID: worktree.runID,
      parentLeaseID: worktree.parentLeaseID, branch: creation.branch,
      ttlSeconds: worktree.ttlSeconds, now: now, association: worktree)
    do {
      return .acquired(try acquireWorktreeLease(in: database, proposed: lease, now: now).id)
    } catch CodexWorktreeLeaseError.conflict {
      return .conflict
    }
  }

  private static func validateRemoval(_ result: JSONValue, worktree: CodexHostWorktree) throws {
    guard let creation = worktree.creation, let fields = result.objectValue,
      fields["worktree_id"]?.stringValue.flatMap(UUID.init(uuidString:)) == creation.worktreeID,
      fields["project_id"] == .string(creation.projectID),
      fields["branch"] == .string(creation.branch),
      let oid = fields["oid"]?.stringValue, [40, 64].contains(oid.utf8.count),
      oid.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let warnings = fields["termination_warnings"]?.arrayValue,
      warnings.allSatisfy({ $0.stringValue != nil })
    else { throw CodexWorktreeObservationError.invalidCompletion }
  }
}

private struct CodexHostWorktreeRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexHostWorktrees"

  let id: String
  let principalID: String
  let profileID: String
  let sourceProjectID: String
  let childProjectID: String?
  let updatedAt: Date
  let payloadJSON: String

  init(_ value: CodexHostWorktree) throws {
    id = value.id
    principalID = value.source.principalID
    profileID = value.source.profileID
    sourceProjectID = value.source.projectID
    childProjectID = value.creation?.projectID
    updatedAt = value.updatedAt
    payloadJSON = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }

  static func subject(in scope: CodexProjectScope) -> QueryInterfaceRequest<Self> {
    filter(Column("principalID") == scope.principalID && Column("profileID") == scope.profileID)
  }

  static func visible(in scope: CodexProjectScope) -> QueryInterfaceRequest<Self> {
    subject(in: scope).filter(
      Column("sourceProjectID") == scope.projectID || Column("childProjectID") == scope.projectID)
  }

  func value() throws -> CodexHostWorktree {
    try JSONDecoder().decode(CodexHostWorktree.self, from: Data(payloadJSON.utf8))
  }
}

private struct CodexWorktreeOperationRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexWorktreeOperations"

  let id: String
  let invocationID: String
  let domainID: String
  let payloadJSON: String

  init(_ value: CodexWorktreeOperation) throws {
    id = value.ids.operationID.uuidString
    invocationID = value.ids.invocationID.uuidString
    domainID = value.domainID
    payloadJSON = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }

  func value() throws -> CodexWorktreeOperation {
    try JSONDecoder().decode(CodexWorktreeOperation.self, from: Data(payloadJSON.utf8))
  }
}
