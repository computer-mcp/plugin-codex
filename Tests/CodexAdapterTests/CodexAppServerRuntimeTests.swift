import CodexAppServerClient
import CodexAppServerProtocol
import Darwin
import Foundation
import Testing

@testable import CodexAdapter

@Suite(.serialized)
final class CodexAppServerRuntimeTests {
  @Test(arguments: [false, true])
  func testUnavailableExecutableReportsFailedStartup(missingInterpreter: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("configured-codex")
    if missingInterpreter {
      try Data("#!\(root.path)/missing-interpreter\n".utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    let runtime = LiveCodexAppServerRuntime(
      configuration: CodexConfig(enabled: true, executable: executable.path), workspaceURL: root)
    await assertThrowsErrorAsync(
      try await runtime.call(method: "thread/loaded/list", params: .object([:])))
    let status = await runtime.status()
    await runtime.shutdown()
    #expect(status.objectValue?["connection_state"] == .string("failed"))
    #expect(status.objectValue?["last_error"]?.stringValue?.isEmpty == false)
  }

  @Test
  func testReleaseForHandoffVerifiesLoadedStateAndReapsEmptyRuntime() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let database = try CodexDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(database: database)
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))
    _ = try await runtime.call(
      method: "thread/goal/set",
      params: .object([
        "threadId": .string("thread_fixture"),
        "objective": .string("Pass every acceptance criterion."),
      ])
    )
    let processID = try await fixture.waitForLatestPID(count: 1)

    let released = try await CodexThreadHandoffService.release(
      threadID: "thread_fixture",
      workspaceID: "fixture-workspace",
      mode: .graceful,
      interruptActiveTurn: false,
      database: database
    )

    #expect(released.objectValue?["final_classification"] == .string("released_persisted"))
    #expect(released.objectValue?["externally_claimable"] == .bool(true))
    #expect(
      released.objectValue?["runtime_results"]?.arrayValue?.first?.objectValue?["runtime_action"]
        == .string("reaped")
    )
    #expect(await waitForProcessExit(processID))
    #expect(
      await CodexRuntimeDirectory.shared.runtimeIDs(
        owning: "thread_fixture",
        workspaceID: "fixture-workspace"
      ).isEmpty
    )
    #expect(
      try database.codexThreadOwnership(threadID: "thread_fixture")?.state == .released
    )

    let second = try await CodexThreadHandoffService.release(
      threadID: "thread_fixture",
      workspaceID: "fixture-workspace",
      mode: .graceful,
      interruptActiveTurn: false,
      database: database
    )
    #expect(second.objectValue?["already_released"] == .bool(true))
    #expect(second.objectValue?["final_classification"] == .string("released_persisted"))

    let claimingRuntime = fixture.makeRuntime(database: database)
    let persistedGoal = try await claimingRuntime.call(
      method: "thread/goal/get",
      params: .object(["threadId": .string("thread_fixture")])
    )
    #expect(
      persistedGoal.objectValue?["goal"]?.objectValue?["objective"]
        == .string("Pass every acceptance criterion.")
    )
    let claimingPID = try await fixture.waitForLatestPID(count: 2)
    #expect(processExists(claimingPID))
    await claimingRuntime.shutdown()
    #expect(await waitForProcessExit(claimingPID))
  }

  @Test
  func testActiveTurnRequiresExplicitInterruptBeforeHandoff() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureActiveTurnOnStart()
    let database = try CodexDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(database: database)
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))
    try await waitUntilRuntimeCondition {
      await runtime.status().objectValue?["threads"]?.arrayValue?.first?
        .objectValue?["active_turn_id"] == .string("turn_fixture")
    }

    await assertThrowsErrorAsync(
      try await CodexThreadHandoffService.release(
        threadID: "thread_fixture",
        workspaceID: "fixture-workspace",
        mode: .graceful,
        interruptActiveTurn: false,
        database: database
      )
    )
    #expect(await runtime.hasLiveOwnership(of: "thread_fixture"))

    let released = try await CodexThreadHandoffService.release(
      threadID: "thread_fixture",
      workspaceID: "fixture-workspace",
      mode: .graceful,
      interruptActiveTurn: true,
      database: database
    )
    #expect(released.objectValue?["externally_claimable"] == .bool(true))
    #expect(
      released.objectValue?["runtime_results"]?.arrayValue?.first?.objectValue?[
        "active_turn_handling"
      ] == .string("interrupted")
    )
  }

  @Test
  func testMultiRuntimeHandoffPreflightsAllOwnersBeforeMutation() async throws {
    let idleFixture = try AppServerProcessFixture()
    let activeFixture = try AppServerProcessFixture()
    defer {
      idleFixture.remove()
      activeFixture.remove()
    }
    try activeFixture.configureActiveTurnOnStart()
    let idleRuntime = idleFixture.makeRuntime()
    let activeRuntime = activeFixture.makeRuntime()
    _ = try await idleRuntime.call(method: "thread/loaded/list", params: .object([:]))
    _ = try await activeRuntime.call(method: "thread/loaded/list", params: .object([:]))
    try await waitUntilRuntimeCondition {
      await activeRuntime.status().objectValue?["threads"]?.arrayValue?.first?
        .objectValue?["active_turn_id"] == .string("turn_fixture")
    }
    let idleProcessID = try await idleFixture.waitForLatestPID(count: 1)
    let activeProcessID = try await activeFixture.waitForLatestPID(count: 1)

    await assertThrowsErrorAsync(
      try await CodexThreadHandoffService.release(
        threadID: "thread_fixture",
        workspaceID: "fixture-workspace",
        mode: .graceful,
        interruptActiveTurn: false,
        database: nil
      )
    )

    #expect(await idleRuntime.hasLiveOwnership(of: "thread_fixture"))
    #expect(await activeRuntime.hasLiveOwnership(of: "thread_fixture"))
    #expect(processExists(idleProcessID))
    #expect(processExists(activeProcessID))
    await idleRuntime.shutdown()
    await activeRuntime.shutdown()
  }

  @Test
  func testHandoffCannotTrustReleasedReceiptWhileExactReceiptedProcessLives() async throws {
    let database = try CodexDatabase(inMemory: ())
    let now = Date()
    try database.saveCodexRuntimeLease(
      CodexRuntimeLeaseRecord(
        id: "runtime-receipted-live",
        owner: runtimeOwner(workspaceID: "fixture-workspace"),
        workspacePath: "/tmp/fixture-workspace",
        state: "running",
        process: CodexAppServerProcessSnapshot(
          state: .running,
          processID: getpid(),
          supervisorProcessID: nil,
          parentProcessID: getppid(),
          processGroupID: getpgrp(),
          startedAt: now,
          stoppedAt: nil,
          exitCode: nil,
          signal: nil,
          terminationEscalated: false,
          lastError: nil
        ),
        createdAt: now,
        updatedAt: now,
        shutdownReason: nil,
        cleanedAt: nil
      )
    )
    try database.saveCodexThreadOwnership(
      CodexThreadOwnershipRecord(
        threadID: "thread-receipted-live",
        workspaceID: "fixture-workspace",
        workspacePath: "/tmp/fixture-workspace",
        runtimeID: "runtime-receipted-live",
        state: .released,
        createdAt: now,
        updatedAt: now
      )
    )

    await assertThrowsErrorAsync(
      try await CodexThreadHandoffService.release(
        threadID: "thread-receipted-live",
        workspaceID: "fixture-workspace",
        mode: .graceful,
        interruptActiveTurn: false,
        database: database
      )
    )
    #expect(
      try database.codexThreadOwnership(threadID: "thread-receipted-live")?.state == .released
    )
  }

  @Test
  func testHandoffPreservesRuntimeWithAnotherActiveThread() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureLoadedThreads(
      initial: ["thread_fixture", "thread_other"],
      afterUnsubscribe: ["thread_other"]
    )
    try fixture.configureActiveTurnOnStart(
      threadID: "thread_other",
      turnID: "turn_other"
    )
    let database = try CodexDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(database: database)
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))
    try await waitUntilRuntimeCondition {
      let threads = await runtime.status().objectValue?["threads"]?.arrayValue ?? []
      return threads.contains {
        $0.objectValue?["thread_id"] == .string("thread_other")
          && $0.objectValue?["active_turn_id"] == .string("turn_other")
      }
    }

    let released = try await CodexThreadHandoffService.release(
      threadID: "thread_fixture",
      workspaceID: "fixture-workspace",
      mode: .graceful,
      interruptActiveTurn: false,
      database: database
    )

    #expect(
      released.objectValue?["runtime_results"]?.arrayValue?.first?.objectValue?["runtime_action"]
        == .string("preserved-for-other-work")
    )
    #expect(!(await runtime.hasLiveOwnership(of: "thread_fixture")))
    #expect(await runtime.hasLiveOwnership(of: "thread_other"))
    await runtime.shutdown()
  }

  @Test
  func testShutdownReconcilesLoadedThreadOwnership() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let database = try CodexDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(database: database)
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))
    #expect(
      try database.codexThreadOwnership(threadID: "thread_fixture")?.state == .loaded
    )
    await runtime.shutdown()

    #expect(
      try database.codexThreadOwnership(threadID: "thread_fixture")?.state == .released
    )
    #expect(
      await CodexRuntimeDirectory.shared.runtimeIDs(
        owning: "thread_fixture",
        workspaceID: "fixture-workspace"
      ).isEmpty
    )
  }

  @Test
  func testShutdownReapsProtocolProcessAndReleasesWriterLease() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }

    let firstRuntime = fixture.makeRuntime()
    let firstResponse = try await firstRuntime.call(
      method: "thread/loaded/list",
      params: .object([:])
    )
    #expect(firstResponse.objectValue?["data"] == .array([.string("thread_fixture")]))
    let firstPID = try await fixture.waitForLatestPID(count: 1)
    #expect(processExists(firstPID))
    #expect(FileManager.default.fileExists(atPath: fixture.leaseDirectory.path))

    await firstRuntime.shutdown()

    #expect(await waitForProcessExit(firstPID))
    #expect(await waitForFileRemoval(fixture.leaseDirectory))

    let secondRuntime = fixture.makeRuntime()
    let secondResponse = try await secondRuntime.call(
      method: "thread/loaded/list",
      params: .object([:])
    )
    #expect(secondResponse.objectValue?["data"] == .array([.string("thread_fixture")]))
    let secondPID = try await fixture.waitForLatestPID(count: 2)
    #expect(firstPID != secondPID)
    #expect(processExists(secondPID))

    await secondRuntime.shutdown()

    #expect(await waitForProcessExit(secondPID))
    #expect(await waitForFileRemoval(fixture.leaseDirectory))
  }

  @Test
  func testConcurrentFirstRequestsShareOneRuntimeGeneration() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let runtime = fixture.makeRuntime()

    async let first = runtime.call(method: "thread/loaded/list", params: .object([:]))
    async let second = runtime.call(method: "thread/loaded/list", params: .object([:]))
    _ = try await (first, second)

    _ = try await fixture.waitForLatestPID(count: 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(try fixture.processIDs().count == 1)

    await runtime.shutdown()
  }

  @Test
  func testOfficialGoalLifecycleUsesStableAppServerProtocol() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let runtime = fixture.makeRuntime()
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))

    let set = try await runtime.call(
      method: "thread/goal/set",
      params: .object([
        "threadId": .string("thread_fixture"),
        "objective": .string("Pass every acceptance criterion."),
        "status": .string("active"),
        "tokenBudget": .number(50_000),
      ])
    )
    #expect(set.objectValue?["goal"]?.objectValue?["threadId"] == .string("thread_fixture"))
    #expect(set.objectValue?["goal"]?.objectValue?["status"] == .string("active"))
    #expect(set.objectValue?["goal"]?.objectValue?["tokenBudget"] == .number(50_000))

    let get = try await runtime.call(
      method: "thread/goal/get",
      params: .object(["threadId": .string("thread_fixture")])
    )
    #expect(
      get.objectValue?["goal"]?.objectValue?["objective"]
        == .string("Pass every acceptance criterion.")
    )
    #expect(get.objectValue?["goal"]?.objectValue?["tokensUsed"] == .number(1_250))

    let clear = try await runtime.call(
      method: "thread/goal/clear",
      params: .object(["threadId": .string("thread_fixture")])
    )
    #expect(clear.objectValue?["cleared"] == .bool(true))

    await runtime.shutdown()
  }

  @Test
  func testTimeoutRetirementReapsWithinEndToEndDeadline() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try Data().write(to: fixture.hangRequestsFile)
    let database = try CodexDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(requestTimeoutSeconds: 4, database: database)
    let clock = ContinuousClock()
    let started = clock.now

    await assertThrowsErrorAsync(
      try await runtime.call(method: "thread/loaded/list", params: .object([:]))
    )

    let elapsed = started.duration(to: clock.now)
    #expect(elapsed < .seconds(6))

    let secondPID = try await fixture.waitForLatestPID(count: 2)
    let processIDs = try fixture.processIDs()
    #expect(processIDs.count == 2)
    #expect(await processIDs.asyncAllSatisfy(waitForProcessExit))
    #expect(!processExists(secondPID))
    #expect(!FileManager.default.fileExists(atPath: fixture.leaseDirectory.path))
    let recoverableStatus = await runtime.status().objectValue
    #expect(recoverableStatus?["runtime_state"] == .string("running"))
    #expect(recoverableStatus?["shutdown_reason"] == .null)
    #expect(
      recoverableStatus?["last_request_failure"]?.objectValue?["kind"]
        == .string("request_timeout")
    )
    let recoverableReceipts = try database.codexRuntimeLeases(limit: 10)
    let recoverableReceipt = try #require(
      recoverableReceipts.first { $0.id == runtime.runtimeID })
    #expect(recoverableReceipt.shutdownReason == nil)
    #expect(recoverableReceipt.lastRequestFailure?.kind == "request_timeout")

    await runtime.shutdown()
    let stoppedReceipts = try database.codexRuntimeLeases(limit: 10)
    let stoppedReceipt = try #require(stoppedReceipts.first { $0.id == runtime.runtimeID })
    #expect(stoppedReceipt.runtimeState == "stopped")
    #expect(stoppedReceipt.shutdownReason == "requested")
  }

  @Test
  func testConcurrentRequestsRemainRunningUntilEveryRequestCompletes() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try Data().write(to: fixture.delayLoadedThreadsFile)
    // Keep the retry boundary above the fixture's two serialized one-second replies;
    // this test observes request accounting rather than timeout retirement.
    let runtime = fixture.makeRuntime(requestTimeoutSeconds: 10)

    async let first = runtime.call(method: "thread/loaded/list", params: .object([:]))
    try await waitUntilRuntimeCondition {
      await runtime.status().objectValue?["current_request_count"] == .number(1)
    }
    async let second = runtime.call(method: "thread/loaded/list", params: .object([:]))
    try await waitUntilRuntimeCondition {
      await runtime.status().objectValue?["current_request_count"] == .number(2)
    }

    let concurrentStatus = await runtime.status().objectValue
    #expect(concurrentStatus?["current_request_state"] == .string("running"))
    #expect(concurrentStatus?["current_request_count"] == .number(2))
    _ = try await (first, second)
    let completedStatus = await runtime.status().objectValue
    #expect(completedStatus?["current_request_state"] == .string("idle"))
    #expect(completedStatus?["current_request_count"] == .number(0))

    await runtime.shutdown()
  }

  @Test
  func testConnectionStartupIsBoundedByEndToEndDeadline() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try Data().write(to: fixture.hangInitializeFile)
    let runtime = fixture.makeRuntime(requestTimeoutSeconds: 1)
    let clock = ContinuousClock()
    let started = clock.now

    await assertThrowsErrorAsync(
      try await runtime.call(method: "thread/loaded/list", params: .object([:]))
    )

    let elapsed = started.duration(to: clock.now)
    #expect(elapsed < .seconds(3))
    let processID = try await fixture.waitForLatestPID(count: 1)
    #expect(await waitForProcessExit(processID))
    #expect(!FileManager.default.fileExists(atPath: fixture.leaseDirectory.path))
    await runtime.shutdown()
  }

  @Test
  func testApprovalBrokerPersistsRedactsAndApprovesOnce() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureFileApproval(
      grantRoot: fixture.directory.path,
      reason: "token=fixture-secret"
    )
    let database = try CodexDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(database: database)
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))

    let pending = try await waitForPendingApproval(runtime)
    #expect(pending.kind == .fileChange)
    #expect(
      pending.details.objectValue?["reason"] == .string("token=[REDACTED]")
    )
    let response = try await runtime.respondToApproval(
      id: pending.id,
      response: .object(["decision": .string("accept")])
    )
    #expect(
      response.objectValue?["approval"]?.objectValue?["state"] == .string("approved")
    )
    #expect(try await fixture.waitForApprovalResponse().contains("accept"))
    #expect(try database.codexApproval(id: pending.id)?.state == .approved)

    await runtime.shutdown()
  }

  @Test
  func testApprovalBrokerDeniesMalformedDecisionAndTimesOut() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureFileApproval(grantRoot: fixture.directory.path)
    let database = try CodexDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(
      requestTimeoutSeconds: 3,
      approvalTimeoutSeconds: 1,
      database: database
    )
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))
    let pending = try await waitForPendingApproval(runtime)

    await assertThrowsErrorAsync(
      try await runtime.respondToApproval(
        id: pending.id, response: .object(["decision": .string("allow_forever")]))
    )

    let timedOut = try await waitForApprovalState(
      runtime,
      approvalID: pending.id,
      state: .timedOut
    )
    #expect(timedOut.resolutionReason == "Approval deadline expired.")
    #expect(try await fixture.waitForApprovalResponse().contains("cancel"))
    #expect(try database.codexApproval(id: pending.id)?.state == .timedOut)
    let released = try await CodexThreadHandoffService.release(
      threadID: "thread_fixture",
      workspaceID: "fixture-workspace",
      mode: .graceful,
      interruptActiveTurn: false,
      database: database
    )
    #expect(released.objectValue?["externally_claimable"] == .bool(true))
  }

  @Test
  func testApprovalTimeoutResponseFailureBecomesTerminal() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureFileApproval(grantRoot: fixture.directory.path)
    try Data().write(to: fixture.closeInputAfterApprovalRequestFile)
    let database = try CodexDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(
      requestTimeoutSeconds: 10,
      approvalTimeoutSeconds: 1,
      database: database
    )
    let requestTask = Task {
      try? await runtime.call(method: "thread/loaded/list", params: .object([:]))
    }
    let pending = try await waitForPendingApproval(runtime)

    let failed = try await waitForApprovalState(
      runtime,
      approvalID: pending.id,
      state: .failed
    )
    #expect(failed.decision == .string("cancel"))
    #expect(failed.resolutionReason?.contains("could not be delivered") == true)
    #expect(try database.codexApproval(id: pending.id)?.state == .failed)
    #expect(
      try await runtime.approvals(state: CodexApprovalState.pending.rawValue, limit: 10)
        .objectValue?["approvals"] == .array([])
    )
    _ = await requestTask.value

    await runtime.shutdown()
  }

  @Test
  func testNativeApprovalCanAuthorizeOutsideInitialDirectory() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureFileApproval(grantRoot: "/tmp/explicit-native-grant")
    let runtime = fixture.makeRuntime(database: try CodexDatabase(inMemory: ()))
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))
    let pending = try await waitForPendingApproval(runtime)
    #expect(pending.state == .pending)
    let result = try await runtime.respondToApproval(
      id: pending.id,
      response: .object(["decision": .string("acceptForSession")]))
    #expect(result.objectValue?["approval"]?.objectValue?["state"] == .string("approved"))
    #expect(try await fixture.waitForApprovalResponse().contains("acceptForSession"))
    await runtime.shutdown()
  }

  @Test
  func testApprovalBrokerIsolatesWorkspacesAndRoutesToOwningRuntime() async throws {
    let owningFixture = try AppServerProcessFixture()
    defer { owningFixture.remove() }
    try owningFixture.configureFileApproval(grantRoot: owningFixture.directory.path)
    let database = try CodexDatabase(inMemory: ())
    let owningRuntime = owningFixture.makeRuntime(
      database: database,
      workspaceID: "workspace-a"
    )
    _ = try await owningRuntime.call(method: "thread/loaded/list", params: .object([:]))
    let pending = try await waitForPendingApproval(owningRuntime)

    let isolatedFixture = try AppServerProcessFixture()
    defer { isolatedFixture.remove() }
    let isolatedRuntime = isolatedFixture.makeRuntime(
      database: database,
      workspaceID: "workspace-b"
    )
    let isolatedList = try await isolatedRuntime.approvals(state: nil, limit: 10)
    #expect(isolatedList.objectValue?["approvals"] == .array([]))
    await assertThrowsErrorAsync(try await isolatedRuntime.approval(id: pending.id))
    await assertThrowsErrorAsync(
      try await isolatedRuntime.respondToApproval(
        id: pending.id, response: .object(["decision": .string("accept")]))
    )

    let routingFixture = try AppServerProcessFixture()
    defer { routingFixture.remove() }
    let routingRuntime = routingFixture.makeRuntime(
      database: database,
      workspaceID: "workspace-a"
    )
    let routed = try await routingRuntime.respondToApproval(
      id: pending.id,
      response: .object(["decision": .string("accept")])
    )
    #expect(routed.objectValue?["approval"]?.objectValue?["state"] == .string("approved"))
    #expect(try await owningFixture.waitForApprovalResponse().contains("accept"))

    await routingRuntime.shutdown()
    await isolatedRuntime.shutdown()
    await owningRuntime.shutdown()
  }

  @Test
  func testApprovalBrokerHandlesEverySupportedNativeApprovalKind() async throws {
    let cases: [(CodexApprovalKind, String, JSONValue, JSONValue)] = [
      (
        .commandExecution,
        "item/commandExecution/requestApproval",
        .object([
          "command": .string("git status"),
          "cwd": .string("__WORKSPACE__"),
          "itemId": .string("item-command"),
          "reason": .string("Inspect repository status."),
          "startedAtMs": .number(1),
          "threadId": .string("thread_fixture"),
          "turnId": .string("turn-command"),
        ]),
        .object(["decision": .string("accept")])
      ),
      (
        .fileChange,
        "item/fileChange/requestApproval",
        .object([
          "grantRoot": .string("__WORKSPACE__"),
          "itemId": .string("item-file"),
          "reason": .string("Write a fixture file."),
          "startedAtMs": .number(1),
          "threadId": .string("thread_fixture"),
          "turnId": .string("turn-file"),
        ]),
        .object(["decision": .string("acceptForSession")])
      ),
      (
        .permissions,
        "item/permissions/requestApproval",
        .object([
          "cwd": .string("__WORKSPACE__"),
          "itemId": .string("item-permissions"),
          "permissions": .object([
            "fileSystem": .object([
              "read": .array([.string("__WORKSPACE__")]),
              "write": .array([.string("__WORKSPACE__")]),
            ])
          ]),
          "reason": .string("Use the registered workspace."),
          "startedAtMs": .number(1),
          "threadId": .string("thread_fixture"),
          "turnId": .string("turn-permissions"),
        ]),
        .object(["decision": .string("acceptForSession")])
      ),
      (
        .applyPatch,
        "applyPatchApproval",
        .object([
          "callId": .string("call-patch"),
          "conversationId": .string("thread_fixture"),
          "fileChanges": .object([
            "__WORKSPACE__/approved.txt": .object([
              "content": .string("approved\n"),
              "type": .string("add"),
            ])
          ]),
          "grantRoot": .string("__WORKSPACE__"),
          "reason": .string("Apply a reviewed patch."),
        ]),
        .object(["decision": .string("accept")])
      ),
      (
        .execCommand,
        "execCommandApproval",
        .object([
          "callId": .string("call-exec"),
          "command": .array([.string("/usr/bin/git"), .string("status")]),
          "conversationId": .string("thread_fixture"),
          "cwd": .string("__WORKSPACE__"),
          "parsedCmd": .array([
            .object([
              "cmd": .string("git status"),
              "type": .string("unknown"),
            ])
          ]),
          "reason": .string("Inspect repository status."),
        ]),
        .object(["decision": .string("accept")])
      ),
    ]

    for (kind, method, template, responseTemplate) in cases {
      let fixture = try AppServerProcessFixture()
      do {
        let params = replaceWorkspacePlaceholder(template, with: fixture.directory.path)
        try fixture.configureApproval(method: method, params: params)
        let database = try CodexDatabase(inMemory: ())
        let runtime = fixture.makeRuntime(database: database)
        _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))

        let pending = try await waitForPendingApproval(runtime)
        #expect(pending.kind == kind)
        let nativeResponse: JSONValue
        switch kind {
        case .permissions:
          nativeResponse = .object([
            "permissions": .object(["network": .object(["enabled": .bool(true)])]),
            "scope": .string("session"),
          ])
        case .applyPatch, .execCommand:
          nativeResponse = .object(["decision": .string("approved")])
        default: nativeResponse = responseTemplate
        }
        let response = try await runtime.respondToApproval(id: pending.id, response: nativeResponse)
        let approval = response.objectValue?["approval"]?.objectValue
        #expect(approval?["state"] == .string("approved"))
        #expect(approval?["response"] == nativeResponse)
        let upstream = try await fixture.waitForApprovalResponse()
        #expect(upstream.contains("\"id\":900"))
        await runtime.shutdown()
      } catch {
        fixture.remove()
        throw error
      }
      fixture.remove()
    }
  }

  @Test
  func testPendingApprovalBecomesInterruptedAndCannotBeReplayedAfterRestart() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureFileApproval(grantRoot: fixture.directory.path)
    let database = try CodexDatabase(inMemory: ())
    let first = fixture.makeRuntime(database: database)
    _ = try await first.call(method: "thread/loaded/list", params: .object([:]))
    let pending = try await waitForPendingApproval(first)

    await first.shutdown()

    let interrupted = try #require(try database.codexApproval(id: pending.id))
    #expect(interrupted.state == .interrupted)
    #expect(interrupted.resolvedAt != nil)
    try? FileManager.default.removeItem(at: fixture.approvalRequestFile)
    let replacement = fixture.makeRuntime(database: database)
    let record = try await replacement.approval(id: pending.id)
      .objectValue?["approval"]?.objectValue
    #expect(record?["state"] == .string("interrupted"))
    await assertThrowsErrorAsync(
      try await replacement.respondToApproval(
        id: pending.id,
        response: .object(["decision": .string("accept")])
      )
    )
    await replacement.shutdown()
  }

  @Test
  func testSeparateDatabaseConnectionPreservesLiveUncoordinatedApproval() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureFileApproval(grantRoot: fixture.directory.path)
    let databasePath = fixture.directory.appendingPathComponent("adapter.sqlite").path
    let database = try CodexDatabase(path: databasePath)
    let owning = fixture.makeRuntime(database: database)
    do {
      _ = try await owning.call(method: "thread/loaded/list", params: .object([:]))
      let pending = try await waitForPendingApproval(owning)
      let reopened = try CodexDatabase(path: databasePath)
      #expect(try reopened.codexApproval(id: pending.id) == pending)
      #expect(try reopened.codexThreadOwnership(threadID: "thread_fixture")?.state == .loaded)
      #expect(try reopened.codexRuntimeLeases().contains { $0.id == owning.runtimeID })

      // A different adapter process sees the durable lease, but not this process-local directory.
      CodexRuntimeDirectory.shared.unregister(id: owning.runtimeID)
      let observer = fixture.makeRuntime(database: reopened)
      do {
        #expect(try reopened.codexApproval(id: pending.id)?.state == .pending)
        let visible = try await observer.approval(id: pending.id)
        #expect(visible.objectValue?["approval"]?.objectValue?["state"] == .string("pending"))
        await assertThrowsErrorAsync(
          try await observer.respondToApproval(
            id: pending.id, response: .object(["decision": .string("accept")])))
        #expect(try reopened.codexApproval(id: pending.id)?.state == .pending)
        #expect(!FileManager.default.fileExists(atPath: fixture.approvalResponseLog.path))
        await observer.shutdown()
        CodexRuntimeDirectory.shared.register(owning, id: owning.runtimeID)
      } catch {
        await observer.shutdown()
        CodexRuntimeDirectory.shared.register(owning, id: owning.runtimeID)
        throw error
      }
      _ = try await owning.respondToApproval(
        id: pending.id, response: .object(["decision": .string("decline")]))
      _ = try await fixture.waitForApprovalResponse()
      #expect(try reopened.codexApproval(id: pending.id)?.state == .denied)
      await owning.shutdown()
      #expect(try reopened.codexThreadOwnership(threadID: "thread_fixture")?.state == .released)
    } catch {
      await owning.shutdown()
      throw error
    }
  }

  @Test
  func testMalformedNativeApprovalIsRecordedAndRejectedBeforeConsent() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureApproval(
      method: "item/fileChange/requestApproval",
      params: .object([
        "grantRoot": .string(fixture.directory.path),
        "reason": .string("token=malformed-secret"),
      ])
    )
    let database = try CodexDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(database: database)
    _ = try? await runtime.call(method: "thread/loaded/list", params: .object([:]))

    var eventKinds: Set<String> = []
    for _ in 0..<500 {
      let events = await runtime.events(afterCursor: 0, maxResults: 100)
      eventKinds = Set(
        (events.objectValue?["events"]?.arrayValue ?? []).compactMap {
          $0.objectValue?["kind"]?.stringValue
        }
      )
      if eventKinds.contains("approval_denied") { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(eventKinds.contains("approval_denied"))
    #expect(
      try database.codexApprovals(workspaceID: "fixture-workspace").allSatisfy {
        $0.state == .denied
      })
    let encodedEvents = try String(
      decoding: JSONEncoder().encode(await runtime.events(afterCursor: 0, maxResults: 100)),
      as: UTF8.self
    )
    #expect(!encodedEvents.contains("malformed-secret"))
    await runtime.shutdown()
  }

  @Test
  func testMCPElicitationIsSurfacedRedactedAndResolvedByCaller() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureElicitation(message: "Use token=fixture-secret to continue")
    let runtime = fixture.makeRuntime()
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))

    let request = try await waitForInteractiveRequest(runtime, kind: "mcp_elicitation")
    #expect(
      request.payload.objectValue?["params"]?.objectValue?["message"]
        == .string("Use token=[REDACTED] to continue")
    )
    _ = try await runtime.respond(
      requestID: request.id,
      response: .object(["action": .string("decline")])
    )
    #expect(try await fixture.waitForApprovalResponse().contains("decline"))

    await runtime.shutdown()
  }

  @Test
  func testUserInputRequestAndEventAreRedactedBeforeExposure() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureUserInput(question: "Confirm token=fixture-secret before continuing")
    let runtime = fixture.makeRuntime()
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))

    let request = try await waitForInteractiveRequest(runtime, kind: "user_input")
    let encodedRequest = String(
      decoding: try JSONEncoder().encode(request.payload),
      as: UTF8.self
    )
    #expect(encodedRequest.contains("token=[REDACTED]"))
    #expect(!encodedRequest.contains("fixture-secret"))
    let encodedEvents = String(
      decoding: try JSONEncoder().encode(await runtime.events(afterCursor: 0, maxResults: 100)),
      as: UTF8.self
    )
    #expect(!encodedEvents.contains("fixture-secret"))

    await runtime.shutdown()
  }

  @Test
  func testPendingUserInputRequiresReviewedForceReleaseAndDoesNotStrandRuntime() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureUserInput(question: "Confirm the reviewed release")
    let database = try CodexDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(database: database)
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))
    _ = try await waitForInteractiveRequest(runtime, kind: "user_input")
    let processID = try await fixture.waitForLatestPID(count: 1)

    await assertThrowsErrorAsync(
      try await CodexThreadHandoffService.release(
        threadID: "thread_fixture",
        workspaceID: "fixture-workspace",
        mode: .graceful,
        interruptActiveTurn: false,
        database: database
      )
    )
    #expect(await runtime.hasLiveOwnership(of: "thread_fixture"))

    let released = try await CodexThreadHandoffService.release(
      threadID: "thread_fixture",
      workspaceID: "fixture-workspace",
      mode: .forceComputerMCPOwnedRuntimeOnly,
      interruptActiveTurn: false,
      database: database
    )
    #expect(released.objectValue?["externally_claimable"] == .bool(true))
    #expect(await waitForProcessExit(processID))
    #expect(
      await CodexRuntimeDirectory.shared.runtimeIDs(
        owning: "thread_fixture",
        workspaceID: "fixture-workspace"
      ).isEmpty
    )
  }

  @Test
  func testBoundedRequestClosesTimedOutOperation() async {
    let probe = CodexAppServerTimeoutProbe()

    do {
      _ = try await LiveCodexAppServerRuntime.boundedRequest(
        timeoutSeconds: 1,
        onTimeout: {
          await probe.recordTimeout()
        },
        operation: {
          try await Task.sleep(for: .seconds(60))
          return "late"
        }
      )
      Issue.record("Expected the App Server request to time out.")
    } catch {
      #expect(error.localizedDescription.contains("1-second deadline"))
    }
    #expect(await probe.didTimeOut)
  }

  @Test
  func testBoundedRequestDoesNotWaitForNonCooperativeOperation() async {
    let probe = CodexAppServerNonCooperativeProbe()
    let safetyRelease = Task {
      try? await Task.sleep(for: .seconds(5))
      await probe.release()
    }
    let clock = ContinuousClock()
    let started = clock.now

    do {
      _ = try await LiveCodexAppServerRuntime.boundedRequest(
        timeoutSeconds: 1,
        onTimeout: {},
        operation: {
          await probe.wait()
        }
      )
      Issue.record("Expected the non-cooperative request to time out.")
    } catch {
      #expect(error.localizedDescription.contains("1-second deadline"))
    }

    let elapsed = started.duration(to: clock.now)
    #expect(elapsed < .seconds(3))
    await probe.release()
    safetyRelease.cancel()
  }

  @Test
  func testOnlyTimedOutReadOnlyRequestsReceiveOneRetry() {
    let timeout = LiveCodexAppServerRuntime.RequestTimeoutError(seconds: 30)

    #expect(
      LiveCodexAppServerRuntime.shouldRetryRequest(
        timeout,
        risk: .readOnly,
        attempt: 0,
        maximumAttempts: 2
      ))
    #expect(
      !LiveCodexAppServerRuntime.shouldRetryRequest(
        timeout,
        risk: .readOnly,
        attempt: 1,
        maximumAttempts: 2
      ))
    #expect(
      !LiveCodexAppServerRuntime.shouldRetryRequest(
        timeout,
        risk: .workspaceWrite,
        attempt: 0,
        maximumAttempts: 2
      ))
    #expect(
      !LiveCodexAppServerRuntime.shouldRetryRequest(
        CocoaError(.fileNoSuchFile),
        risk: .readOnly,
        attempt: 0,
        maximumAttempts: 2
      ))
  }

  @Test
  func testReadOnlyRetrySharesTheEndToEndRequestBudget() {
    #expect(
      LiveCodexAppServerRuntime.firstReadOnlyAttemptTimeoutSeconds(
        totalTimeoutSeconds: 30,
        risk: .readOnly
      ) == 15)
    #expect(
      LiveCodexAppServerRuntime.firstReadOnlyAttemptTimeoutSeconds(
        totalTimeoutSeconds: 1,
        risk: .readOnly
      ) == nil)
    #expect(
      LiveCodexAppServerRuntime.firstReadOnlyAttemptTimeoutSeconds(
        totalTimeoutSeconds: 30,
        risk: .workspaceWrite
      ) == nil)
  }

  @Test
  func testAppListUsesOneBoundedLongResponseGeneration() {
    #expect(
      LiveCodexAppServerRuntime.requestTimeoutSeconds(
        method: "app/list",
        configuredTimeoutSeconds: 30,
        appListTimeoutSeconds: 120
      ) == 120)
    #expect(
      LiveCodexAppServerRuntime.requestTimeoutSeconds(
        method: "skills/list",
        configuredTimeoutSeconds: 30,
        appListTimeoutSeconds: 120
      ) == 30)
    #expect(
      LiveCodexAppServerRuntime.firstReadOnlyAttemptTimeoutSeconds(
        totalTimeoutSeconds: 120,
        risk: .readOnly,
        method: "app/list"
      ) == nil)
  }

  @Test(arguments: [
    JSONValue.string("accept"), .string("acceptForSession"), .string("decline"), .string("cancel"),
    .object([
      "acceptWithExecpolicyAmendment": .object([
        "execpolicy_amendment": .array([.string("git"), .string("status")])
      ])
    ]),
    .object([
      "applyNetworkPolicyAmendment": .object([
        "network_policy_amendment": .object([
          "action": .string("deny"), "host": .string("fixture.invalid"),
        ])
      ])
    ]),
  ])
  func nativeApprovalDecisionsAndUnknownResponseFieldsRoundTrip(_ decision: JSONValue) async throws
  {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureApproval(
      method: "item/commandExecution/requestApproval",
      params: .object([
        "command": .string("git status"), "cwd": .string(fixture.directory.path),
        "itemId": .string("item"), "startedAtMs": .number(1),
        "threadId": .string("thread_fixture"), "turnId": .string("turn"),
      ]))
    let database = try CodexDatabase(inMemory: ())
    let runtime = fixture.makeRuntime(database: database)
    do {
      _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))
      let pending = try await waitForPendingApproval(runtime)
      await #expect(throws: (any Error).self) {
        try await runtime.respondToApproval(
          id: pending.id, response: .object(["decision": .string("invalid")]))
      }
      let response: JSONValue = .object([
        "decision": decision, "futureResponseField": .array([.number(42)]),
      ])
      _ = try await runtime.respondToApproval(id: pending.id, response: response)
      let wire = try JSONDecoder().decode(
        JSONValue.self, from: Data(try await fixture.waitForApprovalResponse().utf8))
      #expect(wire.objectValue?["result"] == response)
      #expect(try database.codexApproval(id: pending.id)?.response == response)
      await #expect(throws: (any Error).self) {
        try await runtime.respondToApproval(id: pending.id, response: response)
      }
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func rawRPCPreservesUnknownRequestResponseAndEventFields() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    let notification: JSONValue = .object([
      "method": .string("fixture/future"),
      "params": .object(["nested": .object(["future": .number(42)])]),
      "futureEnvelope": .string("retained"),
    ])
    try JSONEncoder().encode(notification).write(to: fixture.activeTurnOnStartFile)
    let runtime = fixture.makeRuntime()
    do {
      let params: JSONValue = .object([
        "sandbox": .string("danger-full-access"), "approvalPolicy": .string("never"),
        "futureInput": .object(["nested": .array([.number(7)])]),
      ])
      let response = try await runtime.call(method: "thread/start", params: params)
      #expect(response.objectValue?["futureResponse"] == .object(["preserved": .bool(true)]))
      let requests = try fixture.requests().map {
        try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
      }
      let request = try #require(
        requests.first { $0.objectValue?["method"] == .string("thread/start") })
      #expect(
        request.objectValue?["params"]?.objectValue?["futureInput"]
          == params.objectValue?["futureInput"])
      #expect(
        request.objectValue?["params"]?.objectValue?["sandbox"] == .string("danger-full-access"))
      for _ in 0..<100 {
        let events = await runtime.events(afterCursor: 0, maxResults: 100)
        if events.objectValue?["events"]?.arrayValue?.contains(where: {
          $0.objectValue?["payload"] == notification
        }) == true {
          await runtime.shutdown()
          return
        }
        try await Task.sleep(for: .milliseconds(5))
      }
      Issue.record("Unknown notification fields were not preserved.")
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func testNativeParametersAndConfigurationDefaultsArePreserved() async throws {
    let workspace = URL(fileURLWithPath: "/tmp/computer-mcp-workspace")
    let runtime = LiveCodexAppServerRuntime(
      configuration: .init(enabled: true), workspaceURL: workspace)
    let initial = try await runtime.normalize(params: .object([:]), for: method("thread/start"))
    #expect(initial == .object(["cwd": .string(workspace.path)]))
    let explicit: JSONValue = .object([
      "cwd": .string("/tmp/other-directory"),
      "sandbox": .string("danger-full-access"),
      "approvalPolicy": .string("never"),
      "config": .object(["model_provider": .string("personal")]),
      "developerInstructions": .string("Use the project conventions."),
    ])
    #expect(try await runtime.normalize(params: explicit, for: method("thread/start")) == explicit)
    let skills: JSONValue = .object([
      "cwds": .array([.string("/tmp/skills")]),
      "perCwdExtraUserRoots": .object(["/tmp/skills": .array([.string("/tmp/extra")])]),
    ])
    #expect(try await runtime.normalize(params: skills, for: method("skills/list")) == skills)
    #expect(
      try await runtime.normalize(params: .object([:]), for: method("thread/resume"))
        == .object([:]))
    await #expect(throws: CodexToolError.self) {
      try await runtime.normalize(
        params: .object(["ignored": .bool(true)]), for: method("configRequirements/read"))
    }
    await runtime.shutdown()

    let configured = LiveCodexAppServerRuntime(
      configuration: .init(enabled: true, sandbox: .dangerFullAccess, approvalPolicy: .onRequest),
      workspaceURL: workspace)
    let turn = try await configured.normalize(
      params: .object(["threadId": .string("native")]), for: method("turn/start"))
    #expect(turn?.objectValue?["sandboxPolicy"] == .object(["type": .string("dangerFullAccess")]))
    #expect(turn?.objectValue?["approvalPolicy"] == .string("on-request"))
    #expect(turn?.objectValue?["cwd"] == nil)
    await configured.shutdown()
  }

  @Test
  func testTimedOutReadOnlyRequestRunsExactlyOneFreshAttempt() async throws {
    let probe = CodexAppServerRetryProbe()

    let result = try await LiveCodexAppServerRuntime.withRequestRetry(risk: .readOnly) {
      attempt in
      await probe.record(attempt: attempt)
      if attempt == 0 {
        throw LiveCodexAppServerRuntime.RequestTimeoutError(seconds: 30)
      }
      return "recovered"
    }

    #expect(result == "recovered")
    #expect(await probe.attempts == [0, 1])
  }

  @Test
  func testCancelledEndToEndRequestCannotStartRetryGeneration() async throws {
    let probe = CodexAppServerRetryProbe()
    let request = Task {
      try await LiveCodexAppServerRuntime.withRequestRetry(risk: .readOnly) { attempt in
        await probe.record(attempt: attempt)
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(10))
        }
        throw LiveCodexAppServerRuntime.RequestTimeoutError(seconds: 30)
      }
    }

    for _ in 0..<100 {
      if !(await probe.attempts.isEmpty) {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    request.cancel()

    do {
      _ = try await request.value
      Issue.record("Expected cancellation to suppress the retry generation.")
    } catch {
      #expect(error is CancellationError)
    }
    #expect(await probe.attempts == [0])
  }

  @Test
  func testWorkspaceScopedThreadIDRequiresThreadForScopedMethods() throws {
    #expect(
      (try LiveCodexAppServerRuntime.workspaceScopedThreadID(
        method: "thread/list",
        params: .object([:])
      )) == nil)
    #expect(
      (try LiveCodexAppServerRuntime.workspaceScopedThreadID(
        method: "turn/start",
        params: .object(["threadId": .string("thread-1")])
      )) == ("thread-1"))
    expectThrows(
      try LiveCodexAppServerRuntime.workspaceScopedThreadID(
        method: "thread/read",
        params: .object([:])
      )
    )
    expectThrows(
      try LiveCodexAppServerRuntime.validatedThreadID(String(repeating: "x", count: 1_025)))
    expectThrows(try LiveCodexAppServerRuntime.validatedThreadID("thread\nforged"))
  }

  @Test
  func testNativeThreadIdentityIsIndependentOfInitialDirectory() throws {
    let response = createdThreadResponse(id: "thread-created", cwd: "/tmp/other-directory")
    #expect(try LiveCodexAppServerRuntime.createdThreadID(response: response) == "thread-created")
    try LiveCodexAppServerRuntime.validateThreadResponse(
      threadID: "thread-created", response: response)
    expectThrows(
      try LiveCodexAppServerRuntime.validateThreadResponse(threadID: "other", response: response))
    expectThrows(
      try LiveCodexAppServerRuntime.createdThreadID(response: .object(["thread": .object([:])])))
  }

  private func method(_ name: String) throws -> CodexAppServerMethod {
    try #require(CodexAppServerMethodCatalog.method(named: name))
  }

  private func threadResponse(cwd: String) -> JSONValue {
    .object([
      "thread": .object([
        "cwd": .string(cwd)
      ])
    ])
  }

  private func createdThreadResponse(id: String, cwd: String) -> JSONValue {
    .object([
      "thread": .object([
        "id": .string(id),
        "cwd": .string(cwd),
      ])
    ])
  }
}

private func runtimeOwner(workspaceID: String) -> CodexRuntimeOwner {
  CodexRuntimeOwner(
    workspaceID: workspaceID,
    profileID: "fixture-profile",
    caller: "local-mcp",
    transport: "fixture",
    socketConnectionID: "socket-fixture",
    tunnelInstanceID: nil,
    tunnelProfileID: nil
  )
}

struct AppServerProcessFixture {
  let directory: URL
  let executable: URL
  let processLog: URL
  let leaseDirectory: URL
  let hangRequestsFile: URL
  let hangTurnStartFile: URL
  let hangInitializeFile: URL
  let delayLoadedThreadsFile: URL
  let approvalRequestFile: URL
  let approvalResponseLog: URL
  let closeInputAfterApprovalRequestFile: URL
  let activeTurnOnStartFile: URL
  let requestLog: URL
  let loadedThreadsFile: URL
  let loadedThreadsAfterUnsubscribeFile: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    executable = directory.appendingPathComponent("codex-fixture")
    processLog = directory.appendingPathComponent("processes.log")
    leaseDirectory = directory.appendingPathComponent("writer.lease", isDirectory: true)
    hangRequestsFile = directory.appendingPathComponent("hang-requests")
    hangTurnStartFile = directory.appendingPathComponent("hang-turn-start")
    hangInitializeFile = directory.appendingPathComponent("hang-initialize")
    delayLoadedThreadsFile = directory.appendingPathComponent("delay-loaded-threads")
    approvalRequestFile = directory.appendingPathComponent("approval-request.json")
    approvalResponseLog = directory.appendingPathComponent("approval-response.log")
    closeInputAfterApprovalRequestFile = directory.appendingPathComponent(
      "close-input-after-approval-request"
    )
    activeTurnOnStartFile = directory.appendingPathComponent("active-turn-on-start")
    requestLog = directory.appendingPathComponent("requests.log")
    loadedThreadsFile = directory.appendingPathComponent("loaded-threads.json")
    loadedThreadsAfterUnsubscribeFile = directory.appendingPathComponent(
      "loaded-threads-after-unsubscribe.json"
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(
      """
      #!/bin/sh
      fixture_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
      workspace_dir=$(pwd -P)
      lease_dir="$workspace_dir/writer.lease"
      process_log="$fixture_dir/processes.log"

      if ! /bin/mkdir "$lease_dir"; then
        printf '%s\n' 'writer lease is already owned' >&2
        exit 73
      fi

      cleanup() {
        /bin/rmdir "$lease_dir" 2>/dev/null || true
      }
      trap cleanup EXIT
      trap 'exit 0' HUP INT TERM
      printf '%s\n' "$$" >> "$process_log"

      IFS= read -r line || exit 74
      if [ -f "$fixture_dir/hang-initialize" ]; then
        /bin/sleep 60
        exit 76
      fi
      id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\\1/')
      printf '{"id":%s,"result":{"codexHome":"%s","platformFamily":"unix","platformOs":"macos","userAgent":"Codex/computer-mcp-fixture"}}\n' "$id" "$fixture_dir"
      IFS= read -r line || exit 75
      printf '%s\n' "$line" >> "$fixture_dir/requests.log"
      if [ -f "$fixture_dir/approval-request.json" ]; then
        /bin/cat "$fixture_dir/approval-request.json"
        printf '\n'
        if [ -f "$fixture_dir/close-input-after-approval-request" ]; then
          exec 0<&-
          /bin/sleep 10
          exit 0
        fi
      fi
      if [ -f "$fixture_dir/active-turn-on-start" ]; then
        /bin/cat "$fixture_dir/active-turn-on-start"
        printf '\n'
      fi

      while IFS= read -r line; do
        printf '%s\n' "$line" >> "$fixture_dir/requests.log"
        case "$line" in
          *'"id":900'*|*'"id":"900"'*)
            printf '%s\n' "$line" >> "$fixture_dir/approval-response.log"
            continue
            ;;
        esac
        id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\\1/')
        case "$line" in
          *thread*loaded*list*)
            if [ -f "$fixture_dir/hang-requests" ]; then
              continue
            fi
            if [ -f "$fixture_dir/delay-loaded-threads" ]; then
              /bin/sleep 1
            fi
            if [ -f "$fixture_dir/loaded-threads.json" ]; then
              loaded=$(/bin/cat "$fixture_dir/loaded-threads.json")
            else
              case "$workspace_dir" in
                */workspace-one) loaded='["thread_workspace_one"]' ;;
                */workspace-two) loaded='["thread_workspace_two"]' ;;
                *) loaded='["thread_fixture"]' ;;
              esac
            fi
            printf '{"id":%s,"result":{"data":%s,"nextCursor":null}}\n' "$id" "$loaded"
            ;;
          *thread*unsubscribe*)
            if [ -f "$fixture_dir/loaded-threads-after-unsubscribe.json" ]; then
              /bin/cp "$fixture_dir/loaded-threads-after-unsubscribe.json" "$fixture_dir/loaded-threads.json"
            fi
            printf '{"id":%s,"result":{"status":"unsubscribed"}}\n' "$id"
            ;;
          *thread*start*)
            printf '{"id":%s,"result":{"futureResponse":{"preserved":true},"approvalPolicy":"on-request","approvalsReviewer":"user","cwd":"%s","model":"gpt-test","modelProvider":"openai","sandbox":{"type":"dangerFullAccess"},"thread":{"cliVersion":"fixture","createdAt":1,"cwd":"%s","ephemeral":false,"id":"thread_native","modelProvider":"openai","preview":"","sessionId":"session_native","source":"appServer","status":{"type":"idle"},"turns":[],"updatedAt":1}}}\n' "$id" "$workspace_dir" "$workspace_dir"
            ;;
          *turn*interrupt*)
            printf '{"id":%s,"result":{}}\n' "$id"
            ;;
          *turn*start*)
            if [ -f "$fixture_dir/hang-turn-start" ]; then
              continue
            fi
            printf '{"id":%s,"result":{"turn":{"id":"turn_native","items":[],"status":"inProgress"}}}\n' "$id"
            ;;
          *thread*goal*set*)
            printf '{"id":%s,"result":{"goal":{"createdAt":1,"objective":"Pass every acceptance criterion.","status":"active","threadId":"thread_fixture","timeUsedSeconds":30,"tokenBudget":50000,"tokensUsed":1250,"updatedAt":2}}}\n' "$id"
            ;;
          *thread*goal*get*)
            printf '{"id":%s,"result":{"goal":{"createdAt":1,"objective":"Pass every acceptance criterion.","status":"active","threadId":"thread_fixture","timeUsedSeconds":30,"tokenBudget":50000,"tokensUsed":1250,"updatedAt":2}}}\n' "$id"
            ;;
          *thread*goal*clear*)
            printf '{"id":%s,"result":{"cleared":true}}\n' "$id"
            ;;
          *thread*read*)
            printf '{"id":%s,"error":{"code":-32600,"message":"thread not loaded by this fixture runtime"}}\n' "$id"
            ;;
          *)
            printf '{"id":%s,"error":{"code":-32601,"message":"fixture method unavailable"}}\n' "$id"
            ;;
        esac
      done
      """.utf8
    ).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: executable.path
    )
  }

  func makeRuntime(
    requestTimeoutSeconds: Int = CodexConfig().appServerRequestTimeoutSeconds,
    approvalTimeoutSeconds: Int = 300,
    database: CodexDatabase? = nil,
    workspaceID: String? = "fixture-workspace"
  ) -> LiveCodexAppServerRuntime {
    LiveCodexAppServerRuntime(
      configuration: CodexConfig(
        enabled: true,
        executable: executable.path,
        execEnabled: false,
        appServerRequestTimeoutSeconds: requestTimeoutSeconds,
        appServerTerminationGraceMilliseconds: 200,
        appServerKillGraceMilliseconds: 1_000,
        appServerApprovalTimeoutSeconds: approvalTimeoutSeconds,
        approvalPolicy: .onRequest
      ),
      workspaceURL: directory,
      owner: CodexRuntimeOwner(
        workspaceID: workspaceID,
        profileID: "fixture-profile",
        caller: "local-mcp",
        transport: "fixture",
        socketConnectionID: "socket-fixture",
        tunnelInstanceID: nil,
        tunnelProfileID: nil
      ),
      database: database
    )
  }

  func configureFileApproval(grantRoot: String, reason: String? = nil) throws {
    var params: [String: JSONValue] = [
      "grantRoot": .string(grantRoot),
      "itemId": .string("item-fixture"),
      "startedAtMs": .number(1),
      "threadId": .string("thread_fixture"),
      "turnId": .string("turn-fixture"),
    ]
    if let reason {
      params["reason"] = .string(reason)
    }
    try configureApproval(
      method: "item/fileChange/requestApproval",
      params: .object(params)
    )
  }

  func configureApproval(method: String, params: JSONValue) throws {
    let request: JSONValue = .object([
      "id": .number(900),
      "method": .string(method),
      "params": params,
    ])
    try? FileManager.default.removeItem(at: approvalResponseLog)
    try CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
      .encode(request)
      .write(to: approvalRequestFile)
  }

  func configureElicitation(message: String) throws {
    let request: JSONValue = .object([
      "id": .number(900),
      "method": .string("mcpServer/elicitation/request"),
      "params": .object([
        "elicitationId": .string("elicitation-fixture"),
        "message": .string(message),
        "mode": .string("url"),
        "url": .string("https://example.invalid/authorize"),
      ]),
    ])
    try CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
      .encode(request)
      .write(to: approvalRequestFile)
  }

  func configureUserInput(question: String) throws {
    let request: JSONValue = .object([
      "id": .number(900),
      "method": .string("item/tool/requestUserInput"),
      "params": .object([
        "isBlocking": .bool(true),
        "itemId": .string("item-input-fixture"),
        "questions": .array([
          .object([
            "header": .string("Confirm"),
            "id": .string("confirmation"),
            "question": .string(question),
          ])
        ]),
        "threadId": .string("thread_fixture"),
        "turnId": .string("turn-fixture"),
      ]),
    ])
    try CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
      .encode(request)
      .write(to: approvalRequestFile)
  }

  func configureActiveTurnOnStart(
    threadID: String = "thread_fixture",
    turnID: String = "turn_fixture"
  ) throws {
    let notification: JSONValue = .object([
      "method": .string("turn/started"),
      "params": .object([
        "threadId": .string(threadID),
        "turn": .object([
          "id": .string(turnID),
          "items": .array([]),
          "status": .string("inProgress"),
        ]),
      ]),
    ])
    try CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
      .encode(notification)
      .write(to: activeTurnOnStartFile)
  }

  func configureLoadedThreads(
    initial: [String],
    afterUnsubscribe: [String]
  ) throws {
    let encoder = CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
    try encoder.encode(initial).write(to: loadedThreadsFile)
    try encoder.encode(afterUnsubscribe).write(to: loadedThreadsAfterUnsubscribeFile)
  }

  func requests() throws -> [String] {
    guard let value = try? String(contentsOf: requestLog, encoding: .utf8) else { return [] }
    return value.split(whereSeparator: \.isNewline).map(String.init)
  }

  func configureDynamicTool(
    name: String,
    arguments: JSONValue,
    callID: String = "codex-call-fixture"
  ) throws {
    let request: JSONValue = .object([
      "id": .number(900),
      "method": .string("item/tool/call"),
      "params": .object([
        "arguments": arguments,
        "callId": .string(callID),
        "namespace": .string("computer-mcp"),
        "threadId": .string("thread_fixture"),
        "tool": .string(name),
        "turnId": .string("turn-fixture"),
      ]),
    ])
    try CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
      .encode(request)
      .write(to: approvalRequestFile)
  }

  func waitForApprovalResponse() async throws -> String {
    for _ in 0..<500 {
      if let response = try? String(contentsOf: approvalResponseLog, encoding: .utf8),
        response.last?.isNewline == true
      {
        return response
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CodexAppServerProcessTransportError.launchFailed(
      "Timed out waiting for fixture approval response."
    )
  }

  func waitForLatestPID(count: Int) async throws -> Int32 {
    for _ in 0..<500 {
      let ids = try processIDs()
      if ids.count >= count, let processID = ids.last {
        return processID
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CodexAppServerProcessTransportError.launchFailed(
      "Timed out waiting for fixture process generation \(count)."
    )
  }

  func processIDs() throws -> [Int32] {
    guard let contents = try? String(contentsOf: processLog, encoding: .utf8) else {
      return []
    }
    return contents.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private func waitUntilRuntimeCondition(
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  for _ in 0..<500 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw CodexAppServerProcessTransportError.launchFailed(
    "Timed out waiting for Codex runtime state."
  )
}

private func waitForPendingApproval(
  _ runtime: LiveCodexAppServerRuntime
) async throws -> CodexApprovalRecord {
  try await waitForApprovalState(runtime, state: .pending)
}

private func replaceWorkspacePlaceholder(_ value: JSONValue, with workspace: String) -> JSONValue {
  switch value {
  case .string(let string):
    return .string(string.replacingOccurrences(of: "__WORKSPACE__", with: workspace))
  case .array(let values):
    return .array(values.map { replaceWorkspacePlaceholder($0, with: workspace) })
  case .object(let object):
    return .object(
      Dictionary(
        uniqueKeysWithValues: object.map { key, value in
          (
            key.replacingOccurrences(of: "__WORKSPACE__", with: workspace),
            replaceWorkspacePlaceholder(value, with: workspace)
          )
        }
      )
    )
  case .number, .bool, .null:
    return value
  }
}

private struct InteractiveRequestFixture {
  let id: String
  let payload: JSONValue
}

private func waitForInteractiveRequest(
  _ runtime: LiveCodexAppServerRuntime,
  kind: String
) async throws -> InteractiveRequestFixture {
  for _ in 0..<500 {
    let response = await runtime.pendingRequests()
    for value in response.objectValue?["requests"]?.arrayValue ?? []
    where value.objectValue?["kind"] == .string(kind) {
      if let id = value.objectValue?["request_id"]?.stringValue,
        let payload = value.objectValue?["request"]
      {
        return InteractiveRequestFixture(id: id, payload: payload)
      }
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw CodexApprovalBrokerError.unknown(kind)
}

private func waitForLatestApproval(
  _ runtime: LiveCodexAppServerRuntime
) async throws -> CodexApprovalRecord {
  for _ in 0..<500 {
    let response = try await runtime.approvals(state: nil, limit: 10)
    if let value = response.objectValue?["approvals"]?.arrayValue?.first {
      let data = try JSONEncoder().encode(value)
      return try JSONDecoder().decode(CodexApprovalRecord.self, from: data)
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw CodexApprovalBrokerError.unknown("fixture")
}

private func waitForApprovalState(
  _ runtime: LiveCodexAppServerRuntime,
  approvalID: String? = nil,
  state: CodexApprovalState
) async throws -> CodexApprovalRecord {
  for _ in 0..<500 {
    let response = try await runtime.approvals(state: state.rawValue, limit: 10)
    let values = response.objectValue?["approvals"]?.arrayValue ?? []
    for value in values {
      let data = try JSONEncoder().encode(value)
      let record = try JSONDecoder().decode(CodexApprovalRecord.self, from: data)
      if approvalID == nil || record.id == approvalID {
        return record
      }
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw CodexApprovalBrokerError.unknown(approvalID ?? "fixture")
}

extension Array where Element == Int32 {
  fileprivate func asyncAllSatisfy(
    _ predicate: (Int32) async -> Bool
  ) async -> Bool {
    for element in self where !(await predicate(element)) {
      return false
    }
    return true
  }
}

private func waitForProcessExit(_ processID: Int32) async -> Bool {
  for _ in 0..<500 {
    if !processExists(processID) {
      return true
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return false
}

private func waitForFileRemoval(_ url: URL) async -> Bool {
  for _ in 0..<500 {
    if !FileManager.default.fileExists(atPath: url.path) {
      return true
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return false
}

private func processExists(_ processID: Int32) -> Bool {
  errno = 0
  if kill(processID, 0) == 0 {
    return true
  }
  return errno != ESRCH
}

private actor CodexAppServerTimeoutProbe {
  private(set) var didTimeOut = false

  func recordTimeout() {
    didTimeOut = true
  }
}

private actor CodexAppServerRetryProbe {
  private(set) var attempts: [Int] = []

  func record(attempt: Int) {
    attempts.append(attempt)
  }
}

private actor CodexAppServerNonCooperativeProbe {
  private var continuation: CheckedContinuation<String, Never>?
  private var released = false

  func wait() async -> String {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if released {
          continuation.resume(returning: "released")
        } else {
          self.continuation = continuation
        }
      }
    } onCancel: {
      // This fixture deliberately ignores cancellation to model an RPC that is
      // still blocked while its transport is being retired.
    }
  }

  func release() {
    released = true
    continuation?.resume(returning: "released")
    continuation = nil
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  expectedCode: String? = nil,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    Issue.record("Expected expression to throw.")
  } catch {
    if let expectedCode {
      #expect(String(describing: error).contains("[\(expectedCode)]"))
    }
  }
}
