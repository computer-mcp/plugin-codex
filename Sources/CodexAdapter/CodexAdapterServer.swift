import Foundation
import MCP

package enum CodexAdapterServer {
  package static func compareSchemas(baseline: URL, current: URL) throws -> Data {
    try SchemaComparison.compareDirectories(baseline: baseline, current: current)
  }

  package static func run(configurationURL: URL? = nil, stateDirectory: URL? = nil) async throws {
    let configuration: CodexConfig
    if let configurationURL {
      let handle = try FileHandle(forReadingFrom: configurationURL)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: 65_537) ?? Data()
      guard data.count <= 65_536 else {
        throw ConfigurationError.invalid("Codex configuration exceeds 64 KiB.")
      }
      configuration = try JSONDecoder().decode(CodexConfig.self, from: data)
    } else {
      configuration = CodexConfig()
    }
    let context = try CodexLaunchContext(
      environment: ProcessInfo.processInfo.environment,
      currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    let host = try CodexHostMCPClient.inherited(
      environment: ProcessInfo.processInfo.environment, context: context)
    do {
      let execution = try context.executionProvider(configuration: configuration)
      let appServer = try context.appServerProvider(
        configuration: configuration, stateDirectory: stateDirectory, hostTools: host,
        hostServices: host)
      try await serve(transport: StdioTransport(), execution: execution, appServer: appServer)
    } catch {
      await host?.shutdown()
      throw error
    }
    await host?.shutdown()
  }

  static func serve(
    transport: any MCP.Transport,
    execution: CodexExecutionProvider = .init(exec: nil, mcp: nil, readOnly: false),
    appServer: CodexAppServerProvider? = nil
  ) async throws {
    let tools = ProtocolTools(inventory: try .bundled())
    let server = MCP.Server(
      name: "codex-mcp-adapter", version: "0.1.0",
      instructions:
        "Execution tools retain their Codex session and call identifiers. Protocol declarations describe schemas, not execution support.",
      capabilities: .init(tools: .init()))
    await server.withMethodHandler(MCP.ListTools.self) { params in
      guard params.cursor == nil else { throw MCPError.invalidParams("Unknown tools cursor.") }
      return MCP.ListTools.Result(
        tools: ProtocolTools.definitions + execution.tools + (appServer?.tools ?? []))
    }
    await server.withMethodHandler(MCP.CallTool.self) { params in
      if ProtocolTools.definitions.contains(where: { $0.name == params.name }) {
        return try tools.call(name: params.name, arguments: params.arguments ?? [:])
      }
      let arguments = try JSONDecoder().decode(
        JSONValue.self, from: JSONEncoder().encode(params.arguments ?? [:]))
      do {
        if let appServer, appServer.tools.contains(where: { $0.name == params.name }) {
          return try await appServer.call(name: params.name, arguments: arguments)
        }
        return try await execution.call(name: params.name, arguments: arguments)
      } catch CodexToolError.unknownTool {
        throw MCPError.invalidParams("Unknown tool: \(params.name)")
      } catch {
        return .init(
          content: [
            .text(
              text: CodexApprovalRedactor.redactString(error.localizedDescription),
              annotations: nil, _meta: nil)
          ],
          isError: true)
      }
    }
    do {
      try await server.start(transport: transport)
      await server.waitUntilCompleted()
    } catch {
      await server.stop()
      await appServer?.shutdown()
      await execution.shutdown()
      throw error
    }
    await server.stop()
    await appServer?.shutdown()
    await execution.shutdown()
  }
}
