#if os(Windows)
  import Foundation
  import Logging
  import MCP
  @preconcurrency import SystemPackage
  import WinSDK
  import ucrt

  /// Read and write endpoints belong to this child, independently of its standard streams.
  struct MCPInheritedPipeEndpoint: Sendable {
    static let readEnvironmentKey = "COMPUTER_MCP_HOST_READ_HANDLE"
    static let writeEnvironmentKey = "COMPUTER_MCP_HOST_WRITE_HANDLE"
    let input: MCPInheritedPipeHandle
    let output: MCPInheritedPipeHandle

    static func inherited(environment: [String: String]) throws -> Self? {
      func value(_ name: String) throws -> String? {
        let matches = environment.filter { $0.key.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count <= 1 else {
          throw MCPError.invalidParams("Ambiguous inherited host environment.")
        }
        return matches.first?.value
      }
      let read = try value(readEnvironmentKey)
      let write = try value(writeEnvironmentKey)
      let legacy = try value("COMPUTER_MCP_HOST_FD")
      guard read != nil || write != nil || legacy != nil else { return nil }
      guard legacy == nil, try value("COMPUTER_MCP_HOST_CONTEXT") != nil,
        let read, let write, read != write
      else { throw MCPError.invalidParams("Incomplete inherited host pipe endpoints.") }
      let input = try inheritedHandle(read)
      let output = try inheritedHandle(write)
      return Self(
        input: MCPInheritedPipeHandle(takingOwnershipOf: input),
        output: MCPInheritedPipeHandle(takingOwnershipOf: output))
    }

    private static func inheritedHandle(_ text: String) throws -> HANDLE {
      guard let value = UInt(text), String(value) == text, value > 0, value < UInt.max,
        let handle = HANDLE(bitPattern: value)
      else { throw MCPError.invalidParams("Invalid inherited host pipe handle.") }
      var flags: DWORD = 0
      var mode: DWORD = 0
      guard handle != GetStdHandle(STD_INPUT_HANDLE), handle != GetStdHandle(STD_OUTPUT_HANDLE),
        handle != GetStdHandle(STD_ERROR_HANDLE), GetHandleInformation(handle, &flags),
        flags & DWORD(HANDLE_FLAG_INHERIT) != 0, GetFileType(handle) == DWORD(FILE_TYPE_PIPE),
        GetNamedPipeInfo(handle, &mode, nil, nil, nil), mode & DWORD(PIPE_TYPE_MESSAGE) == 0
      else { throw MCPError.invalidParams("Host transport requires inherited byte pipes.") }
      return handle
    }
  }

  /// Owns inherited endpoints until the MCP transport has duplicated them for native I/O.
  /// No endpoint name, listener or credential is accepted from tool arguments.
  actor MCPInheritedPipeTransport: Transport {
    nonisolated let logger = Logger(
      label: "mcp.inherited-pipe", factory: { _ in SwiftLogNoOpLogHandler() })
    private let descriptors: InheritedPipeDescriptors
    private let base: StdioTransport
    private var connection: Task<AsyncThrowingStream<Data, Error>, Error>?
    private var stream = AsyncThrowingStream<Data, Error> {
      $0.finish(throwing: MCPError.connectionClosed)
    }
    private var closing: Task<Void, Never>?

    init(
      takingOwnershipOf endpoint: MCPInheritedPipeEndpoint,
      maximumMessageBytes: Int = 1_048_576, maximumQueuedMessages: Int = 32,
      writeTimeout: Duration = .seconds(30)
    ) throws {
      let descriptors = try InheritedPipeDescriptors(endpoint)
      self.descriptors = descriptors
      base = StdioTransport(
        input: descriptors.input, output: descriptors.output,
        maximumMessageBytes: maximumMessageBytes, maximumQueuedMessages: maximumQueuedMessages,
        maximumQueuedBytes: 16_777_216, writeTimeout: writeTimeout)
    }

    func connect() async throws {
      guard closing == nil else { throw MCPError.connectionClosed }
      if let connection {
        stream = try await connection.value
        try await base.connect()
        return
      }
      let task = Task { [base, descriptors] in
        defer { descriptors.close() }
        try await base.connect()
        return await base.receive()
      }
      connection = task
      stream = try await task.value
      guard closing == nil else { throw MCPError.connectionClosed }
    }

    func send(_ data: Data) async throws { try await base.send(data) }
    func receive() -> AsyncThrowingStream<Data, Error> { stream }

    func disconnect() async {
      if let closing {
        await closing.value
        return
      }
      let task = Task { [base, descriptors, connection] in
        await base.disconnect()
        _ = await connection?.result
        descriptors.close()
      }
      closing = task
      await task.value
    }
  }

  /// The lock serializes native handle borrowing with its once-only close.
  final class MCPInheritedPipeHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: HANDLE?
    init(takingOwnershipOf handle: HANDLE) { self.handle = handle }
    func withHandle<T>(_ body: (HANDLE) throws -> T) throws -> T {
      try lock.withLock {
        guard let handle else { throw MCPError.connectionClosed }
        return try body(handle)
      }
    }
    func close() {
      lock.withLock {
        guard let handle else { return }
        self.handle = nil
        CloseHandle(handle)
      }
    }
    deinit { close() }
  }

  private final class InheritedPipeDescriptors: @unchecked Sendable {
    let input: FileDescriptor
    let output: FileDescriptor
    private let endpoint: MCPInheritedPipeEndpoint
    private let lock = NSLock()
    private var closed = false

    init(_ endpoint: MCPInheritedPipeEndpoint) throws {
      self.endpoint = endpoint
      input = try Self.duplicate(endpoint.input, reading: true)
      do {
        output = try Self.duplicate(endpoint.output, reading: false)
      } catch {
        _ = ucrt._close(input.rawValue)
        throw error
      }
    }

    private static func duplicate(_ file: MCPInheritedPipeHandle, reading: Bool) throws
      -> FileDescriptor
    {
      try file.withHandle { handle in
        var mode: DWORD = 0
        guard GetFileType(handle) == DWORD(FILE_TYPE_PIPE),
          GetNamedPipeInfo(handle, &mode, nil, nil, nil), mode & DWORD(PIPE_TYPE_MESSAGE) == 0,
          SetHandleInformation(handle, DWORD(HANDLE_FLAG_INHERIT), 0)
        else { throw MCPError.invalidParams("Host transport requires owned byte pipes.") }
        var duplicate: HANDLE?
        guard
          DuplicateHandle(
            GetCurrentProcess(), handle, GetCurrentProcess(), &duplicate, 0, false,
            DWORD(DUPLICATE_SAME_ACCESS)), let duplicate
        else { throw MCPError.connectionClosed }
        let descriptor = ucrt._open_osfhandle(
          Int(bitPattern: duplicate), (reading ? _O_RDONLY : _O_WRONLY) | _O_BINARY | _O_NOINHERIT)
        guard descriptor >= 0 else {
          CloseHandle(duplicate)
          throw MCPError.connectionClosed
        }
        return FileDescriptor(rawValue: descriptor)
      }
    }

    func close() {
      lock.withLock {
        guard !closed else { return }
        closed = true
        _ = ucrt._close(input.rawValue)
        _ = ucrt._close(output.rawValue)
        endpoint.input.close()
        endpoint.output.close()
      }
    }

    deinit { close() }
  }
#endif
