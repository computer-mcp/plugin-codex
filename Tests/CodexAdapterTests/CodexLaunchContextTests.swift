import Foundation
import Testing

@testable import CodexAdapter

struct CodexLaunchContextTests {
  @Test func appServerRequiresExplicitStateAndDoesNotLaunchForDiscovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try CodexLaunchContext(environment: [:], currentDirectory: root)
    let disabledState = root.appendingPathComponent("disabled")
    #expect(
      try context.appServerProvider(configuration: .init(), stateDirectory: disabledState) == nil)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let configuration = CodexConfig(enabled: true, executable: "/missing/codex")
    #expect(throws: ConfigurationError.self) {
      try context.appServerProvider(configuration: configuration, stateDirectory: nil)
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let provider = try #require(
      try context.appServerProvider(
        configuration: configuration, stateDirectory: root.appendingPathComponent("adapter-state")))
    #expect(!provider.tools.isEmpty)
    #expect(provider.owner == context.owner)
    #expect(provider.localControlAllowed)
    #expect(await provider.appServer.status().objectValue?["process_state"] == .string("absent"))
    #expect(try provider.database?.codexRuntimeLeases().isEmpty == true)
    #expect(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("adapter-state/codex.sqlite").path))
    let execution = try context.executionProvider(configuration: configuration)
    #expect(execution.tools.count == 16)
    await execution.shutdown()
    await provider.shutdown()
  }

  @Test func ownerRetainsHostTransportAndStandaloneWorkspaceIdentity() throws {
    var host = try #require(
      try JSONSerialization.jsonObject(with: Data(validHost.utf8)) as? [String: Any])
    host["caller"] = "remote-mcp"
    host["transportTrace"] = [
      "transport": "secure-tunnel", "socketConnectionID": "socket-1",
      "tunnelInstanceID": "tunnel-1", "tunnelProfileID": "tunnel-profile-1",
    ]
    let context = try CodexLaunchContext(
      environment: [
        "COMPUTER_MCP_HOST_CONTEXT": String(
          decoding: JSONSerialization.data(withJSONObject: host), as: UTF8.self)
      ],
      currentDirectory: URL(fileURLWithPath: "/tmp/other"))
    #expect(context.owner.workspaceID == "fixture")
    #expect(context.owner.profileID == "observe")
    #expect(context.owner.caller == "remote-mcp")
    #expect(context.owner.transport == "secure-tunnel")
    #expect(context.owner.socketConnectionID == "socket-1")
    #expect(context.owner.tunnelInstanceID == "tunnel-1")
    #expect(context.owner.tunnelProfileID == "tunnel-profile-1")
    #expect(!context.localControlAllowed)
    let first = try CodexLaunchContext(
      environment: [:], currentDirectory: URL(fileURLWithPath: "/tmp/a"))
    let same = try CodexLaunchContext(
      environment: [:], currentDirectory: URL(fileURLWithPath: "/tmp/a/../a"))
    let other = try CodexLaunchContext(
      environment: [:], currentDirectory: URL(fileURLWithPath: "/tmp/b"))
    #expect(first.owner == same.owner)
    #expect(first.owner.workspaceID != other.owner.workspaceID)
    #expect(first.owner.elevationConnectionID == nil)
  }

  @Test func hostWorkspaceAndReadOnlyOverrideLocalProcessDefaults() throws {
    let context = try CodexLaunchContext(
      environment: ["COMPUTER_MCP_HOST_CONTEXT": validHost],
      currentDirectory: URL(fileURLWithPath: "/tmp/other"))
    #expect(context.workspaceURL.path == "/tmp/bound-workspace")
    #expect(context.readOnly)
    let provider = try context.executionProvider(
      configuration: .init(enabled: true, appServerEnabled: false))
    #expect(provider.readOnly)
    #expect(provider.tools.count == 16)
  }

  @Test func separateProvidersAndDisabledDefaultDoNotLaunchCodex() async throws {
    let context = try CodexLaunchContext(
      environment: [:], currentDirectory: URL(fileURLWithPath: "/tmp/standalone"))
    #expect(context.workspaceURL.path == "/tmp/standalone")
    #expect(!context.readOnly)
    #expect(try context.executionProvider(configuration: .init()).tools.isEmpty)
    let exec = try context.executionProvider(
      configuration: .init(
        enabled: true, executable: "/missing/codex", appServerEnabled: false, mcpEnabled: false))
    let mcp = try context.executionProvider(
      configuration: .init(
        enabled: true, executable: "/missing/codex", appServerEnabled: false, execEnabled: false))
    #expect(exec.tools.count == 6)
    #expect(mcp.tools.count == 10)
    _ = try await exec.call(name: "codex.exec.list", arguments: nil)
    _ = try await mcp.call(name: "codex.mcp.status", arguments: nil)
    await exec.shutdown()
    await mcp.shutdown()
  }

  @Test(arguments: ["", "{}", "null", "oversized"])
  func malformedContextFailsClosed(text: String) {
    #expect(throws: ConfigurationError.self) {
      try CodexLaunchContext(
        environment: [
          "COMPUTER_MCP_HOST_CONTEXT": text == "oversized"
            ? String(repeating: "x", count: 16_385) : text
        ],
        currentDirectory: URL(fileURLWithPath: "/tmp"))
    }
  }

  @Test func existingConfigurationDefaultsAndValidationArePreserved() throws {
    let config = try JSONDecoder().decode(CodexConfig.self, from: Data("{}".utf8))
    #expect(config == CodexConfig())
    #expect(throws: ConfigurationError.self) {
      try CodexConfig(enabled: true, sandbox: .dangerFullAccess).validate()
    }
    #expect(throws: ConfigurationError.self) { try CodexConfig(maxSessions: 65).validate() }
    try CodexConfig(appServerTerminationGraceMilliseconds: 0, appServerKillGraceMilliseconds: 100)
      .validate()
  }

  @Test func childEnvironmentDoesNotInheritHostOrParentSessionIdentity() {
    let result = CodexProcessEnvironment.resolved(
      base: [
        "COMPUTER_MCP_HOST_CONTEXT": validHost, "CODEX_THREAD_ID": "parent",
        "CODEX_HOME": "/tmp/private-state",
      ], systemProxy: .init())
    #expect(result["COMPUTER_MCP_HOST_CONTEXT"] == nil)
    #expect(result["CODEX_THREAD_ID"] == nil)
    #expect(result["CODEX_HOME"] == "/tmp/private-state")
  }

  private var validHost: String {
    #"{"formatVersion":1,"runtimeID":"B66E26EE-53AF-4455-A25D-E2BDD219798C","caller":"local-mcp","profileID":"observe","workspace":{"id":"fixture","rootPath":"/tmp/bound-workspace"},"readOnly":true}"#
  }
}
