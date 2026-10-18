import Darwin
import Foundation
import Testing

@testable import CodexAdapter

@Suite(.serialized)
struct CodexAppWorkOwnershipTests {
  @Test
  func threadAndTurnKeepDifferentCreatorsAndReleasedThreadGetsANewLifetime() async throws {
    try await withRuntime { fixture, runtime in
      let threadCreator = UUID()
      let turnCreator = UUID()
      _ = try await invoke(runtime, "thread/start", creator: threadCreator)
      let first = try #require(try await runtime.workResources().first)
      #expect(first.kind == "codex.app.thread")
      #expect(first.acquiredBy == threadCreator)
      #expect(
        first.handles == [
          "thread_id": .string("thread_native"), "runtime_id": .string(runtime.runtimeID),
        ])
      _ = try await invoke(runtime, "turn/start", params: turnParams(), creator: turnCreator)
      let rows = try await runtime.workResources()
      #expect(rows.count == 2)
      #expect(rows.first { $0.kind == "codex.app.turn" }?.acquiredBy == turnCreator)
      #expect(
        rows.first { $0.kind == "codex.app.turn" }?.handles == [
          "thread_id": .string("thread_native"), "turn_id": .string("turn_native"),
          "runtime_id": .string(runtime.runtimeID),
        ])
      #expect(rows.first { $0.kind == "codex.app.thread" } == first)
      _ = try await invoke(runtime, "thread/unsubscribe", params: threadParams())
      #expect(try await runtime.workResources() == rows)
      try inject(
        fixture,
        [
          .object([
            "method": .string("thread/closed"), "params": threadParams(),
          ])
        ])
      _ = try await invoke(runtime, "thread/goal/get", params: threadParams())
      try await until { try await runtime.workResources().isEmpty }
      let replacementCreator = UUID()
      _ = try await invoke(runtime, "thread/start", creator: replacementCreator)
      let replacement = try #require(try await runtime.workResources().first)
      #expect(replacement.id != first.id)
      #expect(replacement.acquiredBy == replacementCreator)
      #expect(replacement.handles == first.handles)
    }
  }

  @Test
  func threadClosedBeforeCreationReplyDoesNotRegainLiveOwnership() async throws {
    try await withRuntime { fixture, runtime in
      let gate = fixture.directory.appendingPathComponent("hold-notification-response")
      try Data().write(to: gate)
      try inject(
        fixture,
        [
          .object([
            "method": .string("thread/closed"), "params": threadParams(),
          ])
        ])
      let starting = Task { try await invoke(runtime, "thread/start") }
      defer { starting.cancel() }
      try await until {
        await runtime.events(afterCursor: 0, maxResults: 100).objectValue?["events"]?.arrayValue?
          .contains {
            $0.objectValue?["payload"]?.objectValue?["method"] == .string("thread/closed")
          } == true
      }
      try FileManager.default.removeItem(at: gate)
      _ = try await starting.value
      #expect(try await runtime.workResources().isEmpty)
      #expect(!(await runtime.hasLiveOwnership(of: "thread_native")))
    }
  }

  @Test
  func missingLoadedThreadWaitsForClosureAndCannotBeResumedOverCleanup() async throws {
    try await withRuntime { fixture, runtime in
      _ = try await invoke(runtime, "thread/start")
      let original = try #require(try await runtime.workResources().first)
      _ = try await invoke(runtime, "thread/unsubscribe", params: threadParams())
      try Data("[]".utf8).write(to: fixture.loadedThreadsFile)
      _ = try await invoke(runtime, "thread/loaded/list")
      let uncertain = try #require(try await runtime.workResources().first)
      #expect(uncertain.id == original.id)
      #expect(uncertain.acquiredBy == original.acquiredBy)
      #expect(uncertain.state == .uncertain)
      await #expect(throws: (any Error).self) {
        try await invoke(runtime, "thread/resume", params: threadParams())
      }
      try inject(
        fixture,
        [
          .object([
            "method": .string("thread/closed"), "params": threadParams(),
          ])
        ])
      _ = try await invoke(runtime, "thread/loaded/list")
      try await until { try await runtime.workResources().isEmpty }
    }
  }

  @Test
  func archiveCloseNotificationKeepsUnconfirmedNativeCleanupOwned() async throws {
    try await withRuntime { fixture, runtime in
      _ = try await invoke(runtime, "thread/start")
      let original = try #require(try await runtime.workResources().first)
      try inject(
        fixture,
        [
          .object([
            "method": .string("thread/closed"), "params": threadParams(),
          ])
        ])
      _ = try await invoke(runtime, "thread/archive", params: threadParams())
      try await until {
        await runtime.status().objectValue?["threads"]?.arrayValue?.first?.objectValue?["state"]
          == .string("closed")
      }
      let retained = try #require(try await runtime.workResources().first)
      #expect(retained.id == original.id)
      #expect(retained.state == .uncertain)
      await runtime.shutdown()
      #expect(try await runtime.workResources().isEmpty)
    }
  }

  @Test
  func handoffCannotReapAnUnrelatedPendingLogin() async throws {
    try await withRuntime { fixture, runtime in
      _ = try await invoke(runtime, "thread/start")
      try Data("[\"thread_native\"]".utf8).write(to: fixture.loadedThreadsFile)
      let creator = UUID()
      _ = try await invoke(
        runtime, "account/login/start", params: .object(["type": .string("chatgpt")]),
        creator: creator)
      let preparation = try await runtime.prepareForHandoff(
        threadID: "thread_native", mode: .graceful, interruptActiveTurn: false)
      await #expect(throws: (any Error).self) {
        try await runtime.releaseForHandoff(
          threadID: "thread_native", mode: .graceful, interruptActiveTurn: false,
          preparationID: preparation)
      }
      #expect(
        try await runtime.workResources().first { $0.kind == "codex.app.login" }?.acquiredBy
          == creator)
      #expect(await runtime.status().objectValue?["connection_state"] != .string("stopped"))
    }
  }

  @Test
  func remoteControlDisableRetainsItsOwnerUntilNativeProcessCleanup() async throws {
    try await withRuntime { fixture, runtime in
      _ = try await invoke(runtime, "thread/start")
      let creator = UUID()
      _ = try await invoke(runtime, "remoteControl/enable", creator: creator)
      let first = try #require(
        try await runtime.workResources().first { $0.kind == "codex.app.remote-control" })
      try inject(fixture, [remoteStatus("disabled")])
      _ = try await invoke(runtime, "remoteControl/disable")
      let retained = try #require(
        try await runtime.workResources().first { $0.kind == "codex.app.remote-control" })
      #expect(retained.id == first.id)
      #expect(retained.acquiredBy == creator)
      #expect(retained.state == .uncertain)
      await runtime.shutdown()
      #expect(try await runtime.workResources().isEmpty)
    }
  }

  @Test
  func persistedRemoteControlBelongsToTheConnectionCreator() async throws {
    try await withRuntime { fixture, runtime in
      try Data("connected".utf8).write(
        to: fixture.directory.appendingPathComponent("initial-remote-status"))
      let creator = UUID()
      _ = try await invoke(runtime, "thread/start", creator: creator)
      let remote = try #require(
        try await runtime.workResources().first { $0.kind == "codex.app.remote-control" })
      #expect(remote.acquiredBy == creator)
      try inject(fixture, [remoteStatus("disabled")])
      _ = try await invoke(runtime, "thread/goal/get", params: threadParams())
      try await until {
        try await runtime.workResources().first { $0.kind == "codex.app.remote-control" }?.state
          == .uncertain
      }
      #expect(try await runtime.workResources().contains { $0.id == remote.id })
    }
  }

  private func remoteStatus(_ status: String) -> JSONValue {
    .object([
      "method": .string("remoteControl/status/changed"),
      "params": .object([
        "status": .string(status), "installationId": .string("fixture-installation"),
        "serverName": .string("fixture"),
      ]),
    ])
  }

  @Test(arguments: [false, true])
  func realtimeWorkEndsAtClosureRatherThanStopAcknowledgement(earlyClose: Bool) async throws {
    try await withRuntime { fixture, runtime in
      _ = try await invoke(runtime, "thread/start")
      let creator = UUID()
      let closed = JSONValue.object([
        "method": .string("thread/realtime/closed"), "params": threadParams(),
      ])
      let gate = fixture.directory.appendingPathComponent("hold-notification-response")
      if earlyClose {
        try Data().write(to: gate)
        try inject(fixture, [closed])
      }
      let starting = Task {
        try await invoke(
          runtime, "thread/realtime/start",
          params: .object([
            "threadId": .string("thread_native"), "outputModality": .string("text"),
          ]), creator: creator)
      }
      defer { starting.cancel() }
      if earlyClose {
        try await until {
          await runtime.events(afterCursor: 0, maxResults: 100).objectValue?["events"]?.arrayValue?
            .contains {
              $0.objectValue?["payload"]?.objectValue?["method"]
                == .string("thread/realtime/closed")
            } == true
        }
        try FileManager.default.removeItem(at: gate)
      }
      _ = try await starting.value
      if !earlyClose {
        let first = try #require(
          try await runtime.workResources().first { $0.kind == "codex.app.realtime" })
        #expect(first.acquiredBy == creator)
        await #expect(throws: (any Error).self) {
          try await runtime.prepareForHandoff(
            threadID: "thread_native", mode: .graceful, interruptActiveTurn: false)
        }
        _ = try await invoke(runtime, "thread/realtime/stop", params: threadParams())
        #expect(try await runtime.workResources().contains(first))
        try inject(fixture, [closed])
        _ = try await invoke(runtime, "thread/goal/get", params: threadParams())
      }
      try await until {
        try await runtime.workResources().filter { $0.kind == "codex.app.realtime" }.isEmpty
      }
    }
  }

  @Test(arguments: ["thread/queue/start", "review/start"])
  func returnedTurnsRetainTheirCreator(method: String) async throws {
    try await withRuntime { _, runtime in
      _ = try await invoke(runtime, "thread/start")
      let creator = UUID()
      var params = ["threadId": JSONValue.string("thread_native")]
      if method == "review/start" {
        params["target"] = .object(["type": .string("uncommittedChanges")])
      } else {
        params["queuedSubmissionId"] = .string("queued-fixture")
      }
      _ = try await invoke(runtime, method, params: .object(params), creator: creator)
      let turn = try #require(
        try await runtime.workResources().first { $0.kind == "codex.app.turn" })
      #expect(turn.acquiredBy == creator)
    }
  }

  @Test(arguments: [false, true])
  func queuedInputOwnsItsEarlyAutomaticTurnAndCallbacks(completed: Bool) async throws {
    try await withRuntime { fixture, runtime in
      _ = try await invoke(runtime, "thread/start")
      _ = try await invoke(runtime, "thread/goal/set", params: threadParams())
      let gate = fixture.directory.appendingPathComponent("hold-notification-response")
      try Data().write(to: gate)
      var messages = [
        turnNotification("turn/started", id: "turn_native"),
        inputRequest(turnID: "turn_native"), queuedUserMessage(),
      ]
      if completed { messages.append(turnNotification("turn/completed", id: "turn_native")) }
      try inject(fixture, messages)
      let creator = UUID()
      let adding = Task {
        try await invoke(runtime, "thread/queue/add", params: queueParams(), creator: creator)
      }
      defer { adding.cancel() }
      try await until {
        let method = completed ? "turn/completed" : "item/started"
        return await runtime.events(afterCursor: 0, maxResults: 100).objectValue?["events"]?
          .arrayValue?
          .contains { $0.objectValue?["payload"]?.objectValue?["method"] == .string(method) }
          == true
      }
      try FileManager.default.removeItem(at: gate)
      _ = try await adding.value
      let resources = try await runtime.workResources()
      #expect(resources.filter { $0.kind == "codex.app.queued-input" }.isEmpty)
      #expect(resources.first { $0.kind == "codex.app.server-request" }?.acquiredBy == creator)
      #expect(resources.filter { $0.kind == "codex.app.turn" }.count == (completed ? 0 : 1))
      #expect(
        resources.filter { $0.kind == "codex.app.turn" }.allSatisfy { $0.acquiredBy == creator })
    }
  }

  @Test
  func explicitQueueStartRetainsTheQueuedCreatorAndDeletionReleasesPendingInput() async throws {
    try await withRuntime { fixture, runtime in
      _ = try await invoke(runtime, "thread/start")
      let creator = UUID()
      _ = try await invoke(runtime, "thread/queue/add", params: queueParams(), creator: creator)
      let queued = try #require(
        try await runtime.workResources().first { $0.kind == "codex.app.queued-input" })
      #expect(queued.acquiredBy == creator)
      #expect(
        queued.handles == [
          "thread_id": .string("thread_native"), "client_id": .string("queued-client"),
          "submission_id": .string("queued-native"), "runtime_id": .string(runtime.runtimeID),
        ])
      await #expect(throws: (any Error).self) {
        try await invoke(runtime, "thread/queue/add", params: queueParams())
      }
      _ = try await invoke(
        runtime, "thread/queue/start",
        params: .object([
          "threadId": .string("thread_native"), "queuedSubmissionId": .string("queued-native"),
        ]))
      #expect(
        try await runtime.workResources().first { $0.kind == "codex.app.turn" }?.acquiredBy
          == creator)
      try inject(
        fixture, [queuedUserMessage(), turnNotification("turn/completed", id: "turn_native")])
      _ = try await invoke(runtime, "thread/goal/get", params: threadParams())
      try await until { try await runtime.workResources().count == 1 }
      _ = try await invoke(runtime, "thread/queue/add", params: queueParams())
      _ = try await invoke(
        runtime, "thread/queue/delete",
        params: .object([
          "threadId": .string("thread_native"), "queuedSubmissionId": .string("queued-native"),
        ]))
      #expect(try await runtime.workResources().count == 1)
    }
  }

  private func queueParams() -> JSONValue {
    .object([
      "threadId": .string("thread_native"), "clientUserMessageId": .string("queued-client"),
      "input": .array([.object(["type": .string("text"), "text": .string("fixture")])]),
    ])
  }

  private func queuedUserMessage() -> JSONValue {
    .object([
      "method": .string("item/started"),
      "params": .object([
        "threadId": .string("thread_native"), "turnId": .string("turn_native"),
        "item": .object([
          "type": .string("userMessage"), "id": .string("fixture-user-message"),
          "clientId": .string("queued-client"), "content": .array([]),
        ]),
      ]),
    ])
  }

  @Test(arguments: [false, true])
  func detachedReviewBindsEarlyInputWithoutResurrectingACompletedTurn(completed: Bool) async throws
  {
    try await withRuntime { fixture, runtime in
      _ = try await invoke(runtime, "thread/start")
      try Data("review-thread".utf8).write(
        to: fixture.directory.appendingPathComponent("review-thread-id"))
      var input = try #require(inputRequest(turnID: "turn_native").objectValue)
      var inputParams = try #require(input["params"]?.objectValue)
      inputParams["threadId"] = .string("review-thread")
      input["params"] = .object(inputParams)
      var messages = [
        turnNotification("turn/started", thread: "review-thread", id: "turn_native"),
        JSONValue.object(input),
      ]
      if completed {
        messages.append(
          turnNotification("turn/completed", thread: "review-thread", id: "turn_native"))
      }
      try inject(fixture, messages)
      let gate = fixture.directory.appendingPathComponent("hold-notification-response")
      try Data().write(to: gate)
      let creator = UUID()
      let reviewing = Task {
        try await invoke(
          runtime, "review/start",
          params: .object([
            "threadId": .string("thread_native"), "delivery": .string("detached"),
            "target": .object(["type": .string("uncommittedChanges")]),
          ]), creator: creator)
      }
      defer { reviewing.cancel() }
      try await until {
        await runtime.pendingRequests().objectValue?["requests"]?.arrayValue?.count == 1
      }
      if completed {
        try await until {
          await runtime.events(afterCursor: 0, maxResults: 100).objectValue?["events"]?.arrayValue?
            .contains {
              $0.objectValue?["payload"]?.objectValue?["method"] == .string("turn/completed")
            } == true
        }
      }
      try FileManager.default.removeItem(at: gate)
      _ = try await reviewing.value
      let rows = try await runtime.workResources()
      #expect(rows.filter { $0.kind == "codex.app.thread" }.count == 2)
      #expect(rows.first { $0.kind == "codex.app.server-request" }?.acquiredBy == creator)
      #expect(rows.filter { $0.kind == "codex.app.turn" }.count == (completed ? 0 : 1))
      #expect(rows.filter { $0.kind == "codex.app.turn" }.allSatisfy { $0.acquiredBy == creator })
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
      #expect(
        rows.first { $0.kind == "codex.app.server-request" }?.handles == [
          "request_id": .string(id), "thread_id": .string("thread_native"),
          "turn_id": .string("turn_native"), "runtime_id": .string(runtime.runtimeID),
        ])
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
  func canceledAndReplacedLoginsKeepOwnersUntilTheirExactCompletion() async throws {
    try await withRuntime { fixture, runtime in
      let firstCreator = UUID()
      let secondCreator = UUID()
      let firstID = "11111111-1111-1111-1111-111111111111"
      let secondID = UUID().uuidString
      let params = JSONValue.object(["type": .string("chatgpt")])
      _ = try await invoke(runtime, "account/login/start", params: params, creator: firstCreator)
      let first = try #require(try await runtime.workResources().first)
      #expect(first.handles["login_id"] == .string(firstID))
      _ = try await invoke(
        runtime, "account/login/cancel", params: .object(["loginId": .string(firstID)]))
      #expect(try await runtime.workResources() == [first])
      try Data(secondID.utf8).write(to: fixture.directory.appendingPathComponent("login-id"))
      _ = try await invoke(runtime, "account/login/start", params: params, creator: secondCreator)
      #expect(
        Set(try await runtime.workResources().map(\.acquiredBy)) == [firstCreator, secondCreator])
      try inject(fixture, [loginCompletion(id: firstID)])
      _ = try await invoke(
        runtime, "account/login/cancel", params: .object(["loginId": .string(firstID)]))
      try await until { try await runtime.workResources().count == 1 }
      #expect(try await runtime.workResources().first?.acquiredBy == secondCreator)
      #expect(try await runtime.workResources().first?.handles["login_id"] == .string(secondID))
      try inject(fixture, [loginCompletion(id: secondID)])
      _ = try await invoke(
        runtime, "account/login/cancel", params: .object(["loginId": .string(secondID)]))
      try await until { try await runtime.workResources().isEmpty }
    }
  }

  @Test(arguments: [false, true])
  func earlyLoginCompletionDoesNotLeaveWorkAfterTheReply(mcp: Bool) async throws {
    try await withRuntime { fixture, runtime in
      let method = mcp ? "mcpServer/oauth/login" : "account/login/start"
      let completion =
        mcp
        ? mcpLoginCompletion(threadID: nil)
        : loginCompletion(id: "11111111-1111-1111-1111-111111111111")
      let params = JSONValue.object(
        mcp ? ["name": .string("fixture")] : ["type": .string("chatgptDeviceCode")])
      let gate = fixture.directory.appendingPathComponent("hold-notification-response")
      try Data().write(to: gate)
      try inject(fixture, [completion])
      let starting = Task { try await invoke(runtime, method, params: params) }
      defer { starting.cancel() }
      try await until {
        await runtime.events(afterCursor: 0, maxResults: 100).objectValue?["events"]?.arrayValue?
          .contains {
            $0.objectValue?["payload"]?.objectValue?["method"] == completion.objectValue?["method"]
          } == true
      }
      try FileManager.default.removeItem(at: gate)
      _ = try await starting.value
      #expect(try await runtime.workResources().isEmpty)
    }
  }

  @Test
  func mcpLoginCompletionMatchesServerAndThreadBeforeAllowingAnotherAttempt() async throws {
    try await withRuntime { fixture, runtime in
      _ = try await invoke(runtime, "thread/start")
      let globalCreator = UUID()
      let threadCreator = UUID()
      let globalParams = JSONValue.object(["name": .string("fixture")])
      _ = try await invoke(
        runtime, "mcpServer/oauth/login", params: globalParams, creator: globalCreator)
      await #expect(throws: (any Error).self) {
        try await invoke(runtime, "mcpServer/oauth/login", params: globalParams)
      }
      _ = try await invoke(
        runtime, "mcpServer/oauth/login",
        params: .object([
          "name": .string("fixture"), "threadId": .string("thread_native"),
        ]), creator: threadCreator)
      try inject(fixture, [mcpLoginCompletion(threadID: nil)])
      _ = try await invoke(runtime, "thread/goal/get", params: threadParams())
      try await until {
        try await runtime.workResources().filter { $0.kind == "codex.app.mcp-login" }.count == 1
      }
      #expect(
        try await runtime.workResources().first { $0.kind == "codex.app.mcp-login" }?.acquiredBy
          == threadCreator)
      _ = try await invoke(runtime, "mcpServer/oauth/login", params: globalParams)
      #expect(
        try await runtime.workResources().filter { $0.kind == "codex.app.mcp-login" }.count == 2)
      await runtime.shutdown()
      #expect(try await runtime.workResources().isEmpty)
    }
  }

  private func loginCompletion(id: String) -> JSONValue {
    .object([
      "method": .string("account/login/completed"),
      "params": .object(["loginId": .string(id), "success": .bool(false), "error": .null]),
    ])
  }

  private func mcpLoginCompletion(threadID: String?) -> JSONValue {
    .object([
      "method": .string("mcpServer/oauthLogin/completed"),
      "params": .object([
        "name": .string("fixture"), "threadId": threadID.map(JSONValue.string) ?? .null,
        "success": .bool(false), "error": .null,
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
  func nativeThreadActivityKeepsItsParentOriginRatherThanTheObserver() async throws {
    try await withRuntime { fixture, runtime in
      let creator = UUID()
      _ = try await invoke(runtime, "thread/start", creator: creator)
      try inject(
        fixture,
        [
          turnNotification("turn/started", id: "native-turn"),
          inputRequest(turnID: "native-turn"),
        ])
      _ = try await invoke(runtime, "thread/goal/get", params: threadParams(), creator: UUID())
      try await until {
        await runtime.pendingRequests().objectValue?["requests"]?.arrayValue?.count == 1
      }
      let resources = try await runtime.workResources()
      #expect(
        Set(resources.map(\.kind)) == [
          "codex.app.thread", "codex.app.turn", "codex.app.server-request",
        ])
      #expect(resources.allSatisfy { $0.acquiredBy == creator })
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

  @Test
  func queuedHostRequestKeepsItsOriginWhenTurnCompletionOvertakesItsConsumer() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let host = BlockingWorkHost()
    let runtime = fixture.makeRuntime(
      workspaceID: fixture.directory.lastPathComponent, dynamicToolDispatcher: host)
    do {
      _ = try await invoke(runtime, "thread/start")
      let creator = UUID()
      _ = try await invoke(runtime, "turn/start", params: turnParams(), creator: creator)
      try inject(fixture, [dynamicRequest()])
      _ = try await invoke(runtime, "thread/goal/get", params: threadParams())
      try await until { await host.totalStarted == 1 }
      try inject(
        fixture, [dynamicRequest(id: 901), turnNotification("turn/completed", id: "turn_native")])
      _ = try await invoke(runtime, "thread/goal/get", params: threadParams())
      try await until {
        await runtime.status().objectValue?["threads"]?.arrayValue?.first?.objectValue?[
          "active_turn_id"] == .null
      }
      try await until { await host.totalStarted == 2 }
      let callbacks = try await runtime.workResources().filter {
        $0.kind == "codex.app.server-request"
      }
      #expect(callbacks.count == 2)
      #expect(callbacks.allSatisfy { $0.acquiredBy == creator })
      await host.finish()
      await runtime.shutdown()
      try await until { try await runtime.workResources().isEmpty }
    } catch {
      await host.finish()
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func callbackCapacityRejectsNewRequestsWithoutEvictingUnfinishedOwners() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let host = BlockingWorkHost()
    let runtime = fixture.makeRuntime(
      workspaceID: fixture.directory.lastPathComponent, dynamicToolDispatcher: host)
    do {
      _ = try await invoke(runtime, "thread/start")
      let creator = UUID()
      _ = try await invoke(runtime, "turn/start", params: turnParams(), creator: creator)
      let requests = (900...1156).map { dynamicRequest(id: Int64($0)) }
      for offset in stride(from: 0, to: requests.count, by: 16) {
        let end = min(offset + 16, requests.count)
        let completion =
          end == requests.count
          ? [turnNotification("turn/completed", id: "turn_native")] : []
        try inject(fixture, Array(requests[offset..<end]) + completion)
        _ = try await invoke(runtime, "thread/goal/get", params: threadParams())
        try await until { await host.totalStarted == min(end, 256) }
      }
      try await until {
        (try? String(contentsOf: fixture.approvalResponseLog, encoding: .utf8))?
          .contains("pending server-request capacity") == true
      }
      let callbacks = try await runtime.workResources().filter {
        $0.kind == "codex.app.server-request"
      }
      #expect(callbacks.count == 256)
      #expect(callbacks.allSatisfy { $0.acquiredBy == creator })
      await runtime.shutdown()
      #expect(try await runtime.workResources().count == 256)
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

  private func dynamicRequest(id: Int64 = 900) -> JSONValue {
    .object([
      "id": .integer(id), "method": .string("item/tool/call"),
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
  private(set) var totalStarted = 0
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
      totalStarted += 1
    }
    return .object(["done": .bool(true)])
  }
  func finish() {
    let pending = continuations
    continuations.removeAll()
    for continuation in pending { continuation.resume() }
  }
}
