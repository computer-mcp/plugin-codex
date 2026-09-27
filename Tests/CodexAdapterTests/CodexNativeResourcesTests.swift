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
