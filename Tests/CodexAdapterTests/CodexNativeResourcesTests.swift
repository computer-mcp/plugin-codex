import Foundation
import Testing

@testable import CodexAdapter

struct CodexNativeResourcesTests {
  @Test func interactiveHandlesRequireTheirOwningConnection() throws {
    var resources = CodexNativeResources()
    let params = JSONValue.object(["processId": .string("command-1")])
    #expect(throws: CodexToolError.self) {
      try resources.prepare(method: "command/exec/write", params: params, generation: 1)
    }
    let command = try resources.prepare(method: "command/exec", params: params, generation: 1)
    _ = try resources.prepare(method: "command/exec/write", params: params, generation: 1)
    #expect(throws: CodexToolError.self) {
      try resources.prepare(method: "command/exec", params: params, generation: 1)
    }
    #expect(throws: CodexToolError.self) {
      try resources.prepare(method: "command/exec/terminate", params: params, generation: 2)
    }
    #expect(resources.count == 1)
    resources.completed(command)
    #expect(resources.count == 0)
  }

  @Test func failedStopPreservesOwnershipAndLateCompletionCannotDeleteReplacement() throws {
    var resources = CodexNativeResources()
    let params = JSONValue.object(["watchId": .string("watch-1")])
    let first = try resources.prepare(method: "fs/watch", params: params, generation: 1)
    resources.completed(first)
    #expect(resources.count == 1)
    let stop = try resources.prepare(method: "fs/unwatch", params: params, generation: 1)
    resources.completed(stop, rejected: true)
    #expect(resources.count == 1)
    resources.completed(stop)
    let replacement = try resources.prepare(method: "fs/watch", params: params, generation: 1)
    resources.completed(stop)
    resources.completed(first, rejected: true)
    #expect(resources.count == 1)
    resources.completed(replacement, rejected: true)
    #expect(resources.count == 0)
  }

  @Test func exitNotificationIsGenerationBoundAndKillDoesNotClaimCleanup() throws {
    var resources = CodexNativeResources()
    let params = JSONValue.object(["processHandle": .string("process-1")])
    let start = try resources.prepare(method: "process/spawn", params: params, generation: 2)
    resources.completed(start)
    resources.completed(
      try resources.prepare(method: "process/kill", params: params, generation: 2))
    #expect(resources.count == 1)
    resources.processExited(handle: "process-1", generation: 1)
    #expect(resources.count == 1)
    resources.processExited(handle: "process-1", generation: 2)
    #expect(resources.count == 0)
  }

  @Test(arguments: [
    ("command/exec", "command/exec/terminate", "processId", "command"),
    ("process/spawn", "process/kill", "processHandle", "process"),
    ("fs/watch", "fs/unwatch", "watchId", "watch"),
    ("mcpServer/event/stream/start", "mcpServer/event/stream/stop", "subscriptionId", "stream"),
  ])
  func workOriginSurvivesContinuationAndUncertainStop(
    start: String, stop: String, field: String, kind: String
  ) throws {
    var resources = CodexNativeResources()
    let origin = UUID()
    let params = JSONValue.object([field: .string("native-handle")])
    let created = try #require(
      try CodexWorkInvocation.$current.withValue(origin) {
        try resources.prepare(method: start, params: params, generation: 2)
      })
    let owner = try CodexWorkResource(
      kind: "codex.app." + kind, id: created.token.uuidString.lowercased(), acquiredBy: origin,
      handles: ["native_id": .string("native-handle")])
    #expect(try resources.workResources() == [owner])
    let stopping = try CodexWorkInvocation.$current.withValue(UUID()) {
      try resources.prepare(method: stop, params: params, generation: 2)
    }
    resources.uncertain(stopping)
    let unknown = try CodexWorkResource(
      kind: owner.kind, id: owner.id, acquiredBy: origin, state: .uncertain, handles: owner.handles)
    #expect(try resources.workResources() == [unknown])
    resources.completed(stopping, rejected: true)
    #expect(try resources.workResources() == [unknown])
    resources.retired(generation: 1)
    #expect(try resources.workResources() == [unknown])
    resources.retired(generation: 2)
    #expect(try resources.workResources().isEmpty)
  }

  @Test
  func reusedNativeHandleGetsANewOwnerAndRejectsLateMutations() throws {
    var resources = CodexNativeResources()
    let params = JSONValue.object(["watchId": .string("reused")])
    let first = try CodexWorkInvocation.$current.withValue(UUID()) {
      try resources.prepare(method: "fs/watch", params: params, generation: 1)
    }
    let firstOwner = try #require(resources.workResources().first)
    let stopping = try resources.prepare(method: "fs/unwatch", params: params, generation: 1)
    resources.completed(stopping)
    let origin = UUID()
    let second = try CodexWorkInvocation.$current.withValue(origin) {
      try resources.prepare(method: "fs/watch", params: params, generation: 1)
    }
    let secondOwner = try #require(resources.workResources().first)
    #expect(secondOwner.acquiredBy == origin)
    #expect(secondOwner.id != firstOwner.id)
    #expect(firstOwner.handles == ["native_id": .string("reused")])
    #expect(secondOwner.handles == firstOwner.handles)
    resources.uncertain(first)
    resources.uncertain(stopping)
    resources.completed(first, rejected: true)
    resources.completed(stopping)
    #expect(try resources.workResources() == [secondOwner])
    resources.uncertain(second)
    #expect(try resources.workResources().first?.state == .uncertain)
    resources.completed(second, rejected: true)
    #expect(try resources.workResources().isEmpty)
  }

  @Test
  func onlyNativeCompletionOrOwningGenerationCleanupReleasesWork() throws {
    var resources = CodexNativeResources()
    let origin = UUID()
    let process = JSONValue.object(["processHandle": .string("owned")])
    let ticket = try CodexWorkInvocation.$current.withValue(origin) {
      try resources.prepare(method: "process/spawn", params: process, generation: 1)
    }
    resources.uncertain(ticket)
    resources.completed(
      try resources.prepare(method: "process/kill", params: process, generation: 1))
    #expect(try resources.workResources().first?.state == .uncertain)
    resources.processExited(handle: "owned", generation: 2)
    #expect(try resources.workResources().count == 1)
    resources.processExited(handle: "owned", generation: 1)
    #expect(try resources.workResources().isEmpty)
    let command = try CodexWorkInvocation.$current.withValue(origin) {
      try resources.prepare(
        method: "command/exec", params: .object(["processId": .string("owned")]), generation: 2)
    }
    resources.uncertain(command)
    resources.completed(command)
    #expect(try resources.workResources().isEmpty)
  }

  @Test
  func unboundLiveHandlesMakeObservationUnavailable() throws {
    var resources = CodexNativeResources()
    #expect(try resources.workResources().isEmpty)
    let ticket = try resources.prepare(
      method: "fs/watch", params: .object(["watchId": .string("standalone")]), generation: 1)
    #expect(throws: (any Error).self) { try resources.workResources() }
    resources.completed(ticket, rejected: true)
    #expect(try resources.workResources().isEmpty)
  }

  @Test func outstandingOwnershipIsBoundedAndUncertainStartsRemainReserved() throws {
    var resources = CodexNativeResources()
    for index in 0..<256 {
      _ = try resources.prepare(
        method: "fs/watch", params: .object(["watchId": .string("\(index)")]), generation: 1)
    }
    #expect(throws: CodexToolError.self) {
      try resources.prepare(
        method: "fs/watch", params: .object(["watchId": .string("next")]), generation: 1)
    }
    resources.retired(generation: 2)
    #expect(resources.count == 256)
    resources.retired(generation: 1)
    #expect(resources.count == 0)
  }
}
