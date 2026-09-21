import Foundation
import MCP
import Testing

@testable import CodexAdapter

@Suite(.serialized)
final class CodexOperationalDiagnosticsTests {
  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func mcpDiagnosticReadUsesHostSnapshotAndPropagatesDenial(_ denied: Bool) async throws {
    let owner = CodexRuntimeOwner(
      workspaceID: UUID().uuidString, profileID: "observer", caller: "local-mcp",
      transport: "fixture", socketConnectionID: nil, tunnelInstanceID: nil, tunnelProfileID: nil)
    let host = HostDiagnosticsStub(
      value: .init(owner: owner, recentToolAudits: []), denied: denied)
    let provider = CodexAppServerProvider(
      appServer: FakeAppServerRuntime(), owner: owner, database: try CodexDatabase(inMemory: ()),
      workspaceURL: URL(fileURLWithPath: "/tmp"), recentThreadReader: nil,
      localControlAllowed: false, configuredSandbox: .readOnly,
      hostDiagnostics: host)
    let pair = await InMemoryTransport.createConnectedPair()
    try await pair.server.connect()
    let serving = Task {
      try await CodexAdapterServer.serve(transport: pair.server, appServer: provider)
    }
    let client = MCP.Client(name: "diagnostics-fixture", version: "1")
    do {
      _ = try await client.connect(transport: pair.client)
      let pending = try await client.send(
        MCP.CallTool.request(
          .init(
            name: "codex.diagnostics.snapshot", arguments: ["limit": .int(1)])))
      let response = try await pending.value
      #expect(response.isError == denied)
      if !denied {
        let result = try #require(response.structuredContent?.objectValue?["result"]?.objectValue)
        #expect(result["host_diagnostics_available"] == .bool(true))
        #expect(result["recent_tool_audits"] == .array([]))
        #expect(
          result["codex_configuration"]?.objectValue?["sandbox_override"] == .string("read-only")
        )
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

  @Test
  func absentHostDataIsUnknownRatherThanEmptyOrDefaultPermission() async throws {
    let snapshot = try await CodexOperationalDiagnostics.snapshot(
      database: CodexDatabase(inMemory: ()), owner: nil, configuredSandbox: .readOnly, limit: 10)
    #expect(snapshot.objectValue?["host_diagnostics_available"] == .bool(false))
    #expect(snapshot.objectValue?["recent_tool_audits"] == .null)
    let configuration = try #require(snapshot.objectValue?["codex_configuration"]?.objectValue)
    #expect(configuration["sandbox_override"] == .string("read-only"))
    #expect(configuration["unspecified_values"] == .string("inherited_from_codex"))
  }

  @Test(arguments: ["owner", "workspace", "limit"])
  func hostSnapshotMustMatchInvocationScopeAndBound(_ mismatch: String) async throws {
    func owner(profileID: String) -> CodexRuntimeOwner {
      .init(
        workspaceID: "workspace-1", profileID: profileID, caller: "local-mcp",
        transport: "fixture", socketConnectionID: "connection-1",
        tunnelInstanceID: nil, tunnelProfileID: nil)
    }
    let snapshot = CodexHostDiagnosticSnapshot(
      owner: owner(profileID: mismatch == "owner" ? "profile-2" : "profile-1"),
      recentToolAudits: Array(
        repeating: .object([
          "workspace_id": .string(mismatch == "workspace" ? "workspace-2" : "workspace-1")
        ]),
        count: mismatch == "limit" ? 2 : 1))
    await #expect(throws: CodexToolError.self) {
      try await CodexOperationalDiagnostics.snapshot(
        database: CodexDatabase(inMemory: ()), owner: owner(profileID: "profile-1"),
        configuredSandbox: .workspaceWrite, limit: 1, hostSnapshot: snapshot)
    }
  }

  @Test
  func testSnapshotCorrelatesWorkspaceStateAndProducesRecoveryFindings() async throws {
    let database = try CodexDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 10_000)
    let owner = CodexRuntimeOwner(
      workspaceID: "workspace-1",
      profileID: "profile-1",
      caller: "local-mcp",
      transport: "gateway_socket",
      socketConnectionID: "socket-1",
      tunnelInstanceID: "tunnel-1",
      tunnelProfileID: "tunnel-profile-1"
    )
    try database.saveCodexRuntimeLease(
      CodexRuntimeLeaseRecord(
        id: "runtime-stale",
        owner: owner,
        workspacePath: "/tmp/workspace-1",
        state: "failed",
        process: CodexAppServerProcessSnapshot(
          state: .failed,
          processID: Int32.max - 20,
          supervisorProcessID: Int32.max - 21,
          parentProcessID: 1,
          processGroupID: Int32.max - 20,
          startedAt: now.addingTimeInterval(-120),
          stoppedAt: now.addingTimeInterval(-60),
          exitCode: nil,
          signal: 9,
          terminationEscalated: true,
          lastError: "token=[REDACTED]"
        ),
        createdAt: now.addingTimeInterval(-120),
        updatedAt: now.addingTimeInterval(-60),
        shutdownReason: "consumer_failure",
        cleanedAt: nil
      )
    )
    try database.saveCodexThreadOwnership(
      CodexThreadOwnershipRecord(
        threadID: "thread-owned",
        workspaceID: "workspace-1",
        workspacePath: "/tmp/workspace-1",
        runtimeID: "runtime-stale",
        state: .loaded,
        createdAt: now.addingTimeInterval(-120),
        updatedAt: now.addingTimeInterval(-60)
      )
    )
    try database.saveCodexApproval(
      CodexApprovalRecord(
        id: "approval-1",
        upstreamRequestID: "n:1",
        kind: .commandExecution,
        risk: .workspaceWrite,
        state: .pending,
        workspaceID: "workspace-1",
        workspacePath: "/tmp/workspace-1",
        runtimeID: "runtime-stale",
        threadID: "thread-1",
        turnID: "turn-1",
        itemID: "item-1",
        correlationID: "correlation-1",
        socketConnectionID: "socket-1",
        tunnelInstanceID: "tunnel-1",
        details: .object(["command": .string("git status")]),
        proposedAction: .object(["kind": .string("command_execution")]),
        createdAt: now.addingTimeInterval(-30),
        expiresAt: now.addingTimeInterval(300),
        resolvedAt: nil,
        decision: nil,
        scope: nil,
        resolutionReason: nil
      )
    )
    var run = try CodexOrchestrationEngine.create(
      database: database,
      workspaceID: "workspace-1",
      workspacePath: "/tmp/workspace-1",
      parentRunID: nil,
      threadID: "thread-1",
      officialGoalLinked: true,
      objective: "Ship the complete batch.",
      acceptedScope: ["runtime", "website"],
      phase: "implementation",
      acceptanceCriteria: ["All gates pass"],
      requiredEvidenceKinds: ["test"],
      budget: CodexRunBudget(
        maxTurns: 10,
        maxDurationSeconds: 3_600,
        maxNoProgressSeconds: 60,
        maxRepeatedFailures: 3
      )
    )
    for _ in 0..<3 {
      run = try CodexOrchestrationEngine.record(
        database: database,
        workspaceID: "workspace-1",
        runID: run.id,
        expectedRevision: run.revision,
        event: CodexRunEvent(
          kind: .planning,
          summary: "Planning without repository progress.",
          phase: nil,
          nextAction: "Inspect the blocker.",
          turnID: nil,
          approvalID: nil,
          commandID: nil,
          criterionID: nil,
          evidenceKind: nil,
          requestID: "request-run",
          correlationID: "correlation-run",
          artifact: nil,
          repositoryDigest: nil,
          failureFingerprint: nil,
          externalBlocker: false
        ),
        now: now
      )
    }
    let hostSnapshot = CodexHostDiagnosticSnapshot(
      owner: owner,
      recentToolAudits: [
        .object([
          "id": .string("audit-git"),
          "occurred_at": .string(ISO8601DateFormatter().string(from: now)),
          "request_id": .string("request-git"),
          "mcp_request_id": .string("mcp-request-git"),
          "invocation_id": .string("invocation-git"),
          "ticket_id": .string("ticket-git"),
          "transport": .string("gateway_socket"),
          "socket_connection_id": .string("socket-1"),
          "tunnel_instance_id": .string("tunnel-1"),
          "tunnel_profile_id": .string("tunnel-profile-1"),
          "profile_id": .string("profile-1"),
          "workspace_id": .string("workspace-1"),
          "capability_id": .string("git.commit"),
          "decision": .string("allowed"),
          "input_digest": .string("sha256:input"),
          "output_digest": .string("sha256:output"),
        ]),
        .object([
          "id": .string("audit-tool"),
          "occurred_at": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))),
          "request_id": .string("token=diagnostic-secret"),
          "mcp_request_id": .string(String(repeating: "m", count: 2_048)),
          "profile_id": .string("profile-1"),
          "workspace_id": .string("workspace-1"),
          "capability_id": .string("tools.list"),
          "decision": .string("allowed"),
          "input": .string("unprojected command input"),
          "output": .string("unprojected command output"),
        ]),
      ])

    let snapshot = try await CodexOperationalDiagnostics.snapshot(
      database: database,
      owner: owner,
      configuredSandbox: .workspaceWrite,
      limit: 100,
      hostSnapshot: hostSnapshot,
      now: now
    )
    let object = try #require(snapshot.objectValue)
    let summary = try #require(object["summary"]?.objectValue)
    let findings = object["findings"]?.arrayValue ?? []
    let findingCodes = Set(findings.compactMap { $0.objectValue?["code"]?.stringValue })
    let audits = object["recent_tool_audits"]?.arrayValue ?? []

    #expect(object["persistence_available"] == .bool(true))
    #expect(object["host_diagnostics_available"] == .bool(true))
    #expect(
      object["codex_configuration"]?.objectValue?["sandbox_override"]
        == .string("workspace-write"))
    #expect(object["scope"]?.objectValue?["workspace_id"] == .string("workspace-1"))
    #expect(summary["persisted_runtime_count"] == .number(1))
    #expect(summary["thread_ownership_receipt_count"] == .number(1))
    #expect(summary["pending_approval_count"] == .number(1))
    #expect(summary["active_run_count"] == .number(1))
    #expect(findingCodes.contains("stale_record"))
    #expect(findingCodes.contains("pending_approvals"))
    #expect(findingCodes.contains("run_blocked"))
    #expect(findingCodes.contains("thread_ownership_requires_reconciliation"))
    #expect(object["thread_ownership_receipts"]?.arrayValue?.count == 1)
    #expect(audits.count == 2)
    let gitAudit = try #require(
      audits.first { $0.objectValue?["category"] == .string("git") }
    )
    #expect(gitAudit.objectValue?["request_id"] == .string("request-git"))
    #expect(gitAudit.objectValue?["ticket_id"] == .string("ticket-git"))
    let boundedAudit = try #require(
      audits.first { $0.objectValue?["category"] == .string("tool") }
    )
    #expect(boundedAudit.objectValue?["request_id"] == .string("token=[REDACTED]"))
    #expect(boundedAudit.objectValue?["mcp_request_id"]?.stringValue?.count == 1_024)
    #expect(boundedAudit.objectValue?["input"] == nil)
    #expect(boundedAudit.objectValue?["output"] == nil)
    #expect(object["safety"]?.objectValue?["external_process_control"] == .bool(false))
  }

  @Test
  func testHandoffDiagnosticUsesDurableReleasedOwnershipEvidence() async throws {
    let database = try CodexDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 20_000)
    try database.saveCodexThreadOwnership(
      CodexThreadOwnershipRecord(
        threadID: "thread-released",
        workspaceID: "workspace-1",
        workspacePath: "/tmp/workspace-1",
        runtimeID: "runtime-stopped",
        state: .released,
        createdAt: now.addingTimeInterval(-60),
        updatedAt: now
      )
    )
    try database.saveCodexRuntimeLease(
      CodexRuntimeLeaseRecord(
        id: "runtime-stopped",
        owner: CodexRuntimeOwner(
          workspaceID: "workspace-1",
          profileID: "profile-1",
          caller: "local-mcp",
          transport: "fixture",
          socketConnectionID: nil,
          tunnelInstanceID: nil,
          tunnelProfileID: nil
        ),
        workspacePath: "/tmp/workspace-1",
        state: "stopped",
        process: nil,
        createdAt: now.addingTimeInterval(-60),
        updatedAt: now,
        shutdownReason: "requested",
        cleanedAt: nil
      )
    )

    let result = await CodexThreadHandoffDiagnostics.diagnose(
      threadID: "thread-released",
      observedError: nil,
      workspaceID: "workspace-1",
      database: database
    )

    #expect(result.objectValue?["classification"] == .string("released_persisted"))
    #expect(
      result.objectValue?["persisted_ownership"]?.objectValue?["state"]
        == .string("released")
    )
    #expect(
      result.objectValue?["last_runtime_receipt"]?.objectValue?["state"]
        == .string("stopped")
    )
    #expect(result.objectValue?["external_process_signals_allowed"] == .bool(false))
  }
}

private struct HostDiagnosticsStub: CodexHostDiagnostics {
  let value: CodexHostDiagnosticSnapshot
  let denied: Bool

  func snapshot(limit: Int, now: Date) throws -> CodexHostDiagnosticSnapshot {
    #expect(limit == 1)
    if denied { throw CodexToolError.disabled("Fixture host denied audit access.") }
    return value
  }
}
