import Foundation
import GRDB
import Testing

@Suite("Native SQLite Swift consumer")
struct GRDBTests {
  private enum Rollback: Error, Equatable { case requested }

  @Test
  func rollbackAndExactIntegersSurviveReopening() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("ownership.sqlite").path
    let database = try DatabaseQueue(path: path)
    defer { try? database.close() }
    var migrator = DatabaseMigrator()
    migrator.registerMigration("ownership") { db in
      try db.execute(
        sql: "CREATE TABLE owners (id INTEGER PRIMARY KEY, generation INTEGER NOT NULL)")
    }
    try migrator.migrate(database)
    try database.write { db in
      try db.execute(
        sql: "INSERT INTO owners VALUES (?, ?)", arguments: [Int64.max, Int64.min])
    }
    #expect(throws: Rollback.requested) {
      try database.write { db in
        try db.execute(sql: "UPDATE owners SET generation = 0")
        throw Rollback.requested
      }
    }
    try database.close()
    let reopened = try DatabaseQueue(path: path)
    defer { try? reopened.close() }
    try reopened.read { db in
      let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM owners")
      let id = try Int64.fetchOne(db, sql: "SELECT id FROM owners")
      let generation = try Int64.fetchOne(db, sql: "SELECT generation FROM owners")
      #expect(count == 1)
      #expect(id == Int64.max)
      #expect(generation == Int64.min)
    }
  }

  @Test
  func snapshotPoolRetainsItsViewAcrossACommittedWrite() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try DatabasePool(path: directory.appendingPathComponent("snapshots.sqlite").path)
    defer { try? database.close() }
    try database.write { db in
      try db.execute(sql: "CREATE VIRTUAL TABLE search USING fts5(body)")
      try db.execute(sql: "INSERT INTO search VALUES ('owned runtime')")
    }
    let snapshot = try database.makeSnapshotPool()
    defer { try? snapshot.close() }
    try database.write { db in
      try db.execute(sql: "INSERT INTO search VALUES ('replacement runtime')")
    }
    let query = "SELECT count(*) FROM search WHERE search MATCH 'runtime'"
    #expect(try snapshot.read { try Int.fetchOne($0, sql: query) } == 1)
    #expect(try database.read { try Int.fetchOne($0, sql: query) } == 2)
  }
}
