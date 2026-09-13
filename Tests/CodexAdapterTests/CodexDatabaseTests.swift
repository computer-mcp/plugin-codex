import Darwin
import Foundation
import Testing

@testable import CodexAdapter

struct CodexDatabaseTests {
  @Test
  func testPersistsCodexApprovalAndRuntimeOwnershipReceipts() throws {
    let database = try CodexDatabase(inMemory: ())
    let timestamp = Date(timeIntervalSince1970: 2_000)
    let owner = CodexRuntimeOwner(
      workspaceID: "workspace-1",
      profileID: "local-admin",
      caller: "local-mcp",
      transport: "gateway_socket",
      socketConnectionID: "socket-1",
      tunnelInstanceID: nil,
      tunnelProfileID: nil
    )
    let approval = CodexApprovalRecord(
      id: "approval-1",
      upstreamRequestID: "n:1",
      kind: .fileChange,
      risk: .workspaceWrite,
      state: .pending,
      workspaceID: "workspace-1",
      workspacePath: "/tmp/workspace-1",
      runtimeID: "runtime-1",
      threadID: "thread-1",
      turnID: "turn-1",
      itemID: "item-1",
      correlationID: "correlation-1",
      socketConnectionID: "socket-1",
      tunnelInstanceID: nil,
      details: .object(["reason": .string("credential=[REDACTED]")]),
      proposedAction: .object(["kind": .string("file_change")]),
      createdAt: timestamp,
      expiresAt: timestamp.addingTimeInterval(300),
      resolvedAt: nil,
      decision: nil,
      scope: nil,
      resolutionReason: nil
    )
    try database.saveCodexApproval(approval)

    let lease = CodexRuntimeLeaseRecord(
      id: "runtime-1",
      owner: owner,
      workspacePath: "/tmp/workspace-1",
      state: "stopped",
      process: CodexAppServerProcessSnapshot(
        state: .stopped,
        processID: 123,
        supervisorProcessID: 122,
        parentProcessID: 121,
        processGroupID: 123,
        startedAt: timestamp,
        stoppedAt: timestamp.addingTimeInterval(1),
        exitCode: 0,
        signal: nil,
        terminationEscalated: false,
        lastError: nil
      ),
      createdAt: timestamp,
      updatedAt: timestamp.addingTimeInterval(1),
      shutdownReason: "requested",
      cleanedAt: nil
    )
    try database.saveCodexRuntimeLease(lease)

    let ownership = CodexThreadOwnershipRecord(
      threadID: "thread-1",
      workspaceID: "workspace-1",
      workspacePath: "/tmp/workspace-1",
      runtimeID: "runtime-1",
      state: .released,
      createdAt: timestamp,
      updatedAt: timestamp.addingTimeInterval(1)
    )
    try database.saveCodexThreadOwnership(ownership)

    #expect(try database.codexApproval(id: approval.id) == approval)
    #expect(try database.codexApprovals(workspaceID: "workspace-1") == [approval])
    #expect(try database.codexRuntimeLeases() == [lease])
    #expect(try database.codexThreadOwnership(threadID: ownership.threadID) == ownership)
    #expect(try database.codexThreadOwnerships(workspaceID: "workspace-1") == [ownership])
  }

  @Test
  func testStaleOwnershipReconciliationIsReviewedAndNeverSignalsAProcess() throws {
    let database = try CodexDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 5_000)
    let stale = CodexThreadOwnershipRecord(
      threadID: "thread-stale",
      workspaceID: "workspace-1",
      workspacePath: "/tmp/workspace-1",
      runtimeID: "runtime-gone",
      state: .loaded,
      createdAt: now,
      updatedAt: now
    )
    try database.saveCodexThreadOwnership(stale)

    let plan = try CodexThreadOwnershipReconciliation.preview(
      database: database,
      workspaceID: "workspace-1"
    )
    #expect(plan.candidates.map(\.threadID) == [stale.threadID])
    #expect(!plan.signalsSent)
    #expect(!plan.externalStateMutated)
    #expect(try database.codexThreadOwnership(threadID: stale.threadID)?.state == .loaded)

    let result = try CodexThreadOwnershipReconciliation.apply(
      database: database,
      expectedPlanDigest: plan.planDigest,
      workspaceID: "workspace-1",
      now: now.addingTimeInterval(1)
    )
    #expect(result.releasedThreadIDs == [stale.threadID])
    #expect(!result.signalsSent)
    #expect(!result.externalStateMutated)
    #expect(try database.codexThreadOwnership(threadID: stale.threadID)?.state == .released)
  }

  @Test
  func testOwnershipReconciliationPreservesReceiptWhileRecordedProcessIsAlive() throws {
    let database = try CodexDatabase(inMemory: ())
    let now = Date()
    let runtimeID = "runtime-live-process"
    try database.saveCodexRuntimeLease(
      CodexRuntimeLeaseRecord(
        id: runtimeID,
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
        threadID: "thread-live-process",
        workspaceID: "workspace-1",
        workspacePath: "/tmp/workspace-1",
        runtimeID: runtimeID,
        state: .loaded,
        createdAt: now,
        updatedAt: now
      )
    )

    let plan = try CodexThreadOwnershipReconciliation.preview(
      database: database,
      workspaceID: "workspace-1"
    )
    #expect(plan.candidates.isEmpty)
    #expect(!plan.signalsSent)
  }

  @Test
  func testPreSplitRequestTimeoutIsReconciledWithoutTerminalRuntimeReason() throws {
    let database = try CodexDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 6_000)
    try database.saveCodexRuntimeLease(
      CodexRuntimeLeaseRecord(
        id: "pre-split-runtime",
        owner: nil,
        workspacePath: "/tmp/workspace-1",
        state: "running",
        process: nil,
        createdAt: now,
        updatedAt: now,
        shutdownReason: "request_timeout",
        cleanedAt: nil
      )
    )

    let reconciled = try #require(try database.codexRuntimeLeases().first)
    #expect(reconciled.runtimeState == "running")
    #expect(reconciled.shutdownReason == nil)
    #expect(reconciled.lastRequestFailure?.kind == "request_timeout")
    #expect(reconciled.lastRequestFailure?.recoverable == true)
  }

  @Test
  func testReviewedRuntimeCleanupOnlyTransitionsDeadStaleReceipts() async throws {
    let database = try CodexDatabase(inMemory: ())
    let now = Date()
    let owner = CodexRuntimeOwner(
      workspaceID: "workspace-cleanup",
      profileID: "local-admin",
      caller: "local-mcp",
      transport: "fixture",
      socketConnectionID: nil,
      tunnelInstanceID: nil,
      tunnelProfileID: nil
    )
    let process = CodexAppServerProcessSnapshot(
      state: .running,
      processID: Int32.max - 1,
      supervisorProcessID: Int32.max - 2,
      parentProcessID: Int32.max - 3,
      processGroupID: Int32.max - 1,
      startedAt: now,
      stoppedAt: nil,
      exitCode: nil,
      signal: nil,
      terminationEscalated: false,
      lastError: nil
    )
    try database.saveCodexRuntimeLease(
      CodexRuntimeLeaseRecord(
        id: "stale-runtime",
        owner: owner,
        workspacePath: "/tmp/workspace-cleanup",
        state: "running",
        process: process,
        createdAt: now,
        updatedAt: now,
        shutdownReason: nil,
        cleanedAt: nil
      )
    )

    let preview = try CodexRuntimeMaintenance.preview(
      database: database,
      workspaceID: owner.workspaceID
    )
    #expect(
      preview.objectValue?["candidates"]?.arrayValue?.first?.objectValue?["cleanup_ready"]
        == .bool(true))
    let result = try await CodexRuntimeMaintenance.cleanup(
      database: database,
      workspaceID: owner.workspaceID
    )
    #expect(result.objectValue?["cleaned"]?.arrayValue?.count == 1)
    #expect(try database.codexRuntimeLeases().first?.state == "cleaned")
  }
}
