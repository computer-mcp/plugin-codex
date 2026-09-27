import Darwin
import Foundation
import Testing

@testable import CodexAdapter

@Suite(.serialized)
struct CodexAppWorkOwnershipTests {
  @Test
  func threadAndTurnKeepDifferentCreatorsAndReleasedThreadGetsANewLifetime() async throws {
    try await withRuntime { _, runtime in
      let threadCreator = UUID()
      let turnCreator = UUID()
      _ = try await invoke(runtime, "thread/start", creator: threadCreator)
      let first = try #require(try await runtime.workResources().first)
      #expect(first.kind == "codex.app.thread")
      #expect(first.acquiredBy == threadCreator)
      _ = try await invoke(runtime, "turn/start", params: turnParams(), creator: turnCreator)
      let rows = try await runtime.workResources()
      #expect(rows.count == 2)
      #expect(rows.first { $0.kind == "codex.app.turn" }?.acquiredBy == turnCreator)
      #expect(rows.first { $0.kind == "codex.app.thread" } == first)
      _ = try await invoke(runtime, "thread/unsubscribe", params: threadParams())
      #expect(try await runtime.workResources().isEmpty)
      let replacementCreator = UUID()
      _ = try await invoke(runtime, "thread/start", creator: replacementCreator)
      let replacement = try #require(try await runtime.workResources().first)
      #expect(replacement.id != first.id)
      #expect(replacement.acquiredBy == replacementCreator)
    }
  }

  @Test
  func pendingInputBeforeTurnReplyBindsToTheTurnAndSurvivesInvalidResponse() async throws {
    try await withRuntime { fixture, runtime in
      let threadCreator = UUID()
      let turnCreator = UUID()
      _ = try await invoke(runtime, "thread/start", creator: threadCreator)
      let gate = fixture.directory.appendingPathComponent("hold-notification-response")
      try Data().write(to: gate)
      try inject(
        fixture,
        [
          turnNotification("turn/started", id: "turn_native"),
          inputRequest(turnID: "turn_native"),
        ])
      let turning = Task {
        try await invoke(runtime, "turn/start", params: turnParams(), creator: turnCreator)
      }
      defer { turning.cancel() }
      try await until {
        await runtime.pendingRequests().objectValue?["requests"]?.arrayValue?.count == 1
      }
      await #expect(throws: (any Error).self) { try await runtime.workResources() }
      try FileManager.default.removeItem(at: gate)
      _ = try await turning.value
      let rows = try await runtime.workResources()
      #expect(rows.count == 3)
      #expect(rows.first { $0.kind == "codex.app.thread" }?.acquiredBy == threadCreator)
      #expect(
        rows.filter { $0.kind != "codex.app.thread" }.allSatisfy { $0.acquiredBy == turnCreator })
      let input = try #require(
        await runtime.pendingRequests().objectValue?["requests"]?.arrayValue?.first)
      let id = try #require(input.objectValue?["request_id"]?.stringValue)
      await #expect(throws: (any Error).self) {
        try await runtime.respond(requestID: id, response: .object(["answers": .string("invalid")]))
      }
      #expect(try await runtime.workResources() == rows)
      _ = try await CodexWorkInvocation.$current.withValue(UUID()) {
        try await runtime.respond(requestID: id, response: .object(["answers": .object([:])]))
      }
      #expect(
        try await runtime.workResources().filter { $0.kind == "codex.app.server-request" }.isEmpty)
      #expect(
        try await runtime.workResources().first { $0.kind == "codex.app.turn" }?.acquiredBy
          == turnCreator)
    }
  }

  @Test(arguments: [false, true])
  func completionNotificationsRespectTheExactTurn(completeNewTurn: Bool) async throws {
    try await withRuntime { fixture, runtime in
      _ = try await invoke(runtime, "thread/start")
      try Data("old-turn".utf8).write(
        to: fixture.directory.appendingPathComponent("created-turn-id"))
      _ = try await invoke(runtime, "turn/start", params: turnParams())
      try Data("new-turn".utf8).write(
        to: fixture.directory.appendingPathComponent("created-turn-id"))
      let gate = fixture.directory.appendingPathComponent("hold-notification-response")
      try Data().write(to: gate)
      let completionID = completeNewTurn ? "new-turn" : "old-turn"
      try inject(fixture, [turnNotification("turn/completed", id: completionID)])
      let creator = UUID()
      let turning = Task {
        try await invoke(runtime, "turn/start", params: turnParams(), creator: creator)
      }
      defer { turning.cancel() }
      try await until {
        let events = await runtime.events(afterCursor: 0, maxResults: 100)
        return events.objectValue?["events"]?.arrayValue?.contains {
          $0.objectValue?["payload"]?.objectValue?["method"] == .string("turn/completed")
        } == true
      }
      try FileManager.default.removeItem(at: gate)
      _ = try await turning.value
      let turns = try await runtime.workResources().filter { $0.kind == "codex.app.turn" }
      #expect(turns.count == (completeNewTurn ? 0 : 1))
      if !completeNewTurn { #expect(turns.first?.acquiredBy == creator) }
    }
  }

  @Test
  func activeGoalOwnsDerivedTurnsButReadingStoredGoalsDoesNotAcquireWork() async throws {
    try await withRuntime { fixture, runtime in
      try Data("thread_fixture".utf8).write(
        to: fixture.directory.appendingPathComponent("created-thread-id"))
      let threadCreator = UUID()
      let goalCreator = UUID()
      _ = try await invoke(runtime, "thread/start", creator: threadCreator)
      let thread = threadParams("thread_fixture")
      _ = try await invoke(runtime, "thread/goal/get", params: thread)
      #expect(try await runtime.workResources().count == 1)
      _ = try await invoke(runtime, "thread/goal/set", params: thread, creator: goalCreator)
      #expect(
        try await runtime.workResources().first { $0.kind == "codex.app.goal" }?.acquiredBy
          == goalCreator)
      try inject(
        fixture, [turnNotification("turn/started", thread: "thread_fixture", id: "goal-turn")])
      _ = try await invoke(runtime, "thread/goal/get", params: thread)
      try await until {
        await runtime.status().objectValue?["threads"]?.arrayValue?.first?.objectValue?[
          "active_turn_id"] == .string("goal-turn")
      }
      let rows = try await runtime.workResources()
      #expect(rows.count == 3)
      #expect(
        rows.filter { $0.kind != "codex.app.thread" }.allSatisfy { $0.acquiredBy == goalCreator })
      _ = try await invoke(runtime, "thread/goal/clear", params: thread)
      #expect(try await runtime.workResources().filter { $0.kind == "codex.app.goal" }.isEmpty)
      #expect(
        try await runtime.workResources().first { $0.kind == "codex.app.turn" }?.acquiredBy
          == goalCreator)
    }
  }

  @Test(arguments: [false, true])
  func goalTurnBeforeMutationReplyKeepsTheGoalCreator(inputBeforeTurn: Bool) async throws {
    try await withRuntime { fixture, runtime in
      _ = try await invoke(runtime, "thread/start")
      let creator = UUID()
      let gate = fixture.directory.appendingPathComponent("hold-notification-response")
      try Data().write(to: gate)
      let messages =
        inputBeforeTurn
        ? [inputRequest(turnID: "goal-turn")]
        : [turnNotification("turn/started", id: "goal-turn")]
      try inject(fixture, messages)
      let starting = Task {
        try await invoke(runtime, "thread/goal/set", params: threadParams(), creator: creator)
      }
      defer { starting.cancel() }
      if inputBeforeTurn {
        try await until {
          await runtime.pendingRequests().objectValue?["requests"]?.arrayValue?.count == 1
        }
      } else {
        try await until {
          await runtime.status().objectValue?["threads"]?.arrayValue?.first?.objectValue?[
            "active_turn_id"] == .string("goal-turn")
        }
      }
      try FileManager.default.removeItem(at: gate)
      _ = try await starting.value
      if inputBeforeTurn {
        try inject(fixture, [turnNotification("turn/started", id: "goal-turn")])
        _ = try await invoke(runtime, "thread/goal/get", params: threadParams())
        try await until {
          await runtime.status().objectValue?["threads"]?.arrayValue?.first?.objectValue?[
            "active_turn_id"] == .string("goal-turn")
        }
      }
      let work = try await runtime.workResources().filter { $0.kind != "codex.app.thread" }
      let expected: Set<String> =
        inputBeforeTurn
        ? ["codex.app.goal", "codex.app.turn", "codex.app.server-request"]
        : ["codex.app.goal", "codex.app.turn"]
      #expect(Set(work.map(\.kind)) == expected)
      #expect(work.allSatisfy { $0.acquiredBy == creator })
    }
  }

  @Test(arguments: ["thread/goal/clear", "thread/goal/get"])
  func goalResponseCannotDiscardAnInterleavedActiveNotification(method: String) async throws {
    try await withRuntime { fixture, runtime in
      _ = try await invoke(runtime, "thread/start")
      let creator = UUID()
      _ = try await invoke(runtime, "thread/goal/set", params: threadParams(), creator: creator)
      let first = try #require(
        try await runtime.workResources().first { $0.kind == "codex.app.goal" })
      try Data("complete".utf8).write(
        to: fixture.directory.appendingPathComponent("goal-read-status"))
      let gate = fixture.directory.appendingPathComponent("hold-notification-response")
      try Data().write(to: gate)
      try inject(fixture, [goalNotification()])
      let querying = Task { try await invoke(runtime, method, params: threadParams()) }
      defer { querying.cancel() }
      try await until {
        let events = await runtime.events(afterCursor: 0, maxResults: 100)
        return events.objectValue?["events"]?.arrayValue?.contains {
          $0.objectValue?["payload"]?.objectValue?["method"] == .string("thread/goal/updated")
        } == true
      }
      try FileManager.default.removeItem(at: gate)
      _ = try await querying.value
      let remaining = try await runtime.workResources().filter { $0.kind == "codex.app.goal" }
      #expect(remaining.count == 1)
      #expect(remaining.first?.id == first.id)
      #expect(remaining.first?.acquiredBy == creator)
      if method == "thread/goal/clear" { #expect(remaining.first?.state == .uncertain) }
      _ = try await invoke(runtime, "thread/goal/get", params: threadParams())
      #expect(try await runtime.workResources().filter { $0.kind == "codex.app.goal" }.isEmpty)
    }
  }

  private func goalNotification() -> JSONValue {
    .object([
      "method": .string("thread/goal/updated"),
      "params": .object([
        "threadId": .string("thread_native"),
        "goal": .object([
          "threadId": .string("thread_native"), "status": .string("active"),
          "objective": .string("fixture"), "createdAt": .integer(1), "updatedAt": .integer(2),
          "timeUsedSeconds": .integer(0), "tokensUsed": .integer(0),
        ]),
      ]),
    ])
  }

  @Test
  func unboundHistoricalThreadsRemainUnavailableAndAreNotClaimedByReaders() async throws {
    try await withRuntime { fixture, runtime in
      try Data("thread_fixture".utf8).write(
        to: fixture.directory.appendingPathComponent("created-thread-id"))
      _ = try await invoke(runtime, "thread/loaded/list")
      await #expect(throws: (any Error).self) { try await runtime.workResources() }
      _ = try await invoke(runtime, "thread/goal/get", params: threadParams("thread_fixture"))
      await #expect(throws: (any Error).self) { try await runtime.workResources() }
      _ = try await invoke(runtime, "thread/resume", params: threadParams("thread_fixture"))
      await #expect(throws: (any Error).self) { try await runtime.workResources() }
      await runtime.shutdown()
      #expect(try await runtime.workResources().isEmpty)
    }
  }

  @Test
  func pendingStartupIsOwnedUntilCancellationCleanup() async throws {
    try await withRuntime { fixture, runtime in
      try Data().write(to: fixture.hangInitializeFile)
      let creator = UUID()
      let starting = Task { try await invoke(runtime, "thread/start", creator: creator) }
      defer { starting.cancel() }
      _ = try await fixture.waitForLatestPID(count: 1)
      let rows = try await runtime.workResources()
      #expect(Set(rows.map(\.kind)) == ["codex.app.call", "codex.app.startup"])
      #expect(rows.allSatisfy { $0.acquiredBy == creator })
      starting.cancel()
      _ = await starting.result
      await runtime.shutdown()
      #expect(try await runtime.workResources().isEmpty)
    }
  }

  @Test
  func hostCallbackRemainsOwnedAfterTurnAndNativeProcessComplete() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let host = BlockingWorkHost()
    let runtime = fixture.makeRuntime(
      workspaceID: fixture.directory.lastPathComponent, dynamicToolDispatcher: host)
    do {
      _ = try await invoke(runtime, "thread/start")
      let creator = UUID()
      _ = try await invoke(runtime, "turn/start", params: turnParams(), creator: creator)
      try inject(
        fixture, [dynamicRequest(), turnNotification("turn/completed", id: "turn_native")])
      _ = try await invoke(runtime, "thread/goal/get", params: threadParams())
      try await until { await host.started }
      await runtime.shutdown()
      let remaining = try await runtime.workResources()
      #expect(remaining.count == 1)
      #expect(remaining.first?.kind == "codex.app.server-request")
      #expect(remaining.first?.acquiredBy == creator)
      await host.finish()
      try await until { try await runtime.workResources().isEmpty }
    } catch {
      await host.finish()
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func reusedRequestIDInANewConnectionDoesNotReplaceAnUnfinishedHostCallback() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let host = BlockingWorkHost()
    let runtime = fixture.makeRuntime(
      workspaceID: fixture.directory.lastPathComponent, dynamicToolDispatcher: host)
    do {
      _ = try await invoke(runtime, "thread/start")
      let firstCreator = UUID()
      _ = try await invoke(runtime, "turn/start", params: turnParams(), creator: firstCreator)
      try inject(fixture, [dynamicRequest()])
      _ = try await invoke(runtime, "thread/goal/get", params: threadParams())
      try await until { await host.count == 1 }
      let process = try await fixture.waitForLatestPID(count: 1)
      #expect(Darwin.kill(process, SIGTERM) == 0)
      try await until {
        let status = await runtime.status().objectValue
        return status?["connection_state"] != .string("running")
          && status?["process"]?.objectValue?["cleanup_confirmed"] == .bool(true)
      }
      _ = try await invoke(runtime, "thread/start")
      let secondCreator = UUID()
      _ = try await invoke(runtime, "turn/start", params: turnParams(), creator: secondCreator)
      try inject(fixture, [dynamicRequest()])
      _ = try await invoke(runtime, "thread/goal/get", params: threadParams())
      try await until { await host.count == 2 }
      let callbacks = try await runtime.workResources().filter {
        $0.kind == "codex.app.server-request"
      }
      #expect(callbacks.count == 2)
      #expect(Set(callbacks.map(\.acquiredBy)) == [firstCreator, secondCreator])
      await runtime.shutdown()
      #expect(try await runtime.workResources().count == 2)
      await host.finish()
      try await until { try await runtime.workResources().isEmpty }
    } catch {
      await host.finish()
      await runtime.shutdown()
      throw error
    }
  }

  private func inputRequest(turnID: String) -> JSONValue {
    .object([
      "id": .integer(900), "method": .string("item/tool/requestUserInput"),
      "params": .object([
        "threadId": .string("thread_native"), "turnId": .string(turnID),
        "itemId": .string("input"), "isBlocking": .bool(true),
        "questions": .array([
          .object([
            "id": .string("confirm"), "header": .string("Confirm"),
            "question": .string("Proceed?"),
          ])
        ]),
      ]),
    ])
  }

  private func dynamicRequest() -> JSONValue {
    .object([
      "id": .integer(900), "method": .string("item/tool/call"),
      "params": .object([
        "callId": .string("fixture-callback"), "threadId": .string("thread_native"),
        "turnId": .string("turn_native"), "namespace": .string("computer-mcp"),
        "tool": .string("fixture.read"), "arguments": .object([:]),
      ]),
    ])
  }

  private func invoke(
    _ runtime: LiveCodexAppServerRuntime, _ method: String,
    params: JSONValue = .object([:]), creator: UUID = UUID()
  ) async throws -> JSONValue {
    try await CodexWorkInvocation.$current.withValue(creator) {
      try await runtime.call(method: method, params: params)
    }
  }

  private func threadParams(_ id: String = "thread_native") -> JSONValue {
    .object(["threadId": .string(id)])
  }

  private func turnParams() -> JSONValue {
    .object([
      "threadId": .string("thread_native"),
      "input": .array([.object(["type": .string("text"), "text": .string("fixture")])]),
    ])
  }

  private func turnNotification(_ method: String, thread: String = "thread_native", id: String)
    -> JSONValue
  {
    .object([
      "method": .string(method),
      "params": .object([
        "threadId": .string(thread),
        "turn": .object([
          "id": .string(id), "items": .array([]),
          "status": .string(method == "turn/started" ? "inProgress" : "completed"),
        ]),
      ]),
    ])
  }

  private func inject(_ fixture: AppServerProcessFixture, _ messages: [JSONValue]) throws {
    let data = try messages.reduce(into: Data()) { data, message in
      data.append(try JSONEncoder().encode(message))
      data.append(10)
    }
    try data.write(to: fixture.directory.appendingPathComponent("notifications-next.jsonl"))
  }

  private func until(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<500 {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CodexToolError.executionFailed("Timed out waiting for the isolated fixture observation.")
  }

  private func withRuntime(
    _ body: (AppServerProcessFixture, LiveCodexAppServerRuntime) async throws -> Void
  ) async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let runtime = fixture.makeRuntime(
      requestTimeoutSeconds: 10, workspaceID: fixture.directory.lastPathComponent)
    do {
      try await body(fixture, runtime)
      await runtime.shutdown()
    } catch {
      try? FileManager.default.removeItem(
        at: fixture.directory.appendingPathComponent("hold-notification-response"))
      await runtime.shutdown()
      throw error
    }
  }
}

private actor BlockingWorkHost: CodexHostTools {
  private(set) var started = false
  private var continuations: [CheckedContinuation<Void, Never>] = []
  var count: Int { continuations.count }
  func risk(named name: String, arguments: JSONValue, requestID: String, workspaceID: String?)
    -> CodexOperationRisk
  { .readOnly }
  func execute(name: String, arguments: JSONValue, requestID: String, workspaceID: String?) async
    -> JSONValue
  {
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
      started = true
    }
    return .object(["done": .bool(true)])
  }
  func finish() {
    let pending = continuations
    continuations.removeAll()
    for continuation in pending { continuation.resume() }
  }
}
