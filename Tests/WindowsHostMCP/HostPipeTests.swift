#if os(Windows)
  import Foundation
  import HostProcess
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

    @Test(
      "Independent child uses only inherited callback pipes and keeps standard streams separate")
    func independentChild() async throws {
      let pair = try PipePair()
      let transport = try MCPInheritedPipeTransport(takingOwnershipOf: pair.left)
      let child = try NativeHostChild(endpoint: pair.right)
      let pid = child.pid
      #expect(pid != GetCurrentProcessId())
      let server = Server(
        name: "independent-host", version: "1", capabilities: .init(tools: .init()))
      await server.withMethodHandler(CallTool.self) { request in
        #expect(request.arguments?["pid"] == .int(Int(pid)))
        return try CallTool.Result(
          content: [], structuredContent: .object(["echo": request.arguments?["value"] ?? .null]))
      }
      do {
        try await server.start(transport: transport)
        #expect(try await child.wait() == 0)
        #expect(child.output(standardError: false) == "fixture-stdout\n")
        #expect(child.output(standardError: true) == "fixture-stderr\n")
        #expect(!child.excludedEventWasInherited)
      } catch {
        #expect(child.stop())
        await server.stop()
        await transport.disconnect()
        throw error
      }
      await server.stop()
      await transport.disconnect()
    }

    @Test("Stopping an independent child blocked in initialization releases peer EOF")
    func stoppedChildReleasesEndpoint() async throws {
      let pair = try PipePair()
      let transport = try MCPInheritedPipeTransport(takingOwnershipOf: pair.left)
      let child = try NativeHostChild(endpoint: pair.right)
      do {
        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()
        let request = try #require(try await iterator.next())
        #expect(String(decoding: request, as: UTF8.self).contains("initialize"))
        #expect(child.stop())
        #expect(try await child.wait() != 0)
        #expect(try await iterator.next() == nil)
        #expect(!child.excludedEventWasInherited)
      } catch {
        #expect(child.stop())
        await transport.disconnect()
        throw error
      }
      await transport.disconnect()
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

  /// The native fixture owns one Job Object and never borrows the test runner's standard streams.
  private final class NativeHostChild {
    private let process: OpaquePointer
    private let excluded: MCPInheritedPipeHandle
    var pid: UInt32 { hmcp_pid(process) }

    init(endpoint: MCPInheritedPipeEndpoint) throws {
      defer {
        endpoint.input.close()
        endpoint.output.close()
      }
      var security = SECURITY_ATTRIBUTES()
      security.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
      security.bInheritHandle = true
      let event = try #require(CreateEventW(&security, true, false, nil))
      excluded = MCPInheritedPipeHandle(takingOwnershipOf: event)
      let environment = ProcessInfo.processInfo.environment
      let executable = try #require(environment["HOST_PIPE_FIXTURE_PATH"])
      var values = environment.filter {
        ![
          "COMPUTER_MCP_HOST_CONTEXT", "COMPUTER_MCP_HOST_FD",
          MCPInheritedPipeEndpoint.readEnvironmentKey, MCPInheritedPipeEndpoint.writeEnvironmentKey,
        ]
        .contains($0.key.uppercased())
      }
      values["COMPUTER_MCP_HOST_CONTEXT"] = "bound-by-fixture-host"
      values["FIXTURE_EXCLUDED_EVENT"] = String(UInt(bitPattern: event))
      var failure: UInt32 = 0
      process = try endpoint.input.withHandle { input in
        try endpoint.output.withHandle { output in
          #expect(
            SetHandleInformation(input, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT)))
          #expect(
            SetHandleInformation(output, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT)))
          values[MCPInheritedPipeEndpoint.readEnvironmentKey] = String(UInt(bitPattern: input))
          values[MCPInheritedPipeEndpoint.writeEnvironmentKey] = String(UInt(bitPattern: output))
          var block =
            Array(
              values.sorted { $0.key.lowercased() < $1.key.lowercased() }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "\0").utf16) + [0, 0]
          let launched = executable.withCString(encodedAs: UTF16.self) { path in
            hmcp_launch(path, &block, UInt(bitPattern: input), UInt(bitPattern: output), &failure)
          }
          return try #require(launched, "Native child launch failed: \(failure)")
        }
      }
    }

    var excludedEventWasInherited: Bool {
      (try? excluded.withHandle { WaitForSingleObject($0, 0) }) != DWORD(WAIT_TIMEOUT)
    }

    func wait() async throws -> UInt32 {
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      while true {
        var exit: UInt32 = 0
        switch hmcp_poll(process, &exit) {
        case 1: return exit
        case 0: break
        default: throw MCPError.internalError("Cannot observe fixture process exit")
        }
        guard ContinuousClock.now < deadline else {
          throw MCPError.internalError("Fixture process exit timed out")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    func stop() -> Bool { hmcp_stop(process) != 0 }
    func output(standardError: Bool) -> String {
      var bytes = [UInt8](repeating: 0, count: 1024)
      let count = hmcp_output(process, standardError ? 1 : 0, &bytes, bytes.count)
      return String(decoding: bytes.prefix(count), as: UTF8.self)
    }
    deinit { hmcp_destroy(process) }
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
