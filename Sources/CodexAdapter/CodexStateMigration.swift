import CryptoKit
import Foundation
import GRDB

/// Transfers only adapter-owned domain records. This is an explicit offline
/// administration operation, not an MCP tool or a host-authority channel.
enum CodexStateMigration {
  static let tables = [
    "codexApprovals", "codexRuntimeLeases", "codexThreadOwnership",
    "codexOwnershipReconciliationReceipts", "codexOrchestrationRuns",
    "codexWorktreeLeases", "codexManagedWorktrees",
  ]
  static let maximumRows = 100_000
  static let maximumPayloadBytes = 64 * 1_024 * 1_024

  struct TableReport: Codable, Equatable, Sendable {
    let name: String
    let sourceRows: Int
    let insertRows: Int
    let identicalRows: Int
    let conflictingRows: Int
  }

  struct Plan: Codable, Equatable, Sendable {
    let sourcePath: String
    let destinationPath: String
    let sourceDigest: String
    let destinationDigest: String
    let destinationIdentity: String?
    let tables: [TableReport]
    let destinationExists: Bool
    var canApply: Bool { tables.allSatisfy { $0.conflictingRows == 0 } }
    var insertRows: Int { tables.reduce(0) { $0 + $1.insertRows } }
    var planDigest: String { get throws { try digest(self) } }
  }

  struct Result: Encodable, Sendable {
    let plan: Plan
    let planDigest: String
    let applied: Bool
    let insertedRows: Int
    let canApply: Bool

    init(plan: Plan, planDigest: String, applied: Bool, insertedRows: Int) {
      self.plan = plan
      self.planDigest = planDigest
      self.applied = applied
      self.insertedRows = insertedRows
      self.canApply = plan.canApply
    }
  }

  enum Failure: Error, LocalizedError {
    case invalid(String)
    case changed
    case conflict

    var errorDescription: String? {
      switch self {
      case .invalid(let detail): return "codex.state_migration.invalid: \(detail)"
      case .changed:
        return
          "codex.state_migration.changed: Snapshot or destination changed. Review a new preview."
      case .conflict:
        return
          "codex.state_migration.conflict: Existing records differ. No records were overwritten."
      }
    }
  }

  static func preview(source: URL, destination: URL) throws -> Plan {
    let inputs = try Inputs(source: source, destination: destination)
    let reference = try referenceSchema()
    let snapshot = try readSource(inputs.source, reference: reference)
    let target: Snapshot
    if inputs.destinationIdentity != nil {
      let reader = try open(inputs.destination, readOnly: true)
      defer { try? reader.close() }
      target = try reader.read { try readSnapshot($0, reference: reference, isDestination: true) }
    } else {
      target = Snapshot(tables: reference.map { Table(schema: $0, rows: []) })
    }
    try inputs.verify()
    return try makePlan(inputs: inputs, source: snapshot, destination: target)
  }

  static func apply(source: URL, destination: URL, expectedPlanDigest: String) throws -> Result {
    guard expectedPlanDigest.utf8.count == 64,
      expectedPlanDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw Failure.invalid("A reviewed SHA-256 plan digest is required.") }
    let inputs = try Inputs(source: source, destination: destination)
    let reference = try referenceSchema()
    let snapshot = try readSource(inputs.source, reference: reference)
    if inputs.destinationIdentity != nil {
      let writer = try open(inputs.destination, readOnly: false)
      defer { try? writer.close() }
      // GRDB's write transaction locks the destination before rechecking its
      // rows, so another database writer cannot slip between review and import.
      return try writer.write { db in
        let target = try readSnapshot(db, reference: reference, isDestination: true)
        let plan = try makePlan(inputs: inputs, source: snapshot, destination: target)
        try requireReviewed(plan, expected: expectedPlanDigest)
        try inputs.verify(checkDestinationSidecars: false)
        try insert(snapshot, excluding: target, into: db)
        try verifySource(snapshot, at: inputs.source)
        try inputs.verify(checkDestinationSidecars: false)
        return Result(
          plan: plan, planDigest: expectedPlanDigest, applied: true, insertedRows: plan.insertRows)
      }
    }

    let empty = Snapshot(tables: reference.map { Table(schema: $0, rows: []) })
    let plan = try makePlan(inputs: inputs, source: snapshot, destination: empty)
    try requireReviewed(plan, expected: expectedPlanDigest)
    // A fresh target is published only after its complete transaction closes.
    // link() is no-replace, unlike rename(), so a concurrent creator wins safely.
    let staging = inputs.destination.deletingLastPathComponent()
      .appendingPathComponent(".codex-state-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: staging) }
    let stagedFile = staging.appendingPathComponent("codex.sqlite")
    guard
      FileManager.default.createFile(
        atPath: stagedFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw Failure.invalid("Could not create private staging database.") }
    let writer = try open(stagedFile, readOnly: false)
    defer { try? writer.close() }
    try CodexDatabase.migrator.migrate(writer)
    try writer.write { db in try insert(snapshot, excluding: empty, into: db) }
    try writer.close()
    try verifySource(snapshot, at: inputs.source)
    try inputs.verify()
    try FileManager.default.linkItem(at: stagedFile, to: inputs.destination)
    return Result(
      plan: plan, planDigest: expectedPlanDigest, applied: true, insertedRows: plan.insertRows)
  }

  private static func requireReviewed(_ plan: Plan, expected: String) throws {
    guard try plan.planDigest == expected else { throw Failure.changed }
    guard plan.canApply else { throw Failure.conflict }
  }

  private struct Schema: Codable, Equatable {
    let name: String
    let columns: [Column]
    var keyIndex: Int { columns.firstIndex { $0.primaryKey > 0 }! }
  }

  private struct Column: Codable, Equatable {
    let name: String
    let type: String
    let notNull: Bool
    let primaryKey: Int
    let hidden: Int
  }

  private struct Table: Codable {
    let schema: Schema
    var rows: [[Cell]]
  }

  private struct Snapshot: Codable {
    let tables: [Table]
    var fileDigest: String? = nil
  }

  /// Store SQL values without re-encoding payload JSON or coercing identifiers,
  /// dates, integer precision, NULL and empty strings into another representation.
  private enum Cell: Codable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    init(_ value: DatabaseValue) throws {
      switch value.storage {
      case .null: self = .null
      case .int64(let value): self = .integer(value)
      case .double(let value):
        guard value.isFinite else { throw Failure.invalid("A stored real value is not finite.") }
        self = .real(value)
      case .string(let value): self = .text(value)
      case .blob(let value): self = .blob(value)
      }
    }

    var databaseValue: DatabaseValue {
      switch self {
      case .null: return .null
      case .integer(let value): return value.databaseValue
      case .real(let value): return value.databaseValue
      case .text(let value): return value.databaseValue
      case .blob(let value): return value.databaseValue
      }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      switch (lhs, rhs) {
      case (.null, .null): return true
      case (.integer(let lhs), .integer(let rhs)): return lhs == rhs
      case (.real(let lhs), .real(let rhs)): return lhs.bitPattern == rhs.bitPattern
      case (.text(let lhs), .text(let rhs)): return lhs.utf8.elementsEqual(rhs.utf8)
      case (.blob(let lhs), .blob(let rhs)): return lhs == rhs
      default: return false
      }
    }

    var key: Data? {
      guard case .text(let value) = self, !value.isEmpty else { return nil }
      return Data(value.utf8)
    }
  }

  private struct Inputs {
    let source: URL
    let destination: URL
    let sourceIdentity: String
    let destinationIdentity: String?

    init(source: URL, destination: URL) throws {
      guard source.isFileURL, destination.isFileURL else {
        throw Failure.invalid("Database locations must be local files.")
      }
      self.source =
        source.deletingLastPathComponent().resolvingSymlinksInPath()
        .appendingPathComponent(source.lastPathComponent).standardizedFileURL
      self.destination =
        destination.deletingLastPathComponent().resolvingSymlinksInPath()
        .appendingPathComponent(destination.lastPathComponent).standardizedFileURL
      sourceIdentity = try identity(self.source, required: true)!
      destinationIdentity = try identity(self.destination, required: false)
      guard sourceIdentity != destinationIdentity else {
        throw Failure.invalid("Source and destination identify the same file.")
      }
      try Self.requireOffline(self.source)
      try Self.requireOffline(self.destination)
    }

    func verify(checkDestinationSidecars: Bool = true) throws {
      guard try identity(source, required: true) == sourceIdentity,
        try identity(destination, required: false) == destinationIdentity
      else { throw Failure.changed }
      try Self.requireOffline(source)
      if checkDestinationSidecars { try Self.requireOffline(destination) }
    }

    static func requireOffline(_ file: URL) throws {
      for suffix in ["-wal", "-shm", "-journal"] {
        let sidecar = URL(fileURLWithPath: file.path + suffix)
        if try identity(sidecar, required: false) != nil {
          throw Failure.invalid("Use an offline, checkpointed snapshot without SQLite sidecars.")
        }
      }
    }
  }

  private static func identity(_ url: URL, required: Bool) throws -> String? {
    let attributes: [FileAttributeKey: Any]
    do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) } catch CocoaError
      .fileReadNoSuchFile
    {
      if required { throw Failure.invalid("The source snapshot does not exist.") }
      return nil
    }
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let device = attributes[.systemNumber] as? NSNumber,
      let inode = attributes[.systemFileNumber] as? NSNumber
    else { throw Failure.invalid("Database locations must be regular files, not symbolic links.") }
    return "\(device):\(inode)"
  }

  private static func open(_ url: URL, readOnly: Bool) throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.readonly = readOnly
    configuration.busyMode = .timeout(1)
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA trusted_schema = OFF")
    }
    return try DatabaseQueue(path: url.path, configuration: configuration)
  }

  private static func referenceSchema() throws -> [Schema] {
    let reference = try DatabaseQueue()
    defer { try? reference.close() }
    try CodexDatabase.migrator.migrate(reference)
    return try reference.read { db in try tables.map { try schema($0, in: db) } }
  }

  private static func schema(_ name: String, in db: Database) throws -> Schema {
    let kind = try String.fetchOne(
      db, sql: "SELECT type FROM sqlite_schema WHERE name = ?", arguments: [name])
    guard kind == "table" else { throw Failure.invalid("Missing domain table: \(name).") }
    let columns = try Row.fetchAll(db, sql: "PRAGMA table_xinfo(\(quote(name)))").map { row in
      Column(
        name: row["name"], type: row["type"], notNull: row["notnull"],
        primaryKey: row["pk"], hidden: row["hidden"])
    }
    return Schema(name: name, columns: columns)
  }

  private static func readSource(_ url: URL, reference: [Schema]) throws -> Snapshot {
    let before = try fileDigest(url)
    let reader = try open(url, readOnly: true)
    defer { try? reader.close() }
    var snapshot = try reader.read {
      try readSnapshot($0, reference: reference, isDestination: false)
    }
    snapshot.fileDigest = before
    try verifySource(snapshot, at: url)
    return snapshot
  }

  private static func verifySource(_ snapshot: Snapshot, at url: URL) throws {
    try Inputs.requireOffline(url)
    guard try fileDigest(url) == snapshot.fileDigest else { throw Failure.changed }
  }

  private static func readSnapshot(
    _ db: Database, reference: [Schema], isDestination: Bool
  ) throws -> Snapshot {
    if isDestination {
      let names = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_schema WHERE type = 'table'")
      let allowed = Set(tables + ["grdb_migrations"])
      guard Set(names).isSubset(of: allowed),
        try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_schema WHERE type = 'trigger'") == 0
      else {
        throw Failure.invalid("The destination must be an adapter-only database without triggers.")
      }
      guard
        try CodexDatabase.migrator.appliedIdentifiers(db) == Set(CodexDatabase.migrator.migrations)
      else {
        throw Failure.invalid("The destination schema migration history is incompatible.")
      }
    }
    var result: [Table] = []
    var count = 0
    var bytes = 0
    for expected in reference {
      if !isDestination, try !db.tableExists(expected.name) {
        result.append(Table(schema: expected, rows: []))
        continue
      }
      guard try schema(expected.name, in: db) == expected else {
        throw Failure.invalid("Unsupported columns in domain table: \(expected.name).")
      }
      let rowCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(quote(expected.name))") ?? 0
      guard rowCount <= maximumRows - count else {
        throw Failure.invalid("Domain records exceed the row bound.")
      }
      let byteExpression = expected.columns.map {
        "coalesce(length(CAST(\(quote($0.name)) AS BLOB)), 0)"
      }.joined(separator: " + ")
      let storedBytes =
        try Int64.fetchOne(
          db, sql: "SELECT coalesce(sum(\(byteExpression)), 0) FROM \(quote(expected.name))") ?? 0
      guard storedBytes <= maximumPayloadBytes - bytes else {
        throw Failure.invalid("Domain records exceed 64 MiB.")
      }
      // Compare raw TEXT bytes with the decoded Swift string before binding it
      // back to SQLite; malformed UTF-8 must not silently become replacement characters.
      let rawText = expected.columns.enumerated().map { index, column in
        "CASE WHEN typeof(\(quote(column.name))) = 'text' THEN CAST(\(quote(column.name)) AS BLOB) END AS __migration_text_\(index)"
      }
      let columns = (expected.columns.map { quote($0.name) } + rawText).joined(separator: ", ")
      let cursor = try Row.fetchCursor(
        db,
        sql:
          "SELECT \(columns) FROM \(quote(expected.name)) ORDER BY \(quote(expected.columns[expected.keyIndex].name))"
      )
      var rows: [[Cell]] = []
      var keys = Set<Data>()
      while let row = try cursor.next() {
        count += 1
        guard count <= maximumRows else {
          throw Failure.invalid("Domain records exceed the row bound.")
        }
        let cells = try expected.columns.enumerated().map { index, column in
          let raw: Data? = row["__migration_text_\(index)"]
          if let raw {
            guard let text = String(data: raw, encoding: .utf8) else {
              throw Failure.invalid("A domain record contains invalid UTF-8.")
            }
            return Cell.text(text)
          }
          return try Cell(row[column.name] as DatabaseValue)
        }
        guard let key = cells[expected.keyIndex].key, keys.insert(key).inserted else {
          throw Failure.invalid("Invalid or duplicate domain record identity.")
        }
        bytes += try JSONEncoder().encode(cells).count
        guard bytes <= maximumPayloadBytes else {
          throw Failure.invalid("Domain records exceed 64 MiB.")
        }
        do { try CodexDatabase.validateMigrationRow(row, table: expected.name) } catch {
          throw Failure.invalid("Invalid stored record in \(expected.name).")
        }
        rows.append(cells)
      }
      result.append(Table(schema: expected, rows: rows))
    }
    // A random SQLite file is not a source, even if it happens to be empty.
    if !isDestination {
      let names = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_schema WHERE type = 'table'")
      guard !Set(names).intersection(tables).isEmpty else {
        throw Failure.invalid("The source contains no recognized Codex domain tables.")
      }
    }
    return Snapshot(tables: result)
  }

  private static func makePlan(inputs: Inputs, source: Snapshot, destination: Snapshot) throws
    -> Plan
  {
    let reports = zip(source.tables, destination.tables).map { source, target in
      let existing = Dictionary(
        uniqueKeysWithValues: target.rows.map { ($0[target.schema.keyIndex].key!, $0) })
      var inserts = 0
      var same = 0
      var conflicts = 0
      for row in source.rows {
        if let old = existing[row[source.schema.keyIndex].key!] {
          if old == row { same += 1 } else { conflicts += 1 }
        } else {
          inserts += 1
        }
      }
      return TableReport(
        name: source.schema.name, sourceRows: source.rows.count, insertRows: inserts,
        identicalRows: same, conflictingRows: conflicts)
    }
    return Plan(
      sourcePath: inputs.source.path, destinationPath: inputs.destination.path,
      sourceDigest: source.fileDigest!, destinationDigest: try digest(destination),
      destinationIdentity: inputs.destinationIdentity, tables: reports,
      destinationExists: inputs.destinationIdentity != nil)
  }

  private static func insert(_ source: Snapshot, excluding target: Snapshot, into db: Database)
    throws
  {
    for (table, previous) in zip(source.tables, target.tables) {
      let existing = Set(previous.rows.map { $0[previous.schema.keyIndex].key! })
      let columns = table.schema.columns.map { quote($0.name) }.joined(separator: ", ")
      let markers = Array(repeating: "?", count: table.schema.columns.count).joined(separator: ", ")
      for row in table.rows where !existing.contains(row[table.schema.keyIndex].key!) {
        try db.execute(
          sql: "INSERT INTO \(quote(table.schema.name)) (\(columns)) VALUES (\(markers))",
          arguments: StatementArguments(row.map(\.databaseValue)))
      }
    }
  }

  private static func quote(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  private static func digest(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
  }

  private static func fileDigest(_ url: URL) throws -> String {
    _ = try identity(url, required: true)
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    var count = 0
    while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
      count += chunk.count
      guard count <= 256 * 1_024 * 1_024 else {
        throw Failure.invalid("Source snapshot exceeds 256 MiB.")
      }
      hash.update(data: chunk)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

extension CodexAdapterServer {
  package static func migrateState(
    source: URL, destination: URL, expectedPlanDigest: String? = nil
  ) throws -> Data {
    do {
      let result: CodexStateMigration.Result
      if let expectedPlanDigest {
        result = try CodexStateMigration.apply(
          source: source, destination: destination, expectedPlanDigest: expectedPlanDigest)
      } else {
        let plan = try CodexStateMigration.preview(source: source, destination: destination)
        result = CodexStateMigration.Result(
          plan: plan, planDigest: try plan.planDigest, applied: false, insertedRows: 0)
      }
      return try CanonicalJSONCoding.encoder(outputFormatting: [.prettyPrinted, .sortedKeys])
        .encode(result)
    } catch let error as CodexStateMigration.Failure {
      throw error
    } catch {
      throw CodexStateMigration.Failure.invalid(
        "Database or filesystem validation failed; no record values are included in this diagnostic."
      )
    }
  }
}
