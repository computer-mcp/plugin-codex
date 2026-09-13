import Foundation
import GRDB
import Testing

@testable import CodexAdapter

@Suite(.serialized)
struct CodexStateMigrationTests {
  @Test func previewDoesNotCreateDestinationOrMutateSource() throws {
    let fixture = try Fixture()
    let before = try Data(contentsOf: fixture.source)
    let plan = try CodexStateMigration.preview(
      source: fixture.source, destination: fixture.destination)
    #expect(plan.canApply)
    #expect(!plan.destinationExists)
    #expect(plan.insertRows == 7)
    #expect(plan.tables.allSatisfy { $0.sourceRows == 1 })
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    #expect(try Data(contentsOf: fixture.source) == before)
  }

  @Test func migratesOnlyDomainTablesPreservesRawValuesAndIsIdempotent() throws {
    let fixture = try Fixture()
    let before = try Data(contentsOf: fixture.source)
    let first = try fixture.preview()
    let result = try fixture.apply(first)
    #expect(result.insertedRows == 7)
    #expect(try Data(contentsOf: fixture.source) == before)
    let reader = try DatabaseQueue(path: fixture.destination.path)
    defer { try? reader.close() }
    try reader.read { db throws -> Void in
      #expect(try !db.tableExists("hostSecrets"))
      #expect(try !db.tableExists("codexElevationGrants"))
      for name in CodexStateMigration.tables {
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(name)") == 1)
      }
    }
    let source = try DatabaseQueue(path: fixture.source.path)
    defer { try? source.close() }
    for name in CodexStateMigration.tables {
      let original = try source.read { try Row.fetchAll($0, sql: "SELECT * FROM \(name)") }
      let copied = try reader.read { try Row.fetchAll($0, sql: "SELECT * FROM \(name)") }
      #expect(original == copied)
    }
    let again = try fixture.preview()
    #expect(again.tables.allSatisfy { $0.identicalRows == 1 })
    #expect(try fixture.apply(again).insertedRows == 0)
    let database = try CodexDatabase(path: fixture.destination.path)
    #expect(try database.codexThreadOwnership(threadID: "thread-一")?.state == .released)
    #expect(try database.codexApproval(id: "approval-1")?.state == .interrupted)
    #expect(try database.codexRuntimeLeases().first?.state == "stopped")
  }

  @Test func conflictRejectsWholeImportWithoutOverwritingOrPartialRows() throws {
    let fixture = try Fixture()
    do {
      let target = try CodexDatabase(path: fixture.destination.path)
      try target.saveCodexThreadOwnership(
        .init(
          threadID: "thread-一", workspaceID: "other-workspace", workspacePath: "/tmp/other",
          runtimeID: "different", state: .archived, createdAt: fixture.date, updatedAt: fixture.date
        ))
    }
    let plan = try fixture.preview()
    #expect(!plan.canApply)
    #expect(plan.tables.first { $0.name == "codexThreadOwnership" }?.conflictingRows == 1)
    let before = try Data(contentsOf: fixture.destination)
    #expect(throws: CodexStateMigration.Failure.self) { try fixture.apply(plan) }
    #expect(try Data(contentsOf: fixture.destination) == before)
    let database = try CodexDatabase(path: fixture.destination.path)
    #expect(try database.codexApprovals().isEmpty)
    #expect(try database.codexThreadOwnership(threadID: "thread-一")?.runtimeID == "different")
  }

  @Test func changedSourceRejectsReviewedPlanWithoutCreatingDestination() throws {
    let fixture = try Fixture()
    let plan = try fixture.preview()
    try fixture.write(fixture.source) { db in
      try db.execute(sql: "UPDATE codexThreadOwnership SET workspacePath = '/different'")
    }
    #expect(throws: CodexStateMigration.Failure.self) { try fixture.apply(plan) }
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test func changedDestinationRejectsReviewedPlanWithoutAddingSourceRecords() throws {
    let fixture = try Fixture()
    do { _ = try CodexDatabase(path: fixture.destination.path) }
    let plan = try fixture.preview()
    do {
      let target = try CodexDatabase(path: fixture.destination.path)
      try target.saveCodexThreadOwnership(
        .init(
          threadID: "new-local-thread", workspaceID: nil, workspacePath: "/tmp/local",
          runtimeID: "local", state: .released, createdAt: fixture.date, updatedAt: fixture.date))
    }
    #expect(throws: CodexStateMigration.Failure.self) { try fixture.apply(plan) }
    let target = try CodexDatabase(path: fixture.destination.path)
    #expect(try target.codexApprovals().isEmpty)
    #expect(try target.codexThreadOwnerships().count == 1)
  }

  @Test func lateConstraintFailureRollsBackEarlierTables() throws {
    let fixture = try Fixture()
    do { _ = try CodexDatabase(path: fixture.destination.path) }
    try fixture.write(fixture.destination) { db in
      // A constraint beyond the shared column contract fails after earlier
      // tables have been inserted. The transaction must still roll them back.
      try db.execute(sql: "CREATE UNIQUE INDEX reject_two_states ON codexThreadOwnership(state)")
      try db.execute(
        sql: "INSERT INTO codexThreadOwnership VALUES (?, NULL, ?, ?, ?, ?, ?)",
        arguments: ["local-thread", "/tmp/local", "local", "released", fixture.date, fixture.date])
    }
    let plan = try fixture.preview()
    #expect(throws: (any Error).self) { try fixture.apply(plan) }
    let target = try CodexDatabase(path: fixture.destination.path)
    #expect(try target.codexApprovals().isEmpty)
    #expect(try target.codexRuntimeLeases().isEmpty)
    #expect(try target.codexThreadOwnerships().count == 1)
  }

  @Test(arguments: ["-wal", "-shm", "-journal"])
  func sidecarsRefusePotentiallyLiveSnapshots(_ suffix: String) throws {
    let fixture = try Fixture()
    try Data().write(to: URL(fileURLWithPath: fixture.source.path + suffix))
    #expect(throws: CodexStateMigration.Failure.self) { try fixture.preview() }
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test func sourceDestinationAliasesAndSymbolicLinksAreRejected() throws {
    let fixture = try Fixture()
    #expect(throws: CodexStateMigration.Failure.self) {
      try CodexStateMigration.preview(source: fixture.source, destination: fixture.source)
    }
    try FileManager.default.linkItem(at: fixture.source, to: fixture.destination)
    #expect(throws: CodexStateMigration.Failure.self) { try fixture.preview() }
    try FileManager.default.removeItem(at: fixture.destination)
    try FileManager.default.createSymbolicLink(
      at: fixture.destination, withDestinationURL: fixture.source)
    #expect(throws: CodexStateMigration.Failure.self) { try fixture.preview() }
  }

  @Test func destinationMustNotBeHostDatabase() throws {
    let fixture = try Fixture()
    try FileManager.default.copyItem(at: fixture.source, to: fixture.destination)
    #expect(throws: CodexStateMigration.Failure.self) { try fixture.preview() }
  }

  @Test func unknownColumnsAndMalformedPayloadsAreRejectedWithoutDisclosingValues() throws {
    let fixture = try Fixture()
    try fixture.write(fixture.source) { db in
      try db.execute(
        sql: "UPDATE codexRuntimeLeases SET payloadJSON = ?", arguments: ["secret=fixture-only"])
    }
    do {
      _ = try fixture.preview()
      Issue.record("Malformed domain JSON was accepted.")
    } catch {
      #expect(!error.localizedDescription.contains("fixture-only"))
    }
    let second = try Fixture()
    try second.write(second.source) { db in
      try db.execute(sql: "ALTER TABLE codexApprovals ADD COLUMN future_field TEXT")
    }
    #expect(throws: CodexStateMigration.Failure.self) { try second.preview() }
  }

  @Test func indexedScopeMustMatchPayload() throws {
    let fixture = try Fixture()
    try fixture.write(fixture.source) { db in
      try db.execute(sql: "UPDATE codexManagedWorktrees SET sourceWorkspaceID = 'foreign'")
    }
    #expect(throws: CodexStateMigration.Failure.self) { try fixture.preview() }
  }

  @Test func olderSnapshotMayOmitTablesButUnrelatedDatabaseIsNotAccepted() throws {
    let fixture = try Fixture()
    try fixture.write(fixture.source) { db in
      for table in CodexStateMigration.tables where table != "codexThreadOwnership" {
        try db.execute(sql: "DROP TABLE \(table)")
      }
    }
    #expect(try fixture.preview().insertRows == 1)
    try fixture.write(fixture.source) { db in try db.execute(sql: "DROP TABLE codexThreadOwnership")
    }
    #expect(throws: CodexStateMigration.Failure.self) { try fixture.preview() }
  }

  @Test func invalidDigestDoesNotCreateFiles() throws {
    let fixture = try Fixture()
    #expect(throws: CodexStateMigration.Failure.self) {
      try CodexStateMigration.apply(
        source: fixture.source, destination: fixture.destination, expectedPlanDigest: "bad")
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test func canonicallyEquivalentTextIsNotMistakenForByteIdenticalState() throws {
    let fixture = try Fixture()
    _ = try fixture.apply(fixture.preview())
    try fixture.write(fixture.source) { db in
      try db.execute(
        sql: "UPDATE codexThreadOwnership SET workspacePath = ?", arguments: ["/tmp/\u{00e9}"])
    }
    try fixture.write(fixture.destination) { db in
      try db.execute(
        sql: "UPDATE codexThreadOwnership SET workspacePath = ?", arguments: ["/tmp/e\u{0301}"])
    }
    let plan = try fixture.preview()
    #expect(!plan.canApply)
    #expect(plan.tables.first { $0.name == "codexThreadOwnership" }?.conflictingRows == 1)
    #expect(throws: CodexStateMigration.Failure.self) { try fixture.apply(plan) }
  }

  @Test func byteDistinctSQLiteKeysSurviveSwiftCanonicalEquivalence() throws {
    let fixture = try Fixture()
    try fixture.write(fixture.source) { db in
      for key in ["\u{00e9}", "e\u{0301}"] {
        try db.execute(
          sql: "INSERT INTO codexThreadOwnership VALUES (?, NULL, ?, ?, ?, ?, ?)",
          arguments: [key, "/tmp/local", "runtime", "released", fixture.date, fixture.date])
      }
    }
    let plan = try fixture.preview()
    #expect(plan.insertRows == 9)
    #expect(try fixture.apply(plan).insertedRows == 9)
  }

  @Test func invalidUTF8IsRejectedRatherThanReplaced() throws {
    let fixture = try Fixture()
    try fixture.write(fixture.source) { db in
      try db.execute(sql: "UPDATE codexThreadOwnership SET workspacePath = CAST(x'ff' AS TEXT)")
    }
    #expect(throws: CodexStateMigration.Failure.self) { try fixture.preview() }
  }

  @Test func missingTargetMigrationHistoryAndTriggersFailClosed() throws {
    let fixture = try Fixture()
    do { _ = try CodexDatabase(path: fixture.destination.path) }
    try fixture.write(fixture.destination) { db in
      try db.execute(sql: "DELETE FROM grdb_migrations")
    }
    #expect(throws: CodexStateMigration.Failure.self) { try fixture.preview() }
    let second = try Fixture()
    do { _ = try CodexDatabase(path: second.destination.path) }
    try second.write(second.destination) { db in
      try db.execute(
        sql:
          "CREATE TRIGGER extra_side_effect AFTER INSERT ON codexApprovals BEGIN DELETE FROM codexThreadOwnership; END"
      )
    }
    #expect(throws: CodexStateMigration.Failure.self) { try second.preview() }
  }

  @Test func encodedPreviewContainsNoStoredPayloadOrHostSecret() throws {
    let fixture = try Fixture()
    let data = try CodexAdapterServer.migrateState(
      source: fixture.source, destination: fixture.destination)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("must-not-migrate"))
    #expect(!text.contains("retain-me"))
    #expect(!text.contains("thread-一"))
    #expect(text.contains("can_apply"))
    #expect(text.contains("plan_digest"))
  }

  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var source: URL { root.appendingPathComponent("host snapshot.sqlite") }
    var destination: URL { root.appendingPathComponent("adapter.sqlite") }
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      try seed()
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func preview() throws -> CodexStateMigration.Plan {
      try CodexStateMigration.preview(source: source, destination: destination)
    }
    func apply(_ plan: CodexStateMigration.Plan) throws -> CodexStateMigration.Result {
      try CodexStateMigration.apply(
        source: source, destination: destination, expectedPlanDigest: plan.planDigest)
    }
    func write(_ file: URL, _ body: (Database) throws -> Void) throws {
      let writer = try DatabaseQueue(path: file.path)
      defer { try? writer.close() }
      try writer.write(body)
    }
    private func seed() throws {
      do {
        let database = try CodexDatabase(path: source.path)
        try database.saveCodexApproval(
          .init(
            id: "approval-1", upstreamRequestID: "request-1", kind: .commandExecution,
            risk: .readOnly,
            state: .interrupted, workspaceID: "workspace", workspacePath: "/tmp/工作区",
            runtimeID: "runtime",
            threadID: "thread-一", turnID: nil, itemID: nil, correlationID: "correlation",
            socketConnectionID: nil,
            tunnelInstanceID: nil, details: .object(["text": .string("Unicode 零\0空")]),
            proposedAction: .object([:]),
            createdAt: date, expiresAt: date, resolvedAt: date, decision: nil, scope: "",
            resolutionReason: "shutdown"))
        try database.saveCodexRuntimeLease(
          .init(
            id: "runtime", owner: nil, workspacePath: "/tmp/工作区", state: "stopped", process: nil,
            createdAt: date, updatedAt: date, shutdownReason: "closed", cleanedAt: nil))
        try database.saveCodexThreadOwnership(
          .init(
            threadID: "thread-一", workspaceID: "workspace", workspacePath: "/tmp/工作区",
            runtimeID: "runtime", state: .released, createdAt: date, updatedAt: date))
        _ = try database.applyCodexThreadOwnershipReconciliation(
          plan: .init(
            schemaVersion: 1, planDigest: "digest", candidates: [], signalsSent: false,
            externalStateMutated: false), now: date)
        try database.saveCodexOrchestrationRun(
          .init(
            id: "run", workspaceID: "workspace", workspacePath: "/tmp/工作区", parentRunID: nil,
            threadID: "thread-一", officialGoalLinked: true, objective: "Retain Goal linkage",
            acceptedScope: ["scope"],
            currentPhase: "implementation", acceptanceCriteria: [], evidence: [],
            state: .budgetLimited,
            activeTurnID: nil, pendingApprovalID: nil, blockers: [], nextAction: nil,
            terminalReason: nil,
            lastMeaningfulProgressAt: date, repositoryDigest: nil, activeCommandID: nil,
            lastCommandProgressAt: nil,
            repeatedPlanningCount: 0, repeatedFailureFingerprint: nil, repeatedFailureCount: 0,
            turnsUsed: 1,
            requiredEvidenceKinds: [],
            budget: .init(
              maxTurns: 20, maxDurationSeconds: 300, maxNoProgressSeconds: 60,
              maxRepeatedFailures: 3),
            createdAt: date, updatedAt: date, revision: 1, diagnostics: []))
        _ = try database.acquireCodexWorktreeLease(
          workspaceID: "workspace", workspacePath: "/tmp/工作区", mode: .exclusive, agentID: "agent",
          threadID: "thread-一", runID: "run", parentLeaseID: nil, branch: "work", ttlSeconds: 60,
          now: date)
        try database.saveCodexManagedWorktree(
          .init(
            id: "worktree", sourceWorkspaceID: "workspace", workspaceID: "child",
            sourceRepositoryRoot: "/tmp/repo",
            gitCommonDirectory: "/tmp/repo/.git", path: "/tmp/child", branch: "child",
            startPoint: "HEAD", headOID: "oid",
            agentID: "agent", threadID: nil, runID: nil, parentLeaseID: "parent",
            profileID: "profile", caller: "caller",
            ttlSeconds: 60, leaseID: nil, state: .removed, createdAt: date, updatedAt: date,
            planExpiresAt: nil,
            removedAt: date, lastError: nil, revision: 1))
      }
      try write(source) { db in
        try db.execute(sql: "CREATE TABLE hostSecrets (secret TEXT)")
        try db.execute(sql: "INSERT INTO hostSecrets VALUES ('must-not-migrate')")
        try db.execute(sql: "CREATE TABLE codexElevationGrants (secret TEXT)")
        try db.execute(sql: "INSERT INTO codexElevationGrants VALUES ('never-grant-authority')")
        // Unknown payload fields remain exactly as stored, not lost to Codable re-encoding.
        try db.execute(
          sql:
            "UPDATE codexRuntimeLeases SET payloadJSON = json_set(payloadJSON, '$.futureField', 'retain-me')"
        )
      }
    }
  }
}
