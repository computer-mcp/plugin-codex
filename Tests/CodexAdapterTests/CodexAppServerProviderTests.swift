import Foundation
import MCP
import Testing

@testable import CodexAdapter

@Suite(.serialized)
struct CodexAppServerProviderTests {
  @Test(.timeLimit(.minutes(2)))
  func mcpWorkflowUsesOriginalRuntimeAndPersistsRelease() async throws {
    let fixture = try AppServerProcessFixture()
    defer { fixture.remove() }
    try fixture.configureFileApproval(grantRoot: fixture.directory.path)
    try fixture.configureLoadedThreads(initial: ["thread_fixture"], afterUnsubscribe: [])
    let database = try CodexDatabase(
      path: fixture.directory.appendingPathComponent("adapter.sqlite").path)
    let runtime = fixture.makeRuntime(
      database: database, workspaceID: fixture.directory.lastPathComponent)
    let provider = CodexAppServerProvider(
      appServer: runtime, owner: runtime.owner, database: database, workspaceURL: fixture.directory,
      recentThreadReader: nil, readOnly: false, localControlAllowed: true)
    let pair = await InMemoryTransport.createConnectedPair()
    try await pair.server.connect()
    let serving = Task {
      try await CodexAdapterServer.serve(transport: pair.server, appServer: provider)
    }
    let client = MCP.Client(name: "app-server-workflow", version: "1")
    func invoke(_ name: String, _ arguments: [String: MCP.Value] = [:]) async throws -> MCP.Value {
      let pending = try await client.send(
        MCP.CallTool.request(.init(name: name, arguments: arguments)))
      let response = try await pending.value
      try #require(response.isError == false, "\(name): \(response.content)")
      let result = try #require(response.structuredContent?.objectValue?["result"])
      guard case .text(let text, _, _) = response.content.first else {
        throw CodexToolError.executionFailed("Missing MCP text result.")
      }
      #expect(try JSONDecoder().decode(MCP.Value.self, from: Data(text.utf8)) == result)
      return result
    }
    do {
      _ = try await client.connect(transport: pair.client)
      let catalog = try await client.listTools()
      #expect(Set(catalog.tools.map(\.name)).count == catalog.tools.count)
      #expect(
        Set(catalog.tools.map(\.name))
          == Set(provider.tools.map(\.name) + ProtocolTools.definitions.map(\.name)))
      let diagnostics = try await invoke("codex.diagnostics.snapshot", ["limit": .int(10)])
      #expect(diagnostics.objectValue?["persistence_available"] == .bool(true))
      #expect(diagnostics.objectValue?["host_diagnostics_available"] == .bool(false))
      #expect(diagnostics.objectValue?["recent_tool_audits"] == .null)
      let methods = try await invoke("codex.app.methods.list")
      #expect(
        methods.objectValue?["methods"]?.arrayValue?.contains {
          $0.objectValue?["method"] == .string("thread/goal/set")
        } == true)
      _ = try await invoke("codex.app.thread.loaded.list")
      let goal = try await invoke(
        "codex.app.goal.set",
        [
          "thread_id": .string("thread_fixture"),
          "objective": .string("Pass every acceptance criterion."),
          "status": .string("active"), "token_budget": .int(50_000),
        ])
      #expect(goal.objectValue?["goal"]?.objectValue?["tokenBudget"] == .int(50_000))
      _ = try await invoke("codex.app.goal.get", ["thread_id": .string("thread_fixture")])
      _ = try await invoke("codex.app.goal.clear", ["thread_id": .string("thread_fixture")])
      var approvalID: String?
      for _ in 0..<500 {
        let approvals = try await invoke("codex.app.approvals.list", ["state": .string("pending")])
        approvalID =
          approvals.objectValue?["approvals"]?.arrayValue?.first?.objectValue?["id"]?.stringValue
        if approvalID != nil { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      let id = try #require(approvalID)
      _ = try await invoke(
        "codex.app.approvals.respond",
        [
          "approval_id": .string(id), "decision": .string("deny"),
        ])
      _ = try await fixture.waitForApprovalResponse()
      #expect(try database.codexApproval(id: id)?.state == .denied)
      let invalid = try await client.callTool(
        name: "codex.app.thread.start", arguments: ["cwd": .string("/outside")])
      #expect(invalid.isError == true)
      let released = try await invoke(
        "codex.app.thread.release", ["thread_id": .string("thread_fixture")])
      #expect(released.objectValue?["externally_claimable"] == .bool(true))
      #expect(released.objectValue?["goal_preservation"] == .string("persisted-and-unchanged"))
      #expect(try database.codexThreadOwnership(threadID: "thread_fixture")?.state == .released)
      await client.disconnect()
      try await serving.value
      #expect(await runtime.status().objectValue?["runtime_state"] == .string("stopped"))
      #expect(!FileManager.default.fileExists(atPath: fixture.leaseDirectory.path))
    } catch {
      await client.disconnect()
      await pair.server.disconnect()
      _ = try? await serving.value
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func readOnlyAndRemoteBoundariesRejectBeforeDispatch() async throws {
    let provider = CodexAppServerProvider(
      appServer: FakeAppServerRuntime(), owner: nil, database: nil,
      workspaceURL: URL(fileURLWithPath: "/tmp/workspace-1"), recentThreadReader: nil,
      readOnly: true, localControlAllowed: false)
    for name in [
      "codex.app.thread.start", "codex.app.approvals.respond", "codex.run.create",
      "codex.worktree.leases.acquire", "codex.app.runtimes.stop",
    ] {
      await #expect(throws: CodexToolError.self) {
        try await provider.call(name: name, arguments: .object([:]))
      }
    }
    await #expect(throws: CodexToolError.self) {
      try await provider.call(
        name: "codex.app.methods.call",
        arguments: .object(["method": .string("thread/goal/set")]))
    }
    _ = try await provider.call(
      name: "codex.app.methods.call",
      arguments: .object(["method": .string("model/list")]))
    _ = try await provider.call(name: "codex.diagnostics.snapshot", arguments: .object([:]))
    let remote = CodexAppServerProvider(
      appServer: FakeAppServerRuntime(), owner: nil, database: nil,
      workspaceURL: URL(fileURLWithPath: "/tmp/workspace-1"), recentThreadReader: nil,
      readOnly: false, localControlAllowed: false)
    #expect(!remote.tools.contains { $0.name == "codex.app.ownership.reconcile.perform" })
    #expect(makeProvider().tools.contains { $0.name == "codex.app.ownership.reconcile.perform" })
    await #expect(throws: CodexToolError.self) {
      try await remote.call(
        name: "codex.app.ownership.reconcile.perform",
        arguments: .object([
          "confirm_reconciliation": .bool(true), "expected_plan_digest": .string("x"),
        ]))
    }
  }
  @Test
  func testAppMethodCatalogAndTypedCallReturnStructuredEnvelope() async throws {
    let provider = makeProvider()

    let methods = try await provider.callToolAsync(
      name: "codex.app.methods.list",
      arguments: .object([:])
    )
    let methodRows = methods.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["methods"]?.arrayValue
    #expect(
      methodRows?.contains(where: {
        $0.objectValue?["method"]?.stringValue == "thread/start"
      }) == true)
    #expect(
      methodRows?.contains(where: {
        $0.objectValue?["method"]?.stringValue == "account/usage/read"
      }) == true)
    #expect(
      !(methodRows?.contains(where: {
        $0.objectValue?["method"]?.stringValue == "thread/turns/list"
      }) == true))

    let call = try await provider.callToolAsync(
      name: "codex.app.thread.start",
      arguments: .object(["model": .string("gpt-test")])
    )
    let result = call.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue
    #expect((result?["method"]) == (.string("thread/start")))
    #expect((result?["params"]?.objectValue?["model"]) == (.string("gpt-test")))
  }

  @Test
  func testTypedAppToolsMapStableArgumentsWithoutRawParams() async throws {
    let provider = makeProvider()

    let apps = try await provider.callToolAsync(
      name: "codex.app.apps.list",
      arguments: .object([
        "cursor": .string("page-2"),
        "force_refetch": .bool(false),
        "limit": .number(1),
        "thread_id": .string("thread-1"),
      ])
    )
    let appsParams = apps.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["params"]?.objectValue
    #expect(appsParams?["cursor"] == .string("page-2"))
    #expect(appsParams?["forceRefetch"] == .bool(false))
    #expect(appsParams?["limit"] == .number(1))
    #expect(appsParams?["threadId"] == .string("thread-1"))

    let defaultApps = try await provider.callToolAsync(
      name: "codex.app.apps.list",
      arguments: .object([:])
    )
    let defaultAppsParams = defaultApps.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["params"]?.objectValue
    #expect(defaultAppsParams?["forceRefetch"] == .bool(false))
    #expect(defaultAppsParams?["limit"] == .number(20))

    let list = try await provider.callToolAsync(
      name: "codex.app.thread.list",
      arguments: .object([
        "search_term": .string("gateway"),
        "source_kinds": .array([.string("cli"), .string("vscode")]),
      ])
    )
    let listParams = list.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["params"]?.objectValue
    #expect((listParams?["searchTerm"]) == (.string("gateway")))
    #expect((listParams?["sourceKinds"]) == (.array([.string("cli"), .string("vscode")])))

    let turn = try await provider.callToolAsync(
      name: "codex.app.turn.start",
      arguments: .object([
        "thread_id": .string("thread-1"),
        "prompt": .string("Review the implementation."),
        "effort": .string("high"),
      ])
    )
    let turnParams = turn.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["params"]?.objectValue
    #expect((turnParams?["threadId"]) == (.string("thread-1")))
    #expect((turnParams?["effort"]) == (.string("high")))
    #expect(
      (turnParams?["input"]?.arrayValue?.first?.objectValue)
        == (["type": .string("text"), "text": .string("Review the implementation.")]))

    let review = try await provider.callToolAsync(
      name: "codex.app.review.start",
      arguments: .object([
        "thread_id": .string("thread-1"),
        "target": .object(["type": .string("uncommittedChanges")]),
        "delivery": .string("detached"),
      ])
    )
    let reviewParams = review.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["params"]?.objectValue
    #expect((reviewParams?["delivery"]) == (.string("detached")))
    #expect((reviewParams?["target"]) == (.object(["type": .string("uncommittedChanges")])))

    let goal = try await provider.callToolAsync(
      name: "codex.app.goal.set",
      arguments: .object([
        "thread_id": .string("thread-1"),
        "objective": .string("Ship only after acceptance passes."),
        "status": .string("active"),
        "token_budget": .number(100_000),
      ])
    )
    let goalParams = goal.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["params"]?.objectValue
    #expect(goalParams?["threadId"] == .string("thread-1"))
    #expect(goalParams?["objective"] == .string("Ship only after acceptance passes."))
    #expect(goalParams?["status"] == .string("active"))
    #expect(goalParams?["tokenBudget"] == .number(100_000))

    let steer = try await provider.callToolAsync(
      name: "codex.app.turn.steer",
      arguments: .object([
        "thread_id": .string("thread-1"),
        "expected_turn_id": .string("turn-1"),
        "prompt": .string("Run the remaining acceptance checks before stopping."),
        "client_user_message_id": .string("message-1"),
      ])
    )
    let steerParams = steer.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["params"]?.objectValue
    #expect(steerParams?["threadId"] == .string("thread-1"))
    #expect(steerParams?["expectedTurnId"] == .string("turn-1"))
    #expect(steerParams?["clientUserMessageId"] == .string("message-1"))
    #expect(
      steerParams?["input"]?.arrayValue?.first?.objectValue
        == [
          "type": .string("text"),
          "text": .string("Run the remaining acceptance checks before stopping."),
        ]
    )

    let reclaim = try await provider.callToolAsync(
      name: "codex.app.thread.reclaim",
      arguments: .object([
        "thread_id": .string("thread-1"),
        "model": .string("gpt-test"),
      ])
    )
    let reclaimResult = reclaim.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue
    #expect(reclaimResult?["method"] == .string("thread/resume"))
    #expect(reclaimResult?["params"]?.objectValue?["threadId"] == .string("thread-1"))
    #expect(reclaimResult?["params"]?.objectValue?["model"] == .string("gpt-test"))
  }

  @Test
  func testHandoffDiagnosticDoesNotClaimExternalProcessControl() async throws {
    let provider = makeProvider()

    let response = try await provider.callToolAsync(
      name: "codex.app.handoff.diagnose",
      arguments: .object([
        "thread_id": .string("thread-external"),
        "observed_error": .string(
          "opened in another application; Authorization: Bearer handoff-secret"
        ),
      ])
    )
    let result = response.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue

    #expect(result?["classification"] == .string("external_writer_or_unfinished_watchdog"))
    #expect(result?["external_owner_visible"] == .bool(false))
    #expect(result?["external_process_signals_allowed"] == .bool(false))
    #expect(result?["observed_error"]?.stringValue?.contains("[REDACTED]") == true)
    #expect(result?["observed_error"]?.stringValue?.contains("handoff-secret") == false)
    #expect(
      result?["safe_actions"]?.arrayValue?.first?.objectValue?["tool"]
        == .string("codex.app.runtimes.cleanup.preview")
    )
  }

  @Test
  func testAcceptanceRunAndLeaseToolsEnforceWorkspaceWriterOwnership() async throws {
    let database = try CodexDatabase(inMemory: ())
    let provider = CodexAppServerProvider(
      appServer: FakeAppServerRuntime(),
      owner: CodexRuntimeOwner(
        workspaceID: "workspace-1",
        profileID: "profile-1",
        caller: "local-mcp",
        transport: "fixture",
        socketConnectionID: "socket-1",
        tunnelInstanceID: nil,
        tunnelProfileID: nil
      ),
      database: database, workspaceURL: URL(fileURLWithPath: "/tmp/workspace-1"),
      recentThreadReader: nil, readOnly: false, localControlAllowed: true
    )

    let created = try await provider.callToolAsync(
      name: "codex.run.create",
      arguments: .object([
        "objective": .string("Deliver the complete batch."),
        "accepted_scope": .array([.string("runtime"), .string("website")]),
        "acceptance_criteria": .array([.string("All tests pass")]),
        "thread_id": .string("thread-1"),
        "official_goal_linked": .bool(true),
      ])
    )
    let run = created.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue
    let runID = try #require(run?["id"]?.stringValue)
    #expect(run?["officialGoalLinked"] == .bool(true))

    let acquired = try await provider.callToolAsync(
      name: "codex.worktree.leases.acquire",
      arguments: .object([
        "agent_id": .string("agent-1"),
        "thread_id": .string("thread-1"),
        "run_id": .string(runID),
      ])
    )
    let lease = acquired.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue
    let leaseID = try #require(lease?["id"]?.stringValue)

    await assertThrowsErrorAsync(
      try await provider.callToolAsync(
        name: "codex.app.turn.start",
        arguments: .object([
          "thread_id": .string("thread-1"),
          "prompt": .string("Mutate without the lease."),
        ])
      )
    )
    await assertThrowsErrorAsync(
      try await provider.callToolAsync(
        name: "codex.app.apps.list",
        arguments: .object(["limit": .number(101)])
      )
    )
    await assertThrowsErrorAsync(
      try await provider.callToolAsync(
        name: "codex.app.methods.call",
        arguments: .object([
          "method": .string("turn/start"),
          "params": .object([
            "threadId": .string("thread-1"),
            "input": .array([
              .object([
                "type": .string("text"),
                "text": .string("Attempt the generic turn-start bypass."),
              ])
            ]),
          ]),
        ])
      )
    )
    let turn = try await provider.callToolAsync(
      name: "codex.app.turn.start",
      arguments: .object([
        "thread_id": .string("thread-1"),
        "prompt": .string("Continue under the exclusive writer lease."),
        "worktree_lease_id": .string(leaseID),
      ])
    )
    let turnParams = turn.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["params"]?.objectValue
    #expect(turnParams?["threadId"] == .string("thread-1"))
    #expect(turnParams?["worktree_lease_id"] == nil)
  }

  @Test
  func testAcceptanceRunCompletesThroughThePublicToolSurface() async throws {
    let database = try CodexDatabase(inMemory: ())
    let provider = CodexAppServerProvider(
      appServer: FakeAppServerRuntime(),
      owner: CodexRuntimeOwner(
        workspaceID: "workspace-1",
        profileID: "profile-1",
        caller: "local-mcp",
        transport: "fixture",
        socketConnectionID: "socket-1",
        tunnelInstanceID: nil,
        tunnelProfileID: nil
      ),
      database: database, workspaceURL: URL(fileURLWithPath: "/tmp/workspace-1"),
      recentThreadReader: nil, readOnly: false, localControlAllowed: true
    )

    var run = try providerResult(
      await provider.callToolAsync(
        name: "codex.run.create",
        arguments: .object([
          "objective": .string("Deliver one accepted batch."),
          "accepted_scope": .array([.string("implementation"), .string("verification")]),
          "acceptance_criteria": .array([
            .string("Build passes"),
            .string("Tests pass"),
            .string("Worktree is clean"),
          ]),
          "required_evidence_kinds": .array([
            .string("build"), .string("test"), .string("git_status"),
          ]),
        ])
      )
    )
    let runID = try #require(run["id"]?.stringValue)

    run = try providerResult(
      await provider.callToolAsync(
        name: "codex.run.record",
        arguments: runEventArguments(
          runID: runID,
          revision: try revision(of: run),
          event: "turn_started",
          summary: "The implementation turn started.",
          extra: ["turn_id": .string("turn-1")]
        )
      )
    )
    run = try providerResult(
      await provider.callToolAsync(
        name: "codex.run.record",
        arguments: runEventArguments(
          runID: runID,
          revision: try revision(of: run),
          event: "turn_completed",
          summary: "The turn ended; acceptance remains open."
        )
      )
    )
    #expect(run["state"] == .string("active"))
    #expect(
      run["diagnostics"]?.arrayValue?.contains(.string("turn_completed_with_open_acceptance"))
        == true
    )

    run = try providerResult(
      await provider.callToolAsync(
        name: "codex.run.record",
        arguments: runEventArguments(
          runID: runID,
          revision: try revision(of: run),
          event: "approval_pending",
          summary: "A governed mutation needs consent.",
          extra: ["approval_id": .string("approval-1")]
        )
      )
    )
    #expect(run["state"] == .string("paused"))
    run = try providerResult(
      await provider.callToolAsync(
        name: "codex.run.record",
        arguments: runEventArguments(
          runID: runID,
          revision: try revision(of: run),
          event: "approval_resolved",
          summary: "The governed mutation was approved.",
          extra: ["approval_id": .string("approval-1")]
        )
      )
    )

    for (index, kind) in ["build", "test", "git_status"].enumerated() {
      run = try providerResult(
        await provider.callToolAsync(
          name: "codex.run.record",
          arguments: runEventArguments(
            runID: runID,
            revision: try revision(of: run),
            event: "acceptance_passed",
            summary: "Recorded \(kind) evidence.",
            extra: [
              "criterion_id": .string("criterion-\(index + 1)"),
              "evidence_kind": .string(kind),
              "repository_digest": .string("digest-\(index + 1)"),
            ]
          )
        )
      )
    }

    run = try providerResult(
      await provider.callToolAsync(
        name: "codex.run.accept",
        arguments: .object([
          "run_id": .string(runID),
          "expected_revision": .number(Double(try revision(of: run))),
          "worktree_clean": .bool(true),
        ])
      )
    )
    #expect(run["state"] == .string("completed"))
    #expect(
      run["acceptanceCriteria"]?.arrayValue?.allSatisfy {
        $0.objectValue?["state"] == .string("passed")
      } == true)
    #expect(run["evidence"]?.arrayValue?.count == 3)
    #expect(run["terminalReason"]?.stringValue?.contains("explicitly accepted") == true)
  }

  @Test
  func testTypedAppToolsRejectRawParamsAndUnsafeOverrides() async throws {
    let provider = makeProvider()

    await assertThrowsErrorAsync(
      try await provider.callToolAsync(
        name: "codex.app.thread.start",
        arguments: .object(["params": .object([:])])
      )
    )
    await assertThrowsErrorAsync(
      try await provider.callToolAsync(
        name: "codex.app.turn.start",
        arguments: .object([
          "thread_id": .string("thread-1"),
          "prompt": .string("Do it."),
          "cwd": .string("/tmp"),
        ])
      )
    )
  }

  @Test
  func testHighFrequencyAppSchemasAreTypedAndHaveOutputSchema() throws {
    let tools = makeProvider().tools
    let start = try #require(tools.first { $0.name == "codex.app.thread.start" })
    let turn = try #require(tools.first { $0.name == "codex.app.turn.start" })
    let review = try #require(tools.first { $0.name == "codex.app.review.start" })
    let apps = try #require(tools.first { $0.name == "codex.app.apps.list" })

    #expect((start.inputSchema.objectValue?["properties"]?.objectValue?["params"]) == nil)
    #expect(
      (turn.inputSchema.objectValue?["required"])
        == (.array([.string("thread_id"), .string("prompt")])))
    #expect((start.outputSchema) != nil)
    #expect((turn.outputSchema) != nil)
    #expect(
      apps.inputSchema.objectValue?["properties"]?.objectValue?["limit"]?
        .objectValue?["maximum"] == .int(100))
    #expect(
      (review.inputSchema.objectValue?["properties"]?.objectValue?["delivery"]?
        .objectValue?["type"]) == (.string("string")))
    #expect(
      (review.inputSchema.objectValue?["properties"]?.objectValue?["delivery"]?
        .objectValue?["enum"]) == (.array([.string("inline"), .string("detached")])))
  }

  @Test
  func testReviewStartRejectsUnsupportedDelivery() async {
    await assertThrowsErrorAsync(
      try await makeProvider().callToolAsync(
        name: "codex.app.review.start",
        arguments: .object([
          "thread_id": .string("thread-1"),
          "target": .object(["type": .string("uncommittedChanges")]),
          "delivery": .string("somewhere"),
        ])
      )
    )
  }

  private func makeProvider() -> CodexAppServerProvider {
    .init(
      appServer: FakeAppServerRuntime(), owner: nil, database: nil,
      workspaceURL: URL(fileURLWithPath: "/tmp/workspace-1"),
      recentThreadReader: nil, readOnly: false, localControlAllowed: true)
  }
}

struct FakeAppServerRuntime: CodexAppServerRuntimeProtocol {
  let shutdownProbe: CodexProviderShutdownProbe?

  init(shutdownProbe: CodexProviderShutdownProbe? = nil) {
    self.shutdownProbe = shutdownProbe
  }

  func status() async -> JSONValue {
    .object(["path": .string("app")])
  }

  func call(method: String, params: JSONValue?) async throws -> JSONValue {
    .object([
      "path": .string("app"),
      "method": .string(method),
      "params": params ?? .null,
    ])
  }

  func events(afterCursor: Int, maxResults: Int) async -> JSONValue {
    .object([
      "after_cursor": .number(Double(afterCursor)),
      "max_results": .number(Double(maxResults)),
    ])
  }

  func pendingRequests() async -> JSONValue {
    .object(["requests": .array([])])
  }

  func respond(requestID: String, response: JSONValue) async throws -> JSONValue {
    .object(["request_id": .string(requestID), "response": response])
  }

  func shutdown() async {
    await shutdownProbe?.record()
  }
}

actor CodexProviderShutdownProbe {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    Issue.record("Expected expression to throw.")
  } catch {
    // Expected.
  }
}

private func providerResult(_ response: JSONValue) throws -> [String: JSONValue] {
  try #require(
    response.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue
  )
}

private func revision(of run: [String: JSONValue]) throws -> Int {
  Int(try #require(run["revision"]?.numberValue))
}

private func runEventArguments(
  runID: String,
  revision: Int,
  event: String,
  summary: String,
  extra: [String: JSONValue] = [:]
) -> JSONValue {
  .object(
    [
      "run_id": .string(runID),
      "expected_revision": .number(Double(revision)),
      "event": .string(event),
      "summary": .string(summary),
    ].merging(extra) { _, new in new }
  )
}

extension CodexAppServerProvider {
  fileprivate func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    try await JSONValue.encoded(call(name: name, arguments: arguments))
  }
}
