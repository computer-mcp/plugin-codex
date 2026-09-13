import Foundation
import MCP
import Testing

@testable import CodexAdapter

@Suite(.serialized)
final class CodexManagedWorktreeTests {
  @Test(.timeLimit(.minutes(1)))
  func mcpWorktreeLifecyclePreservesHostDenialAndWorkspaceScope() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repository = directory.appendingPathComponent("repository", isDirectory: true)
    let managedRoot = directory.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try runGit(["init", "-q"], in: repository)
    try runGit(["config", "user.name", "Computer MCP Test"], in: repository)
    try runGit(["config", "user.email", "computer-mcp@example.invalid"], in: repository)
    try Data("baseline\n".utf8).write(to: repository.appendingPathComponent("README.md"))
    try runGit(["add", "README.md"], in: repository)
    try runGit(["commit", "-q", "-m", "test: baseline"], in: repository)
    let database = try CodexDatabase(path: directory.appendingPathComponent("adapter.sqlite").path)
    let host = RecordingManagedWorkspaceHost()
    func provider(workspaceID: String, path: URL, hostConnected: Bool = true)
      -> CodexAppServerProvider
    {
      CodexAppServerProvider(
        appServer: FakeAppServerRuntime(),
        owner: CodexRuntimeOwner(
          workspaceID: workspaceID, profileID: "local-admin", caller: "local-mcp",
          transport: "fixture", socketConnectionID: nil,
          tunnelInstanceID: nil, tunnelProfileID: nil),
        database: database, workspaceURL: path, recentThreadReader: nil,
        readOnly: false, localControlAllowed: true,
        workspaceHost: hostConnected ? host : nil, managedWorktreeRoot: managedRoot)
    }
    try await withMCPClient(provider: provider(workspaceID: "source-workspace", path: repository)) {
      client in
      let parent = try await invoke(
        client, "codex.worktree.leases.acquire",
        [
          "agent_id": .string("parent"), "mode": .string("exclusive"),
        ])
      let plan = try await invoke(
        client, "codex.worktree.provision.plan",
        [
          "agent_id": .string("child"),
          "parent_lease_id": try #require(parent.objectValue?["id"]),
          "branch": .string("codex/mcp-worktree"),
        ])
      let planID = try #require(plan.objectValue?["id"])
      try await withMCPClient(
        provider: provider(workspaceID: "source-workspace", path: repository, hostConnected: false)
      ) { unconnected in
        let unavailable = try await unconnected.callTool(
          name: "codex.worktree.provision.perform",
          arguments: [
            "plan_id": planID, "expected_revision": try #require(plan.objectValue?["revision"]),
            "confirm_provision": .bool(true),
          ])
        #expect(unavailable.isError == true)
        let plannedPath = try #require(plan.objectValue?["path"]?.stringValue)
        #expect(!FileManager.default.fileExists(atPath: plannedPath))
        #expect(
          try database.codexManagedWorktree(id: try #require(planID.stringValue))?.state == .planned
        )
      }
      let active = try await invoke(
        client, "codex.worktree.provision.perform",
        [
          "plan_id": planID, "expected_revision": try #require(plan.objectValue?["revision"]),
          "confirm_provision": .bool(true),
        ])
      let worktreeID = try #require(active.objectValue?["id"]?.stringValue)
      let record = try #require(try database.codexManagedWorktree(id: worktreeID))
      #expect(record.state == .active)
      #expect(await host.record(id: record.workspaceID)?.id == worktreeID)
      let listed = try await invoke(client, "codex.worktree.managed.list")
      #expect(listed.objectValue?["worktrees"]?.arrayValue?.count == 1)
      let read = try await invoke(
        client, "codex.worktree.managed.read",
        [
          "managed_worktree_id": .string(worktreeID)
        ])
      #expect(read == active)
      let sourceDiagnostic = try await invoke(client, "codex.diagnostics.snapshot")
      #expect(
        sourceDiagnostic.objectValue?["summary"]?.objectValue?["active_managed_worktree_count"]
          == .int(1))
      let leaseID = try #require(record.leaseID)
      let lease = try #require(try database.codexWorktreeLease(id: leaseID))
      let releaseArguments: [String: MCP.Value] = [
        "lease_id": .string(leaseID), "expected_revision": .int(lease.revision),
        "reason": .string("Child work accepted."),
      ]
      let wrongScope = try await client.callTool(
        name: "codex.worktree.leases.release", arguments: releaseArguments)
      #expect(wrongScope.isError == true)
      #expect(try database.codexWorktreeLease(id: leaseID)?.state == .active)
      let busy = try await client.callTool(
        name: "codex.worktree.remove.plan",
        arguments: [
          "managed_worktree_id": .string(worktreeID)
        ])
      #expect(busy.isError == true)
      try await withMCPClient(
        provider: provider(workspaceID: record.workspaceID, path: URL(fileURLWithPath: record.path))
      ) { child in
        let hidden = try await child.callTool(
          name: "codex.worktree.managed.read",
          arguments: [
            "managed_worktree_id": .string(worktreeID)
          ])
        #expect(hidden.isError == true)
        let childDiagnostic = try await invoke(child, "codex.diagnostics.snapshot")
        #expect(
          childDiagnostic.objectValue?["managed_worktrees"]?.arrayValue?.first?.objectValue?["id"]
            == .string(worktreeID))
        #expect(
          childDiagnostic.objectValue?["summary"]?.objectValue?["active_worktree_lease_count"]
            == .int(1))
        _ = try await invoke(child, "codex.worktree.leases.release", releaseArguments)
      }
      #expect(try database.codexWorktreeLease(id: leaseID)?.state == .released)
      let dirty = URL(fileURLWithPath: record.path).appendingPathComponent("unaccepted.txt")
      try Data("keep until reviewed\n".utf8).write(to: dirty)
      let dirtyRemoval = try await client.callTool(
        name: "codex.worktree.remove.plan",
        arguments: [
          "managed_worktree_id": .string(worktreeID)
        ])
      #expect(dirtyRemoval.isError == true)
      #expect(try Data(contentsOf: dirty) == Data("keep until reviewed\n".utf8))
      try FileManager.default.removeItem(at: dirty)
      let removal = try await invoke(
        client, "codex.worktree.remove.plan",
        [
          "managed_worktree_id": .string(worktreeID)
        ])
      let removeArguments: [String: MCP.Value] = [
        "managed_worktree_id": .string(worktreeID),
        "expected_revision": try #require(removal.objectValue?["revision"]),
        "confirm_remove": .bool(true),
      ]
      await host.setRemovalAllowed(false)
      let denied = try await client.callTool(
        name: "codex.worktree.remove.perform", arguments: removeArguments)
      #expect(denied.isError == true)
      #expect(try database.codexManagedWorktree(id: worktreeID)?.state == .removalPlanned)
      #expect(
        try database.codexManagedWorktree(id: worktreeID)?.json
          == JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(removal)))
      #expect(FileManager.default.fileExists(atPath: record.path))
      #expect(await host.record(id: record.workspaceID)?.id == worktreeID)
      await host.setRemovalAllowed(true)
      let removed = try await invoke(client, "codex.worktree.remove.perform", removeArguments)
      #expect(removed.objectValue?["state"] == .string("removed"))
      #expect(!FileManager.default.fileExists(atPath: record.path))
      #expect(await host.record(id: record.workspaceID) == nil)
      let removedDiagnostic = try await invoke(client, "codex.diagnostics.snapshot")
      #expect(
        removedDiagnostic.objectValue?["summary"]?.objectValue?["active_managed_worktree_count"]
          == .int(0))
      let reopened = try CodexDatabase(
        path: directory.appendingPathComponent("adapter.sqlite").path)
      #expect(try reopened.codexManagedWorktree(id: worktreeID)?.state == .removed)
      #expect(try reopened.codexWorktreeLease(id: leaseID)?.state == .released)
      #expect(
        try gitResult(
          ["show-ref", "--verify", "--quiet", "refs/heads/codex/mcp-worktree"], in: repository
        ).exitCode == 0)
    }
  }

  @Test(arguments: [false, true])
  func testManagedWorktreeProvisionAndRemovalRequireOwnedCleanLifecycle(retryHostFailure: Bool)
    async throws
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repository = directory.appendingPathComponent("repository", isDirectory: true)
    let managedRoot = directory.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try runGit(["init", "-q"], in: repository)
    try runGit(["config", "user.name", "Computer MCP Test"], in: repository)
    try runGit(["config", "user.email", "computer-mcp@example.invalid"], in: repository)
    try Data("baseline\n".utf8).write(to: repository.appendingPathComponent("README.md"))
    try runGit(["add", "README.md"], in: repository)
    try runGit(["commit", "-q", "-m", "test: baseline"], in: repository)

    let database = try CodexDatabase(inMemory: ())
    let sourceWorkspaceID = "source-workspace"
    let workspaceHost = RecordingManagedWorkspaceHost()
    let parent = try CodexWorktreeLeaseManager.acquire(
      database: database,
      workspaceID: sourceWorkspaceID,
      workspaceURL: repository,
      agentID: "parent-agent",
      threadID: "parent-thread",
      runID: nil,
      parentLeaseID: nil,
      branch: nil,
      mode: .exclusive,
      ttlSeconds: 900,
      liveRuntimeStatus: .object(["runtimes": .array([])])
    )

    let plan = try CodexManagedWorktreeManager.planProvision(
      database: database,
      sourceWorkspaceID: sourceWorkspaceID,
      sourceWorkspaceURL: repository,
      profileID: "local-admin",
      caller: "local-mcp",
      agentID: "child-agent",
      threadID: "child-thread",
      runID: nil,
      parentLeaseID: parent.id,
      branch: "codex/managed-child",
      startPoint: "HEAD",
      ttlSeconds: 900,
      managedRoot: managedRoot
    )
    #expect(plan.state == .planned)
    #expect(!FileManager.default.fileExists(atPath: plan.path))

    let active = try await CodexManagedWorktreeManager.performProvision(
      database: database,
      sourceWorkspaceID: sourceWorkspaceID,
      planID: plan.id,
      expectedRevision: plan.revision,
      confirmProvision: true,
      workspaceHost: workspaceHost,
      managedRoot: managedRoot
    )
    #expect(active.state == .active)
    #expect(FileManager.default.fileExists(atPath: active.path))
    #expect(await workspaceHost.record(id: active.workspaceID)?.path == active.path)
    let childLeaseID = try #require(active.leaseID)
    var childLease = try #require(try database.codexWorktreeLease(id: childLeaseID))
    #expect(childLease.mode == .isolatedWorktree)
    #expect(childLease.parentLeaseID == parent.id)
    #expect(childLease.workspaceID == active.workspaceID)

    let dirtyFile = URL(fileURLWithPath: active.path).appendingPathComponent("dirty.txt")
    try Data("not accepted\n".utf8).write(to: dirtyFile)
    #expect(throws: CodexManagedWorktreeError.self) {
      try CodexManagedWorktreeManager.planRemoval(
        database: database,
        sourceWorkspaceID: sourceWorkspaceID,
        managedWorktreeID: active.id,
        liveRuntimeStatus: .object(["runtimes": .array([])]),
        managedRoot: managedRoot
      )
    }
    try FileManager.default.removeItem(at: dirtyFile)
    childLease = try CodexWorktreeLeaseManager.release(
      database: database,
      workspaceID: childLease.workspaceID,
      leaseID: childLease.id,
      expectedRevision: childLease.revision,
      reason: "Child evidence reconciled."
    )
    #expect(childLease.state == .released)

    var removalPlan = try CodexManagedWorktreeManager.planRemoval(
      database: database,
      sourceWorkspaceID: sourceWorkspaceID,
      managedWorktreeID: active.id,
      liveRuntimeStatus: .object(["runtimes": .array([])]),
      managedRoot: managedRoot
    )
    if retryHostFailure {
      await workspaceHost.setUnregisterAllowed(false)
      await #expect(throws: (any Error).self) {
        try await CodexManagedWorktreeManager.performRemoval(
          database: database,
          sourceWorkspaceID: sourceWorkspaceID, managedWorktreeID: active.id,
          expectedRevision: removalPlan.revision, confirmRemoval: true,
          workspaceHost: workspaceHost,
          liveRuntimeStatus: .object(["runtimes": .array([])]), managedRoot: managedRoot)
      }
      let unfinished = try #require(try database.codexManagedWorktree(id: active.id))
      #expect(unfinished.state == .removing)
      #expect(!FileManager.default.fileExists(atPath: active.path))
      #expect(await workspaceHost.record(id: active.workspaceID) != nil)
      // A replacement path must never be treated as the already-removed worktree.
      try FileManager.default.createDirectory(
        atPath: active.path, withIntermediateDirectories: false)
      #expect(throws: (any Error).self) {
        try CodexManagedWorktreeManager.planRemoval(
          database: database, sourceWorkspaceID: sourceWorkspaceID,
          managedWorktreeID: active.id, liveRuntimeStatus: .object(["runtimes": .array([])]),
          managedRoot: managedRoot)
      }
      try FileManager.default.removeItem(atPath: active.path)
      await workspaceHost.setUnregisterAllowed(true)
      removalPlan = try CodexManagedWorktreeManager.planRemoval(
        database: database,
        sourceWorkspaceID: sourceWorkspaceID, managedWorktreeID: active.id,
        liveRuntimeStatus: .object(["runtimes": .array([])]), managedRoot: managedRoot)
    }
    let removed = try await CodexManagedWorktreeManager.performRemoval(
      database: database,
      sourceWorkspaceID: sourceWorkspaceID,
      managedWorktreeID: active.id,
      expectedRevision: removalPlan.revision,
      confirmRemoval: true,
      workspaceHost: workspaceHost,
      liveRuntimeStatus: .object(["runtimes": .array([])]),
      managedRoot: managedRoot
    )
    #expect(removed.state == .removed)
    #expect(!FileManager.default.fileExists(atPath: active.path))
    #expect(await workspaceHost.record(id: active.workspaceID) == nil)
    let preservedBranch = try gitResult(
      ["show-ref", "--verify", "--quiet", "refs/heads/codex/managed-child"],
      in: repository
    )
    #expect(preservedBranch.exitCode == 0)
  }

  @Test
  func failedHostRollbackPreservesTheOwnedGitWorktreeAndBranch() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repository = directory.appendingPathComponent("repository", isDirectory: true)
    let managedRoot = directory.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try runGit(["init", "-q"], in: repository)
    try runGit(["config", "user.name", "Computer MCP Test"], in: repository)
    try runGit(["config", "user.email", "computer-mcp@example.invalid"], in: repository)
    try Data("baseline\n".utf8).write(to: repository.appendingPathComponent("README.md"))
    try runGit(["add", "README.md"], in: repository)
    try runGit(["commit", "-q", "-m", "test: baseline"], in: repository)

    let database = try CodexDatabase(inMemory: ())
    let sourceWorkspaceID = "source-workspace"
    let workspaceHost = RecordingManagedWorkspaceHost()
    let parent = try CodexWorktreeLeaseManager.acquire(
      database: database,
      workspaceID: sourceWorkspaceID,
      workspaceURL: repository,
      agentID: "parent-agent",
      threadID: "parent-thread",
      runID: nil,
      parentLeaseID: nil,
      branch: nil,
      mode: .exclusive,
      ttlSeconds: 900,
      liveRuntimeStatus: .object(["runtimes": .array([])])
    )

    let plan = try CodexManagedWorktreeManager.planProvision(
      database: database,
      sourceWorkspaceID: sourceWorkspaceID,
      sourceWorkspaceURL: repository,
      profileID: "local-admin",
      caller: "local-mcp",
      agentID: "child-agent",
      threadID: "child-thread",
      runID: nil,
      parentLeaseID: parent.id,
      branch: "codex/managed-child",
      startPoint: "HEAD",
      ttlSeconds: 900,
      managedRoot: managedRoot
    )
    #expect(plan.state == .planned)
    #expect(!FileManager.default.fileExists(atPath: plan.path))

    await workspaceHost.setRegisterFailureAfterSaving(true)
    await workspaceHost.setUnregisterAllowed(false)
    await #expect(throws: (any Error).self) {
      try await CodexManagedWorktreeManager.performProvision(
        database: database,
        sourceWorkspaceID: sourceWorkspaceID, planID: plan.id, expectedRevision: plan.revision,
        confirmProvision: true, workspaceHost: workspaceHost, managedRoot: managedRoot)
    }
    let failed = try #require(try database.codexManagedWorktree(id: plan.id))
    #expect(failed.state == .failed)
    #expect(failed.lastError?.contains("Recovery incomplete") == true)
    #expect(FileManager.default.fileExists(atPath: plan.path))
    #expect(await workspaceHost.record(id: plan.workspaceID) != nil)
    let branch = try gitResult(
      ["show-ref", "--verify", "refs/heads/" + plan.branch], in: repository)
    #expect(branch.exitCode == 0)
  }

  @Test
  func testRemovalNeverTargetsAnUnownedUserWorktree() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try CodexDatabase(inMemory: ())

    #expect(throws: CodexManagedWorktreeError.self) {
      try CodexManagedWorktreeManager.planRemoval(
        database: database,
        sourceWorkspaceID: "source-workspace",
        managedWorktreeID: "user-owned-worktree",
        liveRuntimeStatus: .object(["runtimes": .array([])]),
        managedRoot: directory.appendingPathComponent("managed", isDirectory: true)
      )
    }
    #expect(FileManager.default.fileExists(atPath: directory.path))
  }

  @Test
  func testRemovalRejectsAReceiptedPathReplacedBySymbolicLink() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repository = directory.appendingPathComponent("repository", isDirectory: true)
    let managedRoot = directory.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try runGit(["init", "-q"], in: repository)
    try runGit(["config", "user.name", "Computer MCP Test"], in: repository)
    try runGit(["config", "user.email", "computer-mcp@example.invalid"], in: repository)
    try Data("baseline\n".utf8).write(to: repository.appendingPathComponent("README.md"))
    try runGit(["add", "README.md"], in: repository)
    try runGit(["commit", "-q", "-m", "test: baseline"], in: repository)

    let database = try CodexDatabase(inMemory: ())
    let sourceWorkspaceID = "source-workspace"
    let workspaceHost = RecordingManagedWorkspaceHost()
    let parent = try CodexWorktreeLeaseManager.acquire(
      database: database,
      workspaceID: sourceWorkspaceID,
      workspaceURL: repository,
      agentID: "parent-agent",
      threadID: "parent-thread",
      runID: nil,
      parentLeaseID: nil,
      branch: nil,
      mode: .exclusive,
      ttlSeconds: 900,
      liveRuntimeStatus: .object(["runtimes": .array([])])
    )
    let plan = try CodexManagedWorktreeManager.planProvision(
      database: database,
      sourceWorkspaceID: sourceWorkspaceID,
      sourceWorkspaceURL: repository,
      profileID: "local-admin",
      caller: "local-mcp",
      agentID: "child-agent",
      threadID: "child-thread",
      runID: nil,
      parentLeaseID: parent.id,
      branch: "codex/symlink-boundary",
      startPoint: "HEAD",
      ttlSeconds: 900,
      managedRoot: managedRoot
    )
    let active = try await CodexManagedWorktreeManager.performProvision(
      database: database,
      sourceWorkspaceID: sourceWorkspaceID,
      planID: plan.id,
      expectedRevision: plan.revision,
      confirmProvision: true,
      workspaceHost: workspaceHost,
      managedRoot: managedRoot
    )
    let childLeaseID = try #require(active.leaseID)
    var childLease = try #require(try database.codexWorktreeLease(id: childLeaseID))
    childLease = try CodexWorktreeLeaseManager.release(
      database: database,
      workspaceID: childLease.workspaceID,
      leaseID: childLease.id,
      expectedRevision: childLease.revision,
      reason: "Ready for removal validation."
    )
    #expect(childLease.state == .released)

    let original = URL(fileURLWithPath: active.path, isDirectory: true)
    let moved = directory.appendingPathComponent("moved-worktree", isDirectory: true)
    try FileManager.default.moveItem(at: original, to: moved)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)

    #expect(throws: CodexManagedWorktreeError.self) {
      try CodexManagedWorktreeManager.planRemoval(
        database: database,
        sourceWorkspaceID: sourceWorkspaceID,
        managedWorktreeID: active.id,
        liveRuntimeStatus: .object(["runtimes": .array([])]),
        managedRoot: managedRoot
      )
    }
    #expect(FileManager.default.fileExists(atPath: moved.path))
  }

  @Test
  func testProvisionRollbackDoesNotDeleteBranchCreatedByAnotherWriter() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repository = directory.appendingPathComponent("repository", isDirectory: true)
    let managedRoot = directory.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try runGit(["init", "-q"], in: repository)
    try runGit(["config", "user.name", "Computer MCP Test"], in: repository)
    try runGit(["config", "user.email", "computer-mcp@example.invalid"], in: repository)
    try Data("baseline\n".utf8).write(to: repository.appendingPathComponent("README.md"))
    try runGit(["add", "README.md"], in: repository)
    try runGit(["commit", "-q", "-m", "test: baseline"], in: repository)

    let database = try CodexDatabase(inMemory: ())
    let sourceWorkspaceID = "source-workspace"
    let workspaceHost = RecordingManagedWorkspaceHost()
    let parent = try CodexWorktreeLeaseManager.acquire(
      database: database,
      workspaceID: sourceWorkspaceID,
      workspaceURL: repository,
      agentID: "parent-agent",
      threadID: "parent-thread",
      runID: nil,
      parentLeaseID: nil,
      branch: nil,
      mode: .exclusive,
      ttlSeconds: 900,
      liveRuntimeStatus: .object(["runtimes": .array([])])
    )
    let branch = "codex/concurrent-owner"
    let plan = try CodexManagedWorktreeManager.planProvision(
      database: database,
      sourceWorkspaceID: sourceWorkspaceID,
      sourceWorkspaceURL: repository,
      profileID: "local-admin",
      caller: "local-mcp",
      agentID: "child-agent",
      threadID: "child-thread",
      runID: nil,
      parentLeaseID: parent.id,
      branch: branch,
      startPoint: "HEAD",
      ttlSeconds: 900,
      commandRunner: BranchRaceCommandRunner(branch: branch),
      managedRoot: managedRoot
    )

    await #expect(throws: CodexManagedWorktreeError.self) {
      try await CodexManagedWorktreeManager.performProvision(
        database: database,
        sourceWorkspaceID: sourceWorkspaceID,
        planID: plan.id,
        expectedRevision: plan.revision,
        confirmProvision: true,
        workspaceHost: workspaceHost,
        commandRunner: BranchRaceCommandRunner(branch: branch),
        managedRoot: managedRoot
      )
    }
    let branchResult = try gitResult(
      ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
      in: repository
    )
    #expect(branchResult.exitCode == 0)
  }

  private func runGit(_ arguments: [String], in directory: URL) throws {
    let result = try gitResult(arguments, in: directory)
    guard result.exitCode == 0 else {
      throw CodexManagedWorktreeError.command(result.stderr)
    }
  }

  private func gitResult(_ arguments: [String], in directory: URL) throws -> CommandResult {
    try ProcessCommandRunner().run(
      executable: "/usr/bin/git",
      arguments: arguments,
      workingDirectory: directory,
      environment: ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"],
      timeoutMilliseconds: 10_000,
      maxOutputBytes: 1_048_576
    )
  }
}

private final class BranchRaceCommandRunner: CommandRunning, @unchecked Sendable {
  private let branch: String
  private let runner = ProcessCommandRunner()
  private let lock = NSLock()
  private var injected = false

  init(branch: String) {
    self.branch = branch
  }

  func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult {
    lock.lock()
    let shouldInject =
      !injected && executable == "/usr/bin/git" && arguments.starts(with: ["worktree", "add"])
    if shouldInject {
      injected = true
    }
    lock.unlock()

    if shouldInject, let workingDirectory {
      let create = try runner.run(
        executable: executable,
        arguments: ["branch", branch, "HEAD"],
        workingDirectory: workingDirectory,
        environment: environment,
        timeoutMilliseconds: timeoutMilliseconds,
        maxOutputBytes: maxOutputBytes
      )
      guard create.exitCode == 0 else { return create }
      return CommandResult(
        executable: executable,
        arguments: arguments,
        exitCode: 128,
        timedOut: false,
        stdout: "",
        stderr: "fatal: a concurrent writer created the branch",
        stdoutTruncated: false,
        stderrTruncated: false
      )
    }
    return try runner.run(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes
    )
  }

  func runData(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandDataResult {
    try runner.runData(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes
    )
  }
}

private actor RecordingManagedWorkspaceHost: CodexManagedWorkspaceHost {
  private var records: [String: CodexManagedWorktree] = [:]
  private var removalAllowed = true
  private var unregisterAllowed = true
  private var registerFailureAfterSaving = false
  func setRegisterFailureAfterSaving(_ value: Bool) { registerFailureAfterSaving = value }
  func setUnregisterAllowed(_ value: Bool) { unregisterAllowed = value }

  func setRemovalAllowed(_ allowed: Bool) { removalAllowed = allowed }

  func authorizeRemoval(_ worktree: CodexManagedWorktree) throws {
    guard removalAllowed else {
      throw CodexManagedWorktreeError.state("Fixture host denied removal.")
    }
    guard records[worktree.workspaceID]?.id == worktree.id else {
      throw CodexManagedWorktreeError.state("Fixture removal ownership mismatch.")
    }
  }

  func registerDerivedWorkspace(_ worktree: CodexManagedWorktree, now: Date) throws {
    guard worktree.sourceWorkspaceID == "source-workspace",
      worktree.profileID == "local-admin", worktree.caller == "local-mcp"
    else {
      throw CodexManagedWorktreeError.state("Fixture source binding mismatch.")
    }
    records[worktree.workspaceID] = worktree
    if registerFailureAfterSaving {
      throw CodexManagedWorktreeError.state("Fixture registration acknowledgement failed.")
    }
  }

  func unregisterDerivedWorkspace(_ worktree: CodexManagedWorktree, now: Date) throws {
    guard unregisterAllowed else {
      throw CodexManagedWorktreeError.state("Fixture unregister failed after Git removal.")
    }
    guard let registered = records[worktree.workspaceID] else { return }
    guard registered.id == worktree.id, registered.path == worktree.path,
      registered.sourceWorkspaceID == worktree.sourceWorkspaceID
    else {
      throw CodexManagedWorktreeError.state("Fixture registration ownership mismatch.")
    }
    records.removeValue(forKey: worktree.workspaceID)
  }

  func record(id: String) -> CodexManagedWorktree? { records[id] }
}

private func withMCPClient(
  provider: CodexAppServerProvider,
  body: (MCP.Client) async throws -> Void
) async throws {
  let pair = await InMemoryTransport.createConnectedPair()
  try await pair.server.connect()
  let serving = Task {
    try await CodexAdapterServer.serve(transport: pair.server, appServer: provider)
  }
  let client = MCP.Client(name: "managed-worktree-fixture", version: "1")
  do {
    _ = try await client.connect(transport: pair.client)
    try await body(client)
    await client.disconnect()
    try await serving.value
  } catch {
    await client.disconnect()
    await pair.server.disconnect()
    _ = try? await serving.value
    throw error
  }
}

private func invoke(
  _ client: MCP.Client, _ name: String, _ arguments: [String: MCP.Value] = [:]
) async throws -> MCP.Value {
  let pending = try await client.send(MCP.CallTool.request(.init(name: name, arguments: arguments)))
  let response = try await pending.value
  try #require(response.isError == false, "\(name): \(response.content)")
  let result = try #require(response.structuredContent?.objectValue?["result"])
  guard case .text(let text, _, _) = response.content.first else {
    throw CodexToolError.executionFailed("Missing MCP text result.")
  }
  #expect(try JSONDecoder().decode(MCP.Value.self, from: Data(text.utf8)) == result)
  return result
}
