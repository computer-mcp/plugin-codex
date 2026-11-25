import Foundation
import GRDB
import Testing

@testable import CodexAdapter

struct CodexDatabaseSchemaTests {
  @Test func originalMigrationMatchesCapturedSchema() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("codex.sqlite").path
    let queue = try DatabaseQueue(path: path)
    try CodexDatabase.migrator.migrate(queue, upTo: "codex-initial")
    let fixture = try #require(
      Bundle.module.url(
        forResource: "codex-schema", withExtension: "json", subdirectory: "Fixtures"))
    let expected = try JSONDecoder().decode([SchemaObject].self, from: Data(contentsOf: fixture))
    #expect(try schema(queue) == expected)
    #expect(
      try queue.read { try CodexDatabase.migrator.appliedIdentifiers($0) } == ["codex-initial"])
    _ = try CodexDatabase(path: path)
    let upgraded = try schema(queue)
    #expect(
      upgraded.filter { !["codexHostWorktrees", "codexWorktreeOperations"].contains($0.table) }
        == expected)
    #expect(upgraded.contains { $0.name == "codexHostWorktrees" })
    #expect(upgraded.contains { $0.name == "codexWorktreeOperations" })
    _ = try CodexDatabase(path: path)
    #expect(try schema(queue) == upgraded)
  }

  @Test(arguments: [false, true])
  func unknownMigrationIsRejectedBeforeEitherStoreChanges(sharedLeaseStore: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("codex.sqlite").path
    let leases = directory.appendingPathComponent("leases.sqlite").path
    let primary = try DatabaseQueue(path: path)
    let shared = try DatabaseQueue(path: leases)
    let target = sharedLeaseStore ? shared : primary
    try target.write { database in
      try database.execute(
        sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
      try database.execute(sql: "INSERT INTO grdb_migrations VALUES ('unrecognized-version')")
      try database.execute(sql: "CREATE TABLE retained (value TEXT NOT NULL UNIQUE)")
      try database.execute(sql: "INSERT INTO retained VALUES ('keep')")
    }
    let primaryBefore = try schema(primary)
    let sharedBefore = try schema(shared)
    #expect(throws: CodexDatabase.IncompatibleMigrations.self) {
      try CodexDatabase(path: path, worktreeLeasePath: leases)
    }
    #expect(try schema(primary) == primaryBefore)
    #expect(try schema(shared) == sharedBefore)
    #expect(
      try target.read { try String.fetchOne($0, sql: "SELECT value FROM retained") } == "keep")
    #expect(
      try target.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        == ["unrecognized-version"])
  }

  @Test func sharedLeaseStoreUsesTheSameTableAndIndexDefinitions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("codex.sqlite").path
    let leases = directory.appendingPathComponent("leases.sqlite").path
    _ = try CodexDatabase(path: path, worktreeLeasePath: leases)
    let primary = try schema(DatabaseQueue(path: path)).filter { $0.table == "codexWorktreeLeases" }
    let shared = try schema(DatabaseQueue(path: leases)).filter {
      $0.table == "codexWorktreeLeases"
    }
    #expect(!primary.isEmpty)
    #expect(shared == primary)
    _ = try CodexDatabase(path: path, worktreeLeasePath: leases)
  }

  @Test(arguments: [false, true])
  func historicalRowsAreUnmanagedAcrossIndependentStoreMigrations(splitStore: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("codex.sqlite").path
    let leases = directory.appendingPathComponent("leases.sqlite").path
    let checkout = directory.appendingPathComponent("historical-checkout")
    let original = Data("historical checkout data".utf8)
    try original.write(to: checkout)
    let primary = try DatabaseQueue(path: path)
    try CodexDatabase.migrator.migrate(primary, upTo: "codex-initial")
    let states = [
      "planned", "provisioning", "active", "removal_planned", "removing", "removed", "failed",
    ]
    try primary.write { database in
      for state in states {
        let payload: [String: JSONValue] = [
          "id": .string(state), "state": .string(state), "path": .string(checkout.path),
          "principal_id": .string("principal"), "profile_id": .string("profile"),
          "source_workspace_id": .string("source"),
          "workspace_id": .string("codex-worktree-\(state)"),
          "retained_extension": .integer(42),
        ]
        try database.execute(
          sql: "INSERT INTO codexManagedWorktrees VALUES (?, ?, ?, ?, ?, ?)",
          arguments: [
            state, "source", "codex-worktree-\(state)", state, Date(),
            String(decoding: try JSONEncoder().encode(payload), as: UTF8.self),
          ])
      }
    }
    if splitStore {
      try primary.write { database in
        try database.execute(
          sql: """
            CREATE TRIGGER reject_history_update BEFORE UPDATE ON codexManagedWorktrees
            BEGIN SELECT RAISE(ABORT, 'fixture interrupted migration'); END
            """)
      }
      #expect(throws: DatabaseError.self) {
        try CodexDatabase(path: path, worktreeLeasePath: leases)
      }
      #expect(
        try schema(DatabaseQueue(path: leases)).contains { $0.name == "codexWorktreeOperations" })
      #expect(
        try primary.read {
          try String.fetchAll($0, sql: "SELECT state FROM codexManagedWorktrees").sorted()
        }
          == states.sorted())
      try primary.write { try $0.execute(sql: "DROP TRIGGER reject_history_update") }
    }
    let database = try CodexDatabase(path: path, worktreeLeasePath: splitStore ? leases : nil)
    let owner = CodexRuntimeOwner(
      workspaceID: "source", profileID: "profile", caller: "local-mcp", transport: nil,
      socketConnectionID: nil, tunnelInstanceID: nil, tunnelProfileID: nil, principalID: "principal"
    )
    let history = try database.unmanagedWorktrees(owner: owner, limit: 20)
    #expect(history.count == states.count)
    for item in history {
      let row = try #require(item.objectValue)
      #expect(row["state"] == .string("unmanaged"))
      #expect(row["previous_state"] == row["id"])
      #expect(row["path"] == .string(checkout.path))
      #expect(row["retained_extension"] == .integer(42))
    }
    let sqlStates = try primary.read {
      try String.fetchAll($0, sql: "SELECT DISTINCT state FROM codexManagedWorktrees")
    }
    #expect(sqlStates == ["unmanaged"])
    let scope = try #require(CodexProjectScope(owner))
    #expect(try database.hostWorktrees(in: scope, limit: 20).isEmpty)
    #expect(try Data(contentsOf: checkout) == original)
    let reopened = try CodexDatabase(path: path, worktreeLeasePath: splitStore ? leases : nil)
    #expect(try reopened.unmanagedWorktrees(owner: owner, limit: 20) == history)
  }

  private struct SchemaObject: Codable, Equatable {
    let type: String
    let name: String
    let table: String
    let sql: String?
  }

  private func schema(_ queue: DatabaseQueue) throws -> [SchemaObject] {
    try queue.read { database in
      try Row.fetchAll(
        database, sql: "SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name"
      )
      .map { row in
        SchemaObject(type: row["type"], name: row["name"], table: row["tbl_name"], sql: row["sql"])
      }
    }
  }
}
