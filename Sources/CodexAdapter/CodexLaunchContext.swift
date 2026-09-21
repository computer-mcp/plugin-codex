import CryptoKit
import Foundation

/// Host launch metadata binds task ownership; it never grants gateway administration.
struct CodexLaunchContext: Sendable {
  let workspaceURL: URL
  let owner: CodexRuntimeOwner
  let localControlAllowed: Bool
  let managedWorktreeRoot: URL?

  init(environment: [String: String], currentDirectory: URL) throws {
    if let text = environment["COMPUTER_MCP_HOST_CONTEXT"] {
      guard text.utf8.count <= 16_384,
        let host = try? JSONDecoder().decode(Host.self, from: Data(text.utf8)),
        host.formatVersion == 1,
        !host.workspace.id.isEmpty, !host.profileID.isEmpty, !host.caller.isEmpty,
        host.workspace.rootPath.hasPrefix("/"), !host.workspace.rootPath.contains("\0")
      else {
        throw ConfigurationError.invalid("Invalid Computer MCP launch context.")
      }
      workspaceURL = URL(fileURLWithPath: host.workspace.rootPath).standardizedFileURL
      if let root = host.managedWorkspaceRoot {
        guard root.hasPrefix("/"), root.utf8.count <= 16_384, !root.contains("\0") else {
          throw ConfigurationError.invalid("Invalid host-owned managed workspace root.")
        }
        managedWorktreeRoot = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
      } else {
        managedWorktreeRoot = nil
      }
      owner = CodexRuntimeOwner(
        workspaceID: host.workspace.id, profileID: host.profileID, caller: host.caller,
        transport: host.transportTrace?.transport,
        socketConnectionID: host.transportTrace?.socketConnectionID,
        tunnelInstanceID: host.transportTrace?.tunnelInstanceID,
        tunnelProfileID: host.transportTrace?.tunnelProfileID, principalID: host.principalID)
      localControlAllowed = ["local-app", "local-cli", "local-mcp"].contains(host.caller)
    } else {
      workspaceURL = currentDirectory.standardizedFileURL
      managedWorktreeRoot = nil
      let identity = SHA256.hash(data: Data(workspaceURL.path.utf8))
        .map { String(format: "%02x", $0) }.joined()
      owner = CodexRuntimeOwner(
        workspaceID: "local:" + identity, profileID: "standalone", caller: "local-mcp",
        transport: "stdio", socketConnectionID: nil, tunnelInstanceID: nil, tunnelProfileID: nil)
      localControlAllowed = true
    }
  }

  func executionProvider(configuration: CodexConfig, stateDirectory: URL? = nil) throws
    -> CodexExecutionProvider
  {
    try configuration.validate()
    guard configuration.enabled else {
      return CodexExecutionProvider(exec: nil)
    }
    let index =
      configuration.execEnabled ? try makeThreadOwnerIndex(stateDirectory: stateDirectory) : nil
    return CodexExecutionProvider(
      exec: configuration.execEnabled
        ? LiveCodexExecRuntime(
          configuration: configuration, workspaceURL: workspaceURL, threadOwnerIndex: index) : nil)
  }

  func appServerProvider(
    configuration: CodexConfig, stateDirectory: URL?, hostTools: (any CodexHostTools)? = nil,
    hostServices: CodexHostMCPClient? = nil
  ) throws -> CodexAppServerProvider? {
    try configuration.validate()
    guard configuration.enabled, configuration.appServerEnabled else { return nil }
    guard let stateDirectory else {
      throw ConfigurationError.invalid(
        "App Server execution requires --state-directory for adapter-owned records.")
    }
    let unboundStateAvailable =
      owner.principalID != nil
      && FileManager.default.fileExists(
        atPath: stateDirectory.appendingPathComponent("codex.sqlite").path)
    let storageDirectory: URL
    let worktreeLeasePath: String?
    let threadOwnerIndex: CodexThreadOwnerIndex?
    if let principalID = owner.principalID {
      let identity = try JSONEncoder().encode([
        principalID, owner.profileID ?? "", owner.workspaceID ?? "",
      ])
      let scope = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
      storageDirectory = stateDirectory.appendingPathComponent("subjects", isDirectory: true)
        .appendingPathComponent(scope, isDirectory: true)
      let leaseIdentity = try JSONEncoder().encode([principalID, owner.profileID ?? ""])
      let leaseScope = SHA256.hash(data: leaseIdentity).map { String(format: "%02x", $0) }.joined()
      let leaseDirectory = stateDirectory.appendingPathComponent(
        "worktree-leases", isDirectory: true)
      try FileManager.default.createDirectory(
        at: leaseDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      worktreeLeasePath = leaseDirectory.appendingPathComponent(leaseScope + ".sqlite").path
      threadOwnerIndex = try makeThreadOwnerIndex(stateDirectory: stateDirectory)
    } else {
      storageDirectory = stateDirectory
      worktreeLeasePath = nil
      threadOwnerIndex = nil
    }
    try FileManager.default.createDirectory(
      at: storageDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let database = try CodexDatabase(
      path: storageDirectory.appendingPathComponent("codex.sqlite").path,
      worktreeLeasePath: worktreeLeasePath)
    return CodexAppServerProvider(
      appServer: LiveCodexAppServerRuntime(
        configuration: configuration, workspaceURL: workspaceURL, owner: owner, database: database,
        dynamicToolDispatcher: hostTools, threadOwnerIndex: threadOwnerIndex),
      owner: owner, database: database, workspaceURL: workspaceURL,
      recentThreadReader: .live(),
      localControlAllowed: localControlAllowed,
      workspaceHost: hostServices, managedWorktreeRoot: managedWorktreeRoot,
      configuredSandbox: configuration.sandbox, hostDiagnostics: hostServices,
      unboundStateAvailable: unboundStateAvailable, threadOwnerIndex: threadOwnerIndex)
  }

  private func makeThreadOwnerIndex(stateDirectory: URL?) throws -> CodexThreadOwnerIndex? {
    guard let principalID = owner.principalID else { return nil }
    guard let stateDirectory else {
      throw ConfigurationError.invalid(
        "Host-bound Codex execution requires --state-directory for thread ownership.")
    }
    let identity = try JSONEncoder().encode([
      principalID, owner.profileID ?? "", owner.workspaceID ?? "",
    ])
    let scope = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let codexHome =
      ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    return try CodexThreadOwnerIndex(
      path: stateDirectory.appendingPathComponent("thread-owners.sqlite").path, subject: scope,
      codexHome: codexHome)
  }

  private struct Host: Decodable {
    struct Workspace: Decodable {
      let id: String
      let rootPath: String
    }
    let formatVersion: Int
    let runtimeID: UUID
    let caller: String
    let profileID: String
    let principalID: String?
    let workspace: Workspace
    let managedWorkspaceRoot: String?
    let transportTrace: TransportTrace?
    struct TransportTrace: Decodable {
      let transport: String
      let socketConnectionID: String?
      let tunnelInstanceID: String?
      let tunnelProfileID: String?
    }
  }
}
