import Foundation
import GRDB
import Testing
import WinSDK

@Suite("Windows database directory lifetime", .timeLimit(.minutes(1)))
struct DirectoryLifetimeTests {
  @Test("A native GRDB connection retains private ancestry through close and release")
  func connectionOwnsDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "database 汉字 \(UUID())")
    let moved = root.appendingPathExtension("moved")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: moved)
    }
    let state = root.appendingPathComponent("state")
    let reference = Reference()
    var database: DatabaseQueue? = try open(state: state, reference: reference)
    try database?.write { db in
      try db.execute(sql: "CREATE TABLE records (value INTEGER NOT NULL)")
      try db.execute(sql: "INSERT INTO records VALUES (?)", arguments: [Int64.max])
    }
    #expect(reference.directory != nil)
    #expect(!MoveFileW(Array(root.path.utf16) + [0], Array(moved.path.utf16) + [0]))
    try database?.close()
    #expect(reference.directory != nil)
    database = nil
    #expect(reference.directory == nil)
    try #require(MoveFileW(Array(root.path.utf16) + [0], Array(moved.path.utf16) + [0]))
    let reopened = try open(state: moved.appendingPathComponent("state"), reference: reference)
    let value = try reopened.read { db in try Int64.fetchOne(db, sql: "SELECT value FROM records") }
    #expect(value == Int64.max)
    try reopened.close()
  }

  private func open(state: URL, reference: Reference) throws -> DatabaseQueue {
    let directory = try WindowsPrivateDirectory(state)
    reference.directory = directory
    var configuration = Configuration()
    configuration.prepareDatabase { [directory] _ in try directory.validate() }
    return try DatabaseQueue(
      path: state.appendingPathComponent("records.sqlite").path, configuration: configuration)
  }

  private final class Reference {
    weak var directory: WindowsPrivateDirectory?
  }
}
