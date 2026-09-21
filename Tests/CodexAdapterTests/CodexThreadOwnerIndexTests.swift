import Foundation
import Testing

@testable import CodexAdapter

struct CodexThreadOwnerIndexTests {
  @Test func explicitThreadIdentityIsIsolatedAcrossConnectionsAndSubjects() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("owners.sqlite").path
    let first = try CodexThreadOwnerIndex(path: path, subject: "subject-1", codexHome: root)
    let reconnect = try CodexThreadOwnerIndex(path: path, subject: "subject-1", codexHome: root)
    let other = try CodexThreadOwnerIndex(path: path, subject: "subject-2", codexHome: root)
    try first.check(threadID: "native-history")
    #expect(try !first.owns(threadID: "native-history"))
    try first.claim(threadID: "shared-thread")
    try reconnect.claim(threadID: "shared-thread")
    #expect(throws: CodexToolError.self) { try other.check(threadID: "shared-thread") }
    #expect(throws: CodexToolError.self) { try other.claim(threadID: "shared-thread") }
    let list: JSONValue = .object([
      "data": .array([
        .object(["id": .string("shared-thread")]), .object(["id": .string("native-history")]),
      ]),
      "nextCursor": .string("opaque"), "futureField": .bool(true),
    ])
    let filtered = try other.filtered(list, method: "thread/list")
    #expect(filtered.objectValue?["data"]?.arrayValue?.count == 1)
    #expect(filtered.objectValue?["futureField"] == .bool(true))
    #expect(filtered.objectValue?["nextCursor"] == .string("opaque"))
    let separateHome = try CodexThreadOwnerIndex(
      path: path, subject: "subject-2", codexHome: root.appendingPathComponent("other-home"))
    try separateHome.claim(threadID: "shared-thread")
  }

  @Test func foreignExplicitIDIsRejectedBeforeVendorLaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("owners.sqlite").path
    let owner = try CodexThreadOwnerIndex(path: path, subject: "owner", codexHome: root)
    let foreign = try CodexThreadOwnerIndex(path: path, subject: "foreign", codexHome: root)
    try owner.claim(threadID: "explicit-native-thread")
    let runtime = LiveCodexAppServerRuntime(
      configuration: .init(enabled: true, executable: "/missing/vendor"),
      workspaceURL: root, threadOwnerIndex: foreign)
    for method in [
      "thread/read", "thread/turns/list", "thread/items/list", "thread/resume", "turn/start",
    ] {
      await #expect(throws: CodexToolError.self) {
        try await runtime.call(
          method: method, params: .object(["threadId": .string("explicit-native-thread")]))
      }
    }
    #expect(await runtime.status().objectValue?["process_state"] == .string("absent"))
    await runtime.shutdown()
  }

  @Test func concurrentClaimsHaveOneWinner() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("owners.sqlite").path
    let first = try CodexThreadOwnerIndex(path: path, subject: "one", codexHome: root)
    let second = try CodexThreadOwnerIndex(path: path, subject: "two", codexHome: root)
    let successes = await withTaskGroup(of: Bool.self) { group in
      for index in [first, second] {
        group.addTask { (try? index.claim(threadID: "same-explicit-id")) != nil }
      }
      var count = 0
      for await won in group where won { count += 1 }
      return count
    }
    #expect(successes == 1)
    #expect(
      try first.owns(threadID: "same-explicit-id") != second.owns(threadID: "same-explicit-id"))
  }
}
