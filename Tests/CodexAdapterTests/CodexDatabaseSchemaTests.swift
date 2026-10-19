import Foundation
import GRDB
import Testing

@testable import CodexAdapter

struct CodexDatabaseSchemaTests {
  @Test func initialSchemaMatchesCapturedFinalSchema() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("codex.sqlite").path
    _ = try CodexDatabase(path: path)
    let queue = try DatabaseQueue(path: path)
    let fixture = try #require(
      Bundle.module.url(
        forResource: "codex-schema", withExtension: "json", subdirectory: "Fixtures"))
    let expected = try JSONDecoder().decode([SchemaObject].self, from: Data(contentsOf: fixture))
    #expect(try schema(queue) == expected)
    #expect(
      try queue.read { try CodexDatabase.migrator.appliedIdentifiers($0) } == ["codex-initial"])
    _ = try CodexDatabase(path: path)
    #expect(try schema(queue) == expected)
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
