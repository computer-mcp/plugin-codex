#if os(Windows)
  import Foundation
  import MCP
  import WinSDK

  @main
  struct HostPipeFixture {
    static func main() async {
      do { try await run() } catch { ExitProcess(10) }
    }

    static func run() async throws {
      let environment = ProcessInfo.processInfo.environment
      guard let endpoint = try MCPInheritedPipeEndpoint.inherited(environment: environment) else {
        ExitProcess(11)
      }
      // If this unrelated inheritable event escaped the host's explicit list,
      // setting it is observable in the parent irrespective of handle-number reuse.
      if let text = environment["FIXTURE_EXCLUDED_EVENT"], let value = UInt(text),
        let handle = HANDLE(bitPattern: value)
      {
        _ = SetEvent(handle)
      }
      let transport = try MCPInheritedPipeTransport(takingOwnershipOf: endpoint)
      var flags: DWORD = 0
      guard try endpoint.input.withHandle({ GetHandleInformation($0, &flags) }),
        flags & DWORD(HANDLE_FLAG_INHERIT) == 0,
        try endpoint.output.withHandle({ GetHandleInformation($0, &flags) }),
        flags & DWORD(HANDLE_FLAG_INHERIT) == 0
      else { ExitProcess(12) }
      let client = Client(name: "independent-plugin", version: "1")
      do {
        let initialized = try await client.connect(transport: transport)
        guard initialized.serverInfo.name == "independent-host" else { ExitProcess(13) }
        let request: RequestContext<CallTool.Result> = try await client.callTool(
          name: "echo",
          arguments: ["value": .int(Int.max), "pid": .int(Int(GetCurrentProcessId()))])
        guard try await request.value.structuredContent?.objectValue?["echo"] == .int(Int.max)
        else { ExitProcess(14) }
        guard try FileHandle.standardInput.readToEnd()?.isEmpty != false else { ExitProcess(15) }
        try FileHandle.standardOutput.write(contentsOf: Data("fixture-stdout\n".utf8))
        try FileHandle.standardError.write(contentsOf: Data("fixture-stderr\n".utf8))
      } catch {
        await client.disconnect()
        await transport.disconnect()
        throw error
      }
      await client.disconnect()
      await transport.disconnect()
    }
  }
#endif
