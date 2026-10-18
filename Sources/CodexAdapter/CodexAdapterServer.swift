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
      let execution = try context.executionProvider(
        configuration: configuration, stateDirectory: stateDirectory)
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
    execution: CodexExecutionProvider = .init(exec: nil),
    appServer: CodexAppServerProvider? = nil
  ) async throws {
    let tools = ProtocolTools(inventory: try .bundled())
    if appServer != nil { try CodexAppServerMethodCatalog.validate() }
    let work = CodexWorkSnapshot {
      let executionWork = try await execution.exec?.workResources() ?? []
      let appWork = try await appServer?.appServer.workResources() ?? []
      return executionWork + appWork
    }
    let server = MCP.Server(
      name: "codex-mcp-adapter", version: CodexAdapterBuildInfo.version,
      instructions:
        "Execution tools retain their Codex session and call identifiers. Protocol declarations describe schemas, not execution support.",
      capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init()))
    await server.withMethodHandler(MCP.ListTools.self) { params in
      guard params.cursor == nil else { throw MCPError.invalidParams("Unknown tools cursor.") }
      return MCP.ListTools.Result(
        tools: try (ProtocolTools.definitions + execution.tools + (appServer?.tools ?? []))
          .map(CodexWorkSnapshot.declaring))
    }
    await server.withMethodHandler(MCP.ListResources.self) { params in
      guard params.cursor == nil else { throw MCPError.invalidParams("Unknown resources cursor.") }
      return .init(resources: [
        .init(name: "Runtime work", uri: CodexWorkSnapshot.uri, mimeType: "application/json")
      ])
    }
    await server.withMethodHandler(MCP.ReadResource.self) { params in
      guard params.uri == CodexWorkSnapshot.uri else {
        throw MCPError.invalidParams("Unknown resource URI.")
      }
      return try await work.read()
    }
    await server.withMethodHandler(MCP.CallTool.self) { params in
      let invocation = try CodexWorkInvocation.parse(params._meta)
      if ProtocolTools.definitions.contains(where: { $0.name == params.name }) {
        return try tools.call(name: params.name, arguments: params.arguments ?? [:])
      }
      let arguments = try JSONDecoder().decode(
        JSONValue.self, from: JSONEncoder().encode(params.arguments ?? [:]))
      do {
        return try await CodexWorkInvocation.$current.withValue(invocation) {
          if let appServer, appServer.tools.contains(where: { $0.name == params.name }) {
            return try await appServer.call(name: params.name, arguments: arguments)
          }
          return try await execution.call(name: params.name, arguments: arguments)
        }
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
      await work.shutdown()
      await appServer?.shutdown()
      await execution.shutdown()
      throw error
    }
    await server.stop()
    await work.shutdown()
    await appServer?.shutdown()
    await execution.shutdown()
  }
}
