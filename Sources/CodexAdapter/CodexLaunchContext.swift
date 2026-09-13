import CryptoKit
import Foundation

/// Host launch metadata narrows this process; it never grants gateway administration.
struct CodexLaunchContext: Sendable {
  let workspaceURL: URL
  let readOnly: Bool
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
      readOnly = host.readOnly
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
        tunnelProfileID: host.transportTrace?.tunnelProfileID)
      localControlAllowed = ["local-app", "local-cli", "local-mcp"].contains(host.caller)
    } else {
      workspaceURL = currentDirectory.standardizedFileURL
      readOnly = false
      managedWorktreeRoot = nil
      let identity = SHA256.hash(data: Data(workspaceURL.path.utf8))
        .map { String(format: "%02x", $0) }.joined()
      owner = CodexRuntimeOwner(
        workspaceID: "local:" + identity, profileID: "standalone", caller: "local-mcp",
        transport: "stdio", socketConnectionID: nil, tunnelInstanceID: nil, tunnelProfileID: nil)
      localControlAllowed = true
    }
  }

  func executionProvider(configuration: CodexConfig) throws -> CodexExecutionProvider {
    try configuration.validate()
    guard configuration.enabled else {
      return CodexExecutionProvider(exec: nil, mcp: nil, readOnly: readOnly)
    }
    var effective = configuration
    if readOnly { effective.sandbox = .readOnly }
    return CodexExecutionProvider(
      exec: effective.execEnabled
        ? LiveCodexExecRuntime(configuration: effective, workspaceURL: workspaceURL) : nil,
      mcp: effective.mcpEnabled
        ? LiveCodexMCPRuntime(configuration: effective, workspaceURL: workspaceURL) : nil,
      readOnly: readOnly)
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
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let database = try CodexDatabase(
      path: stateDirectory.appendingPathComponent("codex.sqlite").path)
    var effective = configuration
    if readOnly {
      effective.sandbox = .readOnly
      effective.appServerAutoApproveWorkspaceWrites = false
    }
    return CodexAppServerProvider(
      appServer: LiveCodexAppServerRuntime(
        configuration: effective, workspaceURL: workspaceURL, owner: owner, database: database,
        dynamicToolDispatcher: hostTools, elevationAuthority: hostServices),
      owner: owner, database: database, workspaceURL: workspaceURL,
      recentThreadReader: .live(workspaceURL: workspaceURL),
      readOnly: readOnly, localControlAllowed: localControlAllowed,
      workspaceHost: hostServices, managedWorktreeRoot: managedWorktreeRoot,
      configuredSandbox: effective.sandbox, hostDiagnostics: hostServices,
      elevationAuthority: hostServices)
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
    let workspace: Workspace
    let readOnly: Bool
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
