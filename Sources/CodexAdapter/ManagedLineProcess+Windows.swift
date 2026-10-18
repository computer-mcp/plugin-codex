#if os(Windows)
  import CodexAppServerRuntime
  import CodexAppServerStdio
  import Foundation
  import WinSDK

  /// The SDK owns launch, Job Object membership, pipes and joined native cleanup.
  /// The adapter owns shutdown deadlines and the lifetime reported in runtime receipts.
  final class ManagedLineProcess: Sendable {
    let inboundLines: AsyncThrowingStream<String, Error>
    private let transport: CodexAppServerStdioTransport
    private let state: ManagedWindowsProcessState
    private let lifecycle: Task<Void, Never>

    init(configuration: Configuration) throws {
      try configuration.validate()
      // Retain the configured owner's identity before admitting a child. The current
      // process is also protected by the SDK's non-inherited kill-on-close Job handle.
      let parent = try ManagedWindowsProcessParent(processID: configuration.ownerProcessID)
      let transport: CodexAppServerStdioTransport
      do {
        transport = try CodexAppServerStdioTransport(
          configuration: .init(
            executableURL: URL(fileURLWithPath: configuration.executable),
            arguments: configuration.arguments, environment: configuration.environment,
            workingDirectoryURL: configuration.workingDirectory,
            maximumMessageBytes: configuration.maximumMessageBytes))
      } catch {
        throw ManagedLineProcessError.launchFailed("Native process admission failed.")
      }
      self.transport = transport
      self.inboundLines = transport.inboundLines
      let state = ManagedWindowsProcessState(configuration: configuration, transport: transport)
      self.state = state
      let parentWait = parent.wait()
      let parentCleanup = Task.detached {
        switch await parentWait.value {
        case .stopped: return
        case .exited: await state.ownerEnded(failed: false)
        case .failed: await state.ownerEnded(failed: true)
        }
        await transport.close()
      }
      self.lifecycle = Task.detached {
        let result: Result<CodexAppServerStdioTransport.Termination, Error>
        do { result = .success(try await transport.waitForExit()) } catch {
          result = .failure(error)
        }
        parent.stop()
        await parentCleanup.value
        await state.finished(result)
      }
    }

    deinit {
      let transport = transport
      let lifecycle = lifecycle
      Task {
        await transport.close()
        await lifecycle.value
      }
    }

    func sendLine(_ line: String) async throws { try await state.send(line) }
    func close() async {
      await state.close()
      if await state.snapshot().cleanupConfirmed == true { await lifecycle.value }
    }
    func snapshot() async -> ManagedLineProcessSnapshot { await state.snapshot() }
  }

  private actor ManagedWindowsProcessState {
    private let configuration: ManagedLineProcess.Configuration
    private let transport: CodexAppServerStdioTransport
    private let startedAt = Date()
    private var state: ManagedLineProcessSnapshot.State = .running
    private var stoppedAt: Date?
    private var exitCode: Int32?
    private var signal: Int32?
    private var terminationEscalated = false
    private var pendingWrites = 0
    private var hasExited = false
    private var cleanupConfirmed = false
    private var lastError: String?
    private var closeTask: Task<Void, Never>?
    private var inputFinish: Task<Void, Never>?
    private var forcedClose: Task<Void, Never>?

    init(configuration: ManagedLineProcess.Configuration, transport: CodexAppServerStdioTransport) {
      self.configuration = configuration
      self.transport = transport
    }

    func send(_ line: String) async throws {
      guard state == .running else { throw ManagedLineProcessError.closed }
      pendingWrites += 1
      defer { pendingWrites -= 1 }
      do { try await transport.sendLine(line) } catch CodexAppServerStdioError.closed {
        throw ManagedLineProcessError.closed
      } catch let error as CodexAppServerConnectionFoundation.FoundationError {
        switch error {
        case .messageTooLarge(let limit): throw ManagedLineProcessError.oversizedMessage(limit)
        case .embeddedNewline: throw ManagedLineProcessError.invalidConfiguration
        case .bufferLimitExceeded: throw ManagedLineProcessError.bufferOverflow
        default: throw ManagedLineProcessError.launchFailed("Managed process I/O failed.")
        }
      } catch {
        throw ManagedLineProcessError.launchFailed("Managed process I/O failed.")
      }
    }

    func close() async {
      if let closeTask {
        await closeTask.value
        return
      }
      if cleanupConfirmed { return }
      if state == .running { state = .stopping }
      // The actor retains the shutdown owner through every caller's cancellation.
      let task = Task { await self.performClose() }
      closeTask = task
      await task.value
    }

    private func performClose() async {
      let finishing = Task { _ = try? await transport.finishInput() }
      inputFinish = finishing
      if await waitForCleanup(milliseconds: configuration.terminationGraceMilliseconds) {
        await finishing.value
        return
      }
      terminationEscalated = true
      let forced = Task { await transport.close() }
      forcedClose = forced
      if await waitForCleanup(milliseconds: configuration.killGraceMilliseconds) {
        await forced.value
        await finishing.value
      } else {
        // These tasks keep the exact SDK owner alive after the reporting deadline.
        // Only finished() can subsequently confirm cleanup and release the lifetime.
        state = .failed
        lastError = "Native process cleanup did not finish before the configured deadline."
      }
    }

    private func waitForCleanup(milliseconds: Int) async -> Bool {
      let deadline = ContinuousClock.now + .milliseconds(milliseconds)
      while !cleanupConfirmed {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return true
    }

    func ownerEnded(failed: Bool) {
      if state == .running { state = .stopping }
      terminationEscalated = true
      if failed {
        state = .failed
        lastError = "Native parent ownership observation failed."
      }
    }

    func finished(_ result: Result<CodexAppServerStdioTransport.Termination, Error>) async {
      await inputFinish?.value
      await forcedClose?.value
      stoppedAt = Date()
      switch result {
      case .success(let termination):
        hasExited = true
        cleanupConfirmed = true
        switch termination {
        case .exited(let code): exitCode = code
        case .signalled(let code): signal = code
        }
        if state != .failed { state = .stopped }
      case .failure:
        state = .failed
        lastError = "Native process cleanup could not be confirmed."
      }
    }

    func snapshot() -> ManagedLineProcessSnapshot {
      .init(
        state: state, processID: transport.processIdentifier, supervisorProcessID: nil,
        parentProcessID: configuration.ownerProcessID, processGroupID: nil,
        startedAt: startedAt, stoppedAt: stoppedAt, exitCode: exitCode, signal: signal,
        terminationEscalated: terminationEscalated, pendingWrites: pendingWrites,
        hasExited: hasExited, lastError: lastError, cleanupConfirmed: cleanupConfirmed)
    }
  }

  /// Both non-inheritable handles remain immutable until the native waiter completes.
  /// Closing the child never signals the borrowed owner process.
  private final class ManagedWindowsProcessParent: @unchecked Sendable {
    enum Result: Sendable { case exited, stopped, failed }
    private let process: HANDLE
    private let stopped: HANDLE

    init(processID: Int32) throws {
      guard let process = OpenProcess(DWORD(SYNCHRONIZE), false, DWORD(bitPattern: processID))
      else {
        throw ManagedLineProcessError.launchFailed("Cannot observe the configured process owner.")
      }
      guard WaitForSingleObject(process, 0) == DWORD(WAIT_TIMEOUT) else {
        CloseHandle(process)
        throw ManagedLineProcessError.launchFailed("The configured process owner is not running.")
      }
      guard let stopped = CreateEventW(nil, true, false, nil) else {
        CloseHandle(process)
        throw ManagedLineProcessError.launchFailed("Cannot create the process owner observation.")
      }
      self.process = process
      self.stopped = stopped
    }

    deinit {
      CloseHandle(stopped)
      CloseHandle(process)
    }

    func stop() { _ = SetEvent(stopped) }

    func wait() -> Task<Result, Never> {
      Task.detached {
        await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .utility).async { [self] in
            var handles: [HANDLE?] = [stopped, process]
            let result = WaitForMultipleObjects(2, &handles, false, DWORD(INFINITE))
            switch result {
            case DWORD(WAIT_OBJECT_0): continuation.resume(returning: .stopped)
            case DWORD(WAIT_OBJECT_0 + 1): continuation.resume(returning: .exited)
            default: continuation.resume(returning: .failed)
            }
          }
        }
      }
    }
  }
#endif
