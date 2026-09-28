#if os(Windows)
  import Foundation
  import MCP
  import Testing
  import WinSDK

  @testable import HostPipe

  @Suite("Native inherited host MCP pipes", .serialized, .timeLimit(.minutes(1)))
  struct HostPipeTests {
    @Test("Standard MCP callbacks retain exact integer payloads")
    func standardMCP() async throws {
      let pair = try PipePair()
      let serverTransport = try MCPInheritedPipeTransport(takingOwnershipOf: pair.left)
      let clientTransport = try MCPInheritedPipeTransport(takingOwnershipOf: pair.right)
      let server = Server(name: "host-pipe", version: "1", capabilities: .init(tools: .init()))
      await server.withMethodHandler(CallTool.self) { request in
        try CallTool.Result(
          content: [],
          structuredContent: Value.object(["echo": request.arguments?["value"] ?? .null]))
      }
      let client = Client(name: "owned-plugin", version: "1")
      do {
        try await server.start(transport: serverTransport)
        let initialized = try await client.connect(transport: clientTransport)
        #expect(initialized.serverInfo.name == "host-pipe")
        let request: RequestContext<CallTool.Result> = try await client.callTool(
          name: "echo", arguments: ["value": .int(Int.max)])
        #expect(try await request.value.structuredContent?.objectValue?["echo"] == .int(Int.max))
      } catch {
        await client.disconnect()
        await server.stop()
        await clientTransport.disconnect()
        await serverTransport.disconnect()
        throw error
      }
      await client.disconnect()
      await server.stop()
      await clientTransport.disconnect()
      await serverTransport.disconnect()
    }

    @Test("Connected transport consumes original endpoints and concurrent close reaches peer EOF")
    func endpointOwnership() async throws {
      let pair = try PipePair()
      let left = try MCPInheritedPipeTransport(takingOwnershipOf: pair.left)
      let right = try MCPInheritedPipeTransport(takingOwnershipOf: pair.right)
      do {
        try await left.connect()
        try await right.connect()
        #expect(throws: (any Error).self) { try pair.left.output.withHandle { _ in } }
        #expect(throws: (any Error).self) { try pair.left.input.withHandle { _ in } }
        async let first: Void = left.disconnect()
        async let second: Void = left.disconnect()
        _ = await (first, second)
        var iterator = await right.receive().makeAsyncIterator()
        #expect(try await iterator.next() == nil)
        await #expect(throws: (any Error).self) { try await left.connect() }
      } catch {
        await left.disconnect()
        await right.disconnect()
        throw error
      }
      await right.disconnect()
    }

    @Test("Inherited handles require exact paired provenance and lose inheritance on admission")
    func inheritedAdmission() async throws {
      let pair = try PipePair()
      let input = try HandleLease(duplicating: pair.left.input)
      let output = try HandleLease(duplicating: pair.left.output)
      let environment = [
        "COMPUTER_MCP_HOST_CONTEXT": "bound-by-host",
        MCPInheritedPipeEndpoint.readEnvironmentKey: input.text,
        MCPInheritedPipeEndpoint.writeEnvironmentKey: output.text,
      ]
      let endpoint = try #require(MCPInheritedPipeEndpoint.inherited(environment: environment))
      input.transfer()
      output.transfer()
      let transport = try MCPInheritedPipeTransport(takingOwnershipOf: endpoint)
      var inputFlags: DWORD = 0
      var outputFlags: DWORD = 0
      #expect(try endpoint.input.withHandle { GetHandleInformation($0, &inputFlags) })
      #expect(try endpoint.output.withHandle { GetHandleInformation($0, &outputFlags) })
      #expect(inputFlags & DWORD(HANDLE_FLAG_INHERIT) == 0)
      #expect(outputFlags & DWORD(HANDLE_FLAG_INHERIT) == 0)
      await transport.disconnect()
      #expect(throws: (any Error).self) { try endpoint.output.withHandle { _ in } }
    }

    @Test("Missing, ambiguous, standard-stream and noninherited handles are not consumed")
    func rejectedAdmission() throws {
      let pair = try PipePair()
      #expect(try MCPInheritedPipeEndpoint.inherited(environment: [:]) == nil)
      let values = ["", "0", "-1", "01", " 12", "12x", String(UInt.max)]
      for value in values {
        #expect(throws: (any Error).self) {
          try MCPInheritedPipeEndpoint.inherited(environment: [
            "COMPUTER_MCP_HOST_CONTEXT": "bound-by-host",
            MCPInheritedPipeEndpoint.readEnvironmentKey: value,
            MCPInheritedPipeEndpoint.writeEnvironmentKey: "1",
          ])
        }
      }
      let read = try pair.left.input.withHandle { String(UInt(bitPattern: $0)) }
      let write = try pair.left.output.withHandle { String(UInt(bitPattern: $0)) }
      let environment = [
        "COMPUTER_MCP_HOST_CONTEXT": "bound-by-host",
        MCPInheritedPipeEndpoint.readEnvironmentKey: read,
        MCPInheritedPipeEndpoint.writeEnvironmentKey: write,
      ]
      #expect(throws: (any Error).self) {
        try MCPInheritedPipeEndpoint.inherited(environment: environment)
      }
      var ambiguous = environment
      ambiguous[MCPInheritedPipeEndpoint.readEnvironmentKey.lowercased()] = read
      #expect(throws: (any Error).self) {
        try MCPInheritedPipeEndpoint.inherited(environment: ambiguous)
      }
      var standard = environment
      let standardInput = try #require(GetStdHandle(STD_INPUT_HANDLE))
      standard[MCPInheritedPipeEndpoint.readEnvironmentKey] = String(
        UInt(bitPattern: standardInput))
      #expect(throws: (any Error).self) {
        try MCPInheritedPipeEndpoint.inherited(environment: standard)
      }
      var flags: DWORD = 0
      #expect(try pair.left.input.withHandle { GetHandleInformation($0, &flags) })
      #expect(try pair.left.output.withHandle { GetHandleInformation($0, &flags) })
    }

    @Test("A pre-cancelled receiver releases native endpoints and permits peer EOF")
    func cancelledReceive() async throws {
      let pair = try PipePair()
      let left = try MCPInheritedPipeTransport(takingOwnershipOf: pair.left)
      let right = try MCPInheritedPipeTransport(takingOwnershipOf: pair.right)
      do {
        try await left.connect()
        try await right.connect()
        let stream = await left.receive()
        let cancelled = Task {
          withUnsafeCurrentTask { $0?.cancel() }
          var iterator = stream.makeAsyncIterator()
          _ = try? await iterator.next()
        }
        await cancelled.value
        var iterator = await right.receive().makeAsyncIterator()
        #expect(try await iterator.next() == nil)
      } catch {
        await left.disconnect()
        await right.disconnect()
        throw error
      }
      await left.disconnect()
      await right.disconnect()
    }
  }

  private struct PipePair: Sendable {
    let left: MCPInheritedPipeEndpoint
    let right: MCPInheritedPipeEndpoint
    init() throws {
      func pipe() throws -> (MCPInheritedPipeHandle, MCPInheritedPipeHandle) {
        var read: HANDLE?
        var write: HANDLE?
        guard CreatePipe(&read, &write, nil, 4096), let read, let write else {
          throw MCPError.connectionClosed
        }
        return (
          MCPInheritedPipeHandle(takingOwnershipOf: read),
          MCPInheritedPipeHandle(takingOwnershipOf: write)
        )
      }
      let request = try pipe()
      let response = try pipe()
      left = MCPInheritedPipeEndpoint(input: request.0, output: response.1)
      right = MCPInheritedPipeEndpoint(input: response.0, output: request.1)
    }
  }

  /// A duplicate is transferred exactly once; failed admission leaves cleanup with the fixture.
  private final class HandleLease {
    private var owned: HANDLE?
    let text: String
    init(duplicating file: MCPInheritedPipeHandle) throws {
      var copy: HANDLE?
      guard
        try file.withHandle({
          DuplicateHandle(
            GetCurrentProcess(), $0, GetCurrentProcess(), &copy, 0, true,
            DWORD(DUPLICATE_SAME_ACCESS))
        }), let copy
      else { throw MCPError.connectionClosed }
      owned = copy
      text = String(UInt(bitPattern: copy))
    }
    func transfer() { owned = nil }
    deinit { if let owned { CloseHandle(owned) } }
  }
#endif
