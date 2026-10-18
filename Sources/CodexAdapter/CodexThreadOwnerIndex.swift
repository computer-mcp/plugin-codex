import CryptoKit
import Foundation
import GRDB

/// Cross-subject affinity for native threads; all execution records remain in their subject database.
final class CodexThreadOwnerIndex: @unchecked Sendable {
  private let database: DatabaseQueue
  private let subject: String
  private let vendorHome: String

  init(path: String, subject: String, codexHome: URL) throws {
    self.subject = subject
    vendorHome = SHA256.hash(
      data: Data(codexHome.standardizedFileURL.resolvingSymlinksInPath().path.utf8)
    )
    .map { String(format: "%02x", $0) }.joined()
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    database = try DatabaseQueue(path: path, configuration: configuration)
    try database.write { db in
      try db.execute(
        sql: """
          CREATE TABLE IF NOT EXISTS threadOwners (
            vendorHome TEXT NOT NULL, threadID TEXT NOT NULL, subject TEXT NOT NULL,
            PRIMARY KEY (vendorHome, threadID)
          )
          """)
    }
  }

  func owns(threadID: String) throws -> Bool {
    try database.read { db in try owner(threadID: threadID, database: db) == subject }
  }

  func isVisible(threadID: String) throws -> Bool {
    try database.read { db in
      try owner(threadID: threadID, database: db).map { $0 == subject } ?? true
    }
  }

  func check(threadID: String) throws {
    guard try isVisible(threadID: threadID) else { throw Self.foreignThread() }
  }

  /// Claims before dispatch. An uncertain downstream result must not release affinity to another subject.
  func claim(threadID: String) throws {
    try database.write { db in
      if let current = try owner(threadID: threadID, database: db) {
        guard current == subject else { throw Self.foreignThread() }
        return
      }
      try db.execute(
        sql: "INSERT INTO threadOwners (vendorHome, threadID, subject) VALUES (?, ?, ?)",
        arguments: [vendorHome, threadID, subject])
    }
  }

  func filtered(_ response: JSONValue, method: String) throws -> JSONValue {
    guard ["thread/list", "thread/loaded/list"].contains(method),
      var object = response.objectValue, let rows = object["data"]?.arrayValue
    else { return response }
    object["data"] = .array(
      try rows.filter { row in
        guard let id = row.stringValue ?? row.objectValue?["id"]?.stringValue else { return true }
        return try isVisible(threadID: id)
      })
    return .object(object)
  }

  private func owner(threadID: String, database: Database) throws -> String? {
    try String.fetchOne(
      database, sql: "SELECT subject FROM threadOwners WHERE vendorHome = ? AND threadID = ?",
      arguments: [vendorHome, threadID])
  }

  private static func foreignThread() -> CodexToolError {
    .disabled("The Codex thread belongs to another authorization subject.")
  }
}
