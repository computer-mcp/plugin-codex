import Foundation
import GRDB
import Testing
import WinSDK

@Suite("Windows database directory lifetime", .timeLimit(.minutes(1)))
struct DirectoryLifetimeTests {
  @Test("A native GRDB connection retains private ancestry through close and release")
  func connectionOwnsDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "database 汉字 \(UUID())")
    let moved = root.appendingPathExtension("moved")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: moved)
    }
    let state = root.appendingPathComponent("state")
    let reference = Reference()
    try useAndClose(state: state, root: root, moved: moved, reference: reference)
    // Dispatch retires GRDB's queue-specific context asynchronously. A cleared weak
    // reference alone does not observe completion of the native handle closes.
    let deadline = ContinuousClock.now + .seconds(3)
    while !isReleased(reference), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(reference.directory == nil)
    while !MoveFileW(Array(root.path.utf16) + [0], Array(moved.path.utf16) + [0]) {
      let code = GetLastError()
      try #require(code == DWORD(ERROR_SHARING_VIOLATION), "Directory rename failed: \(code)")
      try #require(ContinuousClock.now < deadline, "Native directory handles remain open")
      try await Task.sleep(for: .milliseconds(5))
    }
    let reopened = try open(state: moved.appendingPathComponent("state"), reference: reference)
    let value = try await reopened.read { db in
      try Int64.fetchOne(db, sql: "SELECT value FROM records")
    }
    #expect(value == Int64.max)
    try reopened.close()
  }

  private func isReleased(_ reference: Reference) -> Bool { reference.directory == nil }

  private func useAndClose(state: URL, root: URL, moved: URL, reference: Reference) throws {
    let database = try open(state: state, reference: reference)
    defer { withExtendedLifetime(database) {} }
    try database.write { db in
      try db.execute(sql: "CREATE TABLE records (value INTEGER NOT NULL)")
      try db.execute(sql: "INSERT INTO records VALUES (?)", arguments: [Int64.max])
    }
    #expect(reference.directory != nil)
    try #require(!MoveFileW(Array(root.path.utf16) + [0], Array(moved.path.utf16) + [0]))
    try database.close()
    #expect(reference.directory != nil)
    try #require(
      !MoveFileW(
        Array(state.path.utf16) + [0], Array(state.appendingPathExtension("moved").path.utf16) + [0]
      ))
    #expect(GetLastError() == DWORD(ERROR_SHARING_VIOLATION))
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
