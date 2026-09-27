import Foundation
import MCP
import Testing

@testable import CodexAdapter

struct CodexWorkSnapshotTests {
  @Test func aliasesPreserveExactIdentifiersAndAdvanceSnapshotRevision() async throws {
    let source = WorkSource()
    let snapshot = CodexWorkSnapshot { try await source.collect() }
    let original = try resource("lifetime")
    await source.set([original])
    let initial = try await payload(snapshot.read())
    let handles: [String: JSONValue] = [
      "native_id": .integer(9_007_199_254_740_993), "thread_id": .string("opaque"),
    ]
    let enriched = try original.addingHandles(handles)
    #expect(enriched.id == original.id && enriched.acquiredBy == original.acquiredBy)
    #expect(enriched.json.objectValue?["handles"] == .object(handles))
    await source.set([enriched])
    let changed = try await payload(snapshot.read())
    #expect(initial["revision"] == .integer(0))
    #expect(changed["revision"] == .integer(1))
    #expect(changed["resources"] == .array([enriched.json]))
    #expect(try await payload(snapshot.read()) == changed)
    #expect(throws: MCPError.self) {
      try enriched.addingHandles(["native_id": .string("9007199254740993")])
    }
    await snapshot.shutdown()
  }

  @Test func invalidAliasesCannotPublishOwnedIdentifiers() throws {
    let invalid: [[String: JSONValue]] = [
      ["id": .string("shadow")], ["native": .null], ["native": .bool(true)],
      ["native": .number(1.5)], ["native": .string("")], ["native": .string("bad\nvalue")],
      ["bad\nname": .string("value")], ["native": .string(String(repeating: "x", count: 1025))],
      Dictionary(uniqueKeysWithValues: (0...16).map { ("alias\($0)", .string("value")) }),
    ]
    for handles in invalid {
      #expect(throws: MCPError.self) {
        try CodexWorkResource(kind: "work", id: "lifetime", acquiredBy: UUID(), handles: handles)
      }
    }
  }

  @Test func revisionsChangeOnlyForCompleteChangedObservations() async throws {
    let source = WorkSource()
    let snapshot = CodexWorkSnapshot { try await source.collect() }
    let initial = try await payload(snapshot.read())
    #expect(initial["revision"] == .integer(0))
    #expect(initial["resources"] == .array([]))
    let first = try resource("z")
    let second = try resource("a")
    await source.set([first, second])
    let active = try await payload(snapshot.read())
    #expect(active["instance_id"] == initial["instance_id"])
    #expect(active["revision"] == .integer(1))
    #expect(active["resources"] == .array([second.json, first.json]))
    await source.set([second, first])
    #expect(try await payload(snapshot.read()) == active)
    await source.set([first, first])
    await #expect(throws: MCPError.self) { try await snapshot.read() }
    await source.set([first, second])
    #expect(try await payload(snapshot.read()) == active)
    await source.set([], fail: true)
    await #expect(throws: MCPError.self) { try await snapshot.read() }
    await source.set([])
    #expect(try await payload(snapshot.read())["revision"] == .integer(2))
    await snapshot.shutdown()
    await #expect(throws: MCPError.self) { try await snapshot.read() }
  }

  @Test(arguments: [
    "", "bad\nidentity", "bad\u{7f}identity", "bad\u{9f}identity",
    String(repeating: "a", count: 1025), String(repeating: "界", count: 342),
  ])
  func invalidIdentifiersFailTheEntireObservation(_ invalid: String) async throws {
    for invalidKind in [false, true] {
      let row = try CodexWorkResource(
        kind: invalidKind ? invalid : "work", id: invalidKind ? "id" : invalid, acquiredBy: UUID())
      let snapshot = CodexWorkSnapshot { [row] }
      await #expect(throws: MCPError.self) { try await snapshot.read() }
      await snapshot.shutdown()
    }
  }

  @Test func rowAndByteBoundsNeverTruncateLiveWork() async throws {
    let source = WorkSource()
    let snapshot = CodexWorkSnapshot { try await source.collect() }
    let rows = try (0..<1024).map { try resource(String($0)) }
    await source.set(rows)
    #expect(try await payload(snapshot.read())["resources"]?.arrayValue?.count == 1024)
    await source.set(rows + [try resource("overflow")])
    await #expect(throws: MCPError.self) { try await snapshot.read() }
    let oversized = try (0..<600).map {
      try resource(String($0) + String(repeating: "x", count: 1000))
    }
    await source.set(oversized)
    await #expect(throws: MCPError.self) { try await snapshot.read() }
    await source.set(rows)
    #expect(try await payload(snapshot.read())["revision"] == .integer(0))
    await snapshot.shutdown()
  }

  @Test(.timeLimit(.minutes(1)))
  func overlappingReadsCannotReuseAnObservationFromBeforeTheirAdmission() async throws {
    let gate = WorkReadGate()
    let snapshot = CodexWorkSnapshot { await gate.collect() }
    let first = Task { try await snapshot.read() }
    await gate.waitForRead()
    await #expect(throws: MCPError.self) { try await snapshot.read() }
    first.cancel()
    // Caller cancellation cannot detach the still-running provider observation.
    await #expect(throws: MCPError.self) { try await snapshot.read() }
    let stopped = Task { await snapshot.shutdown() }
    await gate.release()
    _ = await first.result
    await stopped.value
    await #expect(throws: MCPError.self) { try await snapshot.read() }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func standardMCPDiscoveryAndReadExposeCompleteWorkOrAnExplicitFailure(
    unavailableProvider: Bool
  ) async throws {
    let provider: CodexAppServerProvider? =
      unavailableProvider
      ? .init(
        appServer: FakeAppServerRuntime(), owner: nil, database: nil,
        workspaceURL: FileManager.default.temporaryDirectory, recentThreadReader: nil,
        localControlAllowed: false) : nil
    let pair = await InMemoryTransport.createConnectedPair()
    try await pair.server.connect()
    let serving = Task {
      try await CodexAdapterServer.serve(transport: pair.server, appServer: provider)
    }
    let client = MCP.Client(name: "work-snapshot-tests", version: "1")
    do {
      let initialized = try await client.connect(transport: pair.client)
      #expect(initialized.capabilities.resources?.subscribe == false)
      #expect(initialized.capabilities.resources?.listChanged == false)
      let catalog = try await client.listTools()
      for tool in catalog.tools {
        #expect(
          tool._meta?[CodexWorkSnapshot.metadataKey]
            == .object([
              "format_version": .int(1), "uri": .string(CodexWorkSnapshot.uri),
            ]))
      }
      let listed = try await client.listResources()
      #expect(listed.resources.map(\.uri) == [CodexWorkSnapshot.uri])
      await #expect(throws: MCPError.self) { try await client.listResources(cursor: "unknown") }
      await #expect(throws: MCPError.self) { try await client.readResource(uri: "unknown") }
      if unavailableProvider {
        await #expect(throws: MCPError.self) {
          try await client.readResource(uri: CodexWorkSnapshot.uri)
        }
      } else {
        let contents = try await client.readResource(uri: CodexWorkSnapshot.uri)
        let value = try payload(.init(contents: contents))
        #expect(value["format_version"] == .integer(1))
        #expect(value["resources"] == .array([]))
        let instance = try #require(value["instance_id"]?.stringValue)
        #expect(UUID(uuidString: instance)?.uuidString.lowercased() == instance)
      }
      await client.disconnect()
      try await serving.value
    } catch {
      await client.disconnect()
      await pair.server.disconnect()
      _ = try? await serving.value
      throw error
    }
  }

  private func resource(_ id: String) throws -> CodexWorkResource {
    try .init(kind: "work", id: id, acquiredBy: UUID())
  }

  private func payload(_ result: MCP.ReadResource.Result) throws -> [String: JSONValue] {
    #expect(result.contents.count == 1)
    let content = try #require(result.contents.first)
    #expect(content.uri == CodexWorkSnapshot.uri)
    #expect(content.mimeType == "application/json")
    let text = try #require(content.text)
    return try #require(JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).objectValue)
  }
}

private actor WorkSource {
  private var rows: [CodexWorkResource] = []
  private var fail = false
  func set(_ rows: [CodexWorkResource], fail: Bool = false) {
    self.rows = rows
    self.fail = fail
  }
  func collect() throws -> [CodexWorkResource] {
    if fail { throw MCPError.internalError("Native work is unavailable.") }
    return rows
  }
}

private actor WorkReadGate {
  private var pending: CheckedContinuation<[CodexWorkResource], Never>?
  private var started: CheckedContinuation<Void, Never>?
  func collect() async -> [CodexWorkResource] {
    await withCheckedContinuation {
      pending = $0
      started?.resume()
      started = nil
    }
  }
  func waitForRead() async {
    if pending != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func release() {
    pending?.resume(returning: [])
    pending = nil
  }
}
