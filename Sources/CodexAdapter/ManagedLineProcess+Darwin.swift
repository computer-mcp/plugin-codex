import Darwin
import Foundation
import Subprocess
import System

/// Owns one supervisor generation. The lock protects closeTask; all process state is actor-owned.
/// Admission cancellation and Foundation's callback reader use separate locks; no host process is adopted.
final class ManagedLineProcess: @unchecked Sendable {

  enum InputEvent: Equatable, Sendable {
    case writeStarted
    case writeSettled(bytesWritten: Int?)
    case finishStarted
    case terminationSignalled(Int32)
  }

  let inboundLines: AsyncThrowingStream<String, Error>

  private let configuration: Configuration
  private let state: ManagedLineProcessState
  private let launchTask: Task<Void, Never>
  private let closeLock = NSLock()
  private var closeTask: Task<Void, Never>?

  init(
    configuration: Configuration,
    inputObserver: (@Sendable (InputEvent) -> Void)? = nil
  ) throws {
    try configuration.validate()
    installBrokenPipeHandler()
    self.configuration = configuration
    let streamAndContinuation = AsyncThrowingStream<String, Error>.makeStream(
      bufferingPolicy: .bufferingOldest(16))
    self.inboundLines = streamAndContinuation.stream
    let state = ManagedLineProcessState(
      continuation: streamAndContinuation.continuation,
      maximumMessageBytes: configuration.maximumMessageBytes,
      ownerProcessID: configuration.ownerProcessID,
      inputObserver: inputObserver
    )
    self.state = state
    self.launchTask = Task.detached(priority: .userInitiated) {
      await Self.launch(configuration: configuration, state: state)
    }
  }

  func sendLine(_ line: String) async throws {
    try await state.send(line: line)
  }

  func close() async {
    let task = closeLock.withLock { () -> Task<Void, Never> in
      if let closeTask {
        return closeTask
      }
      let task = Task { [weak self] in
        if let self {
          await self.performClose()
        }
      }
      closeTask = task
      return task
    }
    await task.value
  }

  private func performClose() async {
    await state.beginShutdown()

    // The child has a separate job-control group. Do not kill its supervisor before
    // it publishes that group's identity, or a concurrently spawned child could escape.
    // Readiness also ensures EOF delivery sees the input writer attached during launch.
    let startupDeadline = ContinuousClock.now + .seconds(5)
    while !(await state.canSignalOwnedProcess()) {
      if ContinuousClock.now >= startupDeadline {
        await state.failTerminationTimeout()
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    let finishInput = Task {
      try? await state.finishInput()
    }

    // EOF waits for the admitted write; signal escalation remains independent
    // so process exit can cancel back-pressured I/O before the descriptor closes.
    if await waitForExit(milliseconds: configuration.terminationGraceMilliseconds) {
      await launchTask.value
      await finishInput.value
      return
    }

    if !(await state.signalChildGroup(SIGTERM)), let execution = await state.runningExecution() {
      try? execution.send(signal: .terminate, toProcessGroup: true)
    }
    if await waitForExit(milliseconds: configuration.terminationGraceMilliseconds) {
      await launchTask.value
      await finishInput.value
      return
    }

    if let execution = await state.runningExecution() {
      await state.recordTerminationEscalation()
      if !(await state.signalChildGroup(SIGKILL)) {
        try? execution.send(signal: .kill, toProcessGroup: true)
      }
    }

    if !(await waitForExit(milliseconds: configuration.killGraceMilliseconds)) {
      await state.failTerminationTimeout()
      return
    }
    await launchTask.value
    await finishInput.value
  }

  func snapshot() async -> ManagedLineProcessSnapshot {
    await state.snapshot()
  }

  private func waitForExit(milliseconds: Int) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(max(0, milliseconds))
    repeat {
      if await state.cleanupIsConfirmed() {
        return true
      }
      if ContinuousClock.now >= deadline {
        return false
      }
      try? await Task.sleep(for: .milliseconds(10))
    } while true
  }

  private static func launch(
    configuration: Configuration,
    state: ManagedLineProcessState
  ) async {
    var supervisorDirectory: URL?
    do {
      if await state.isShuttingDown() {
        await state.finish(status: .exited(0))
        return
      }
      let environment = Dictionary(
        uniqueKeysWithValues: configuration.environment.compactMap { key, value in
          Subprocess.Environment.Key(rawValue: key).map { ($0, value) }
        }
      )
      let supervisor = try makeSupervisor(configuration: configuration)
      supervisorDirectory = supervisor.directory
      let executable: Executable = .path(FilePath("/bin/sh"))
      var platformOptions = PlatformOptions()
      platformOptions.processGroupID = 0
      let standardOutput = try FileDescriptor.pipe()
      let outputReader = try ManagedLineProcessOutputReader(
        readEnd: standardOutput.readEnd,
        state: state
      )
      outputReader.start()
      do {
        let outcome = try await Subprocess.run(
          executable,
          arguments: Arguments(supervisor.arguments),
          environment: .custom(environment),
          workingDirectory: FilePath(configuration.workingDirectory.path),
          platformOptions: platformOptions,
          input: .inputWriter,
          output: .fileDescriptor(
            standardOutput.writeEnd,
            closeAfterSpawningProcess: true
          ),
          error: .sequence
        ) { execution in
          await state.attach(
            execution: execution,
            inputWriter: execution.standardInputWriter
          )
          guard let processID = await waitForProcessID(at: supervisor.processIDFile)
          else {
            try? execution.send(signal: .kill, toProcessGroup: true)
            try? await state.finishInput()
            throw ManagedLineProcessError.launchFailed(
              "The process supervisor did not report the child PID."
            )
          }
          await state.attachChild(processID: processID)
          do {
            for try await _ in execution.standardError {}
          } catch {
            await state.recordStreamError(error)
          }
          // run automatically finishes stdin when this body returns.
          try await state.finishInput()
        }
        await outputReader.stop(drainRemainingOutput: true)
        await state.finish(status: outcome.terminationStatus)
      } catch {
        await outputReader.stop(drainRemainingOutput: false)
        throw error
      }
    } catch {
      await state.failLaunch(error)
    }
    if let supervisorDirectory {
      try? FileManager.default.removeItem(at: supervisorDirectory)
    }
  }

  private struct SupervisorLaunch {
    let directory: URL
    let processIDFile: URL
    let arguments: [String]
  }

  private static func makeSupervisor(
    configuration: Configuration
  ) throws -> SupervisorLaunch {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("computer-mcp-process-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    let script = directory.appendingPathComponent("supervisor.sh")
    let processIDFile = directory.appendingPathComponent("child.pid")
    try Data(
      """
      #!/bin/sh
      set -m
      pid_file=$1
      owner_pid=$2
      grace_seconds=$3
      shift 3

      child=
      watchdog=
      timer=
      cleanup_timer() {
        if [ -n "$timer" ]; then
          kill -KILL "$timer" 2>/dev/null || true
          wait "$timer" 2>/dev/null || true
          timer=
        fi
      }
      terminate_group() {
        kill -TERM -- -"$child" 2>/dev/null || true
        # One owned timer measures elapsed grace independently of polling cost.
        /bin/sleep "$grace_seconds" &
        timer=$!
        while kill -0 -- -"$child" 2>/dev/null; do
          if ! kill -0 "$timer" 2>/dev/null; then
            kill -KILL -- -"$child" 2>/dev/null || true
            break
          fi
          /bin/sleep 0.01
        done
        cleanup_timer
      }
      cleanup() {
        trap - EXIT HUP INT TERM
        if [ -n "$child" ]; then
          if kill -0 -- -"$child" 2>/dev/null; then
            terminate_group
          fi
          wait "$child" 2>/dev/null || true
        fi
        if [ -n "$watchdog" ]; then
          kill -CONT "$watchdog" 2>/dev/null || true
          kill -TERM "$watchdog" 2>/dev/null || true
          wait "$watchdog" 2>/dev/null || true
        fi
      }
      trap cleanup EXIT HUP INT TERM

      "$@" <&0 >&1 2>&2 &
      child=$!
      exec 0<&-
      if ! printf '%s\n' "$child" > "$pid_file"; then exit 1; fi
      (
        trap '' HUP INT
        trap 'cleanup_timer; exit 0' TERM
        while kill -0 "$owner_pid" 2>/dev/null; do
          if ! kill -0 -- -"$child" 2>/dev/null; then exit 0; fi
          /bin/sleep 0.1
        done
        terminate_group
      ) </dev/null >/dev/null 2>&1 &
      watchdog=$!

      wait "$child"
      status=$?
      cleanup
      exit "$status"
      """.utf8
    ).write(to: script, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: script.path
    )
    let graceSeconds = Double(configuration.terminationGraceMilliseconds) / 1_000
    return SupervisorLaunch(
      directory: directory,
      processIDFile: processIDFile,
      arguments: [
        script.path,
        processIDFile.path,
        String(configuration.ownerProcessID),
        String(graceSeconds),
        configuration.executable,
      ] + configuration.arguments
    )
  }

  private static func waitForProcessID(at file: URL) async -> Int32? {
    for _ in 0..<500 {
      if Task.isCancelled { return nil }
      if let text = try? String(contentsOf: file, encoding: .utf8),
        let processID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        return processID
      }
      do { try await Task.sleep(for: .milliseconds(10)) } catch { return nil }
    }
    return nil
  }

}

/// File descriptor access and callback/task ownership are serialized by lock. Nonblocking reads
/// let shutdown drain a finite pipe without waiting on a descendant that retained stdout.
private final class ManagedLineProcessOutputReader: @unchecked Sendable {
  private let handle: FileHandle
  private let state: ManagedLineProcessState
  private let lock = NSLock()
  private var stopped = false
  private var consumptionTask: Task<Void, Never>?

  init(
    readEnd: FileDescriptor,
    state: ManagedLineProcessState
  ) throws {
    self.handle = FileHandle(fileDescriptor: readEnd.rawValue, closeOnDealloc: true)
    self.state = state
    let flags = fcntl(readEnd.rawValue, F_GETFL)
    guard flags >= 0, fcntl(readEnd.rawValue, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      throw ManagedLineProcessError.launchFailed(
        "Cannot configure the managed process output pipe.")
    }
  }

  func start() {
    arm()
  }

  func stop(drainRemainingOutput: Bool) async {
    let task = lock.withLock { () -> Task<Void, Never>? in
      if !stopped {
        stopped = true
        handle.readabilityHandler = nil
        if drainRemainingOutput {
          // A pipe holds fewer bytes than this budget. A concurrent writer cannot make drain infinite.
          var remaining = 1_048_576
          while remaining > 0, let data = readChunkLocked(), !data.isEmpty {
            remaining -= data.count
            enqueueLocked(data)
          }
          if remaining <= 0 {
            let previous = consumptionTask
            consumptionTask = Task { [state] in
              await previous?.value
              await state.recordStreamError(ManagedLineProcessError.bufferOverflow)
            }
          }
        }
        try? handle.close()
      }
      return consumptionTask
    }
    await task?.value
  }

  private func arm() {
    lock.withLock { armLocked() }
  }

  private func armLocked() {
    guard !stopped else { return }
    handle.readabilityHandler = { [weak self] handle in
      self?.consumeAvailableData(from: handle)
    }
  }

  private func consumeAvailableData(from handle: FileHandle) {
    lock.withLock {
      guard !stopped else { return }
      handle.readabilityHandler = nil
      guard let data = readChunkLocked() else {
        armLocked()
        return
      }
      guard !data.isEmpty else {
        stopped = true
        try? handle.close()
        return
      }
      enqueueLocked(data)
    }
  }

  private func readChunkLocked() -> Data? {
    var bytes = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
      if count >= 0 { return Data(bytes.prefix(count)) }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
      let previous = consumptionTask
      consumptionTask = Task { [state] in
        await previous?.value
        await state.recordStreamError(
          ManagedLineProcessError.launchFailed("Cannot read managed process stdout."))
      }
      return Data()
    }
  }

  private func enqueueLocked(_ data: Data) {
    let previous = consumptionTask
    consumptionTask = Task { [weak self, state] in
      await previous?.value
      do {
        try await state.appendStandardOutput(data)
        self?.arm()
      } catch {
        await state.recordStreamError(error)
        self?.stopProducing()
      }
    }
  }

  private func stopProducing() {
    lock.withLock {
      guard !stopped else { return }
      stopped = true
      handle.readabilityHandler = nil
      try? handle.close()
    }
  }
}

private typealias ManagedLineExecution = Execution<
  CustomWriteInput, FileDescriptorOutput, SequenceOutput
>

/// The lock orders synchronous caller cancellation against actor-owned write admission.
private final class ManagedLineInputAdmission: @unchecked Sendable {
  private enum State { case waiting, admitted, cancelled }
  private let lock = NSLock()
  private var state = State.waiting

  var isCancelled: Bool { lock.withLock { state == .cancelled } }

  func admit() -> Bool {
    lock.withLock {
      guard state == .waiting else { return false }
      state = .admitted
      return true
    }
  }

  func cancel() {
    lock.withLock {
      if state == .waiting { state = .cancelled }
    }
  }
}

private actor ManagedLineProcessState {
  private struct InputWrite {
    let admission: ManagedLineInputAdmission
    let frame: [UInt8]
    let continuation: CheckedContinuation<Void, Error>
  }

  private let continuation: AsyncThrowingStream<String, Error>.Continuation
  private let maximumMessageBytes: Int
  private let ownerProcessID: Int32
  private let inputObserver: (@Sendable (ManagedLineProcess.InputEvent) -> Void)?
  private var state: ManagedLineProcessSnapshot.State = .starting
  private var execution: ManagedLineExecution?
  private var inputWriter: StandardInputWriter?
  private var processID: Int32?
  private var supervisorProcessID: Int32?
  private var startedAt: Date?
  private var stoppedAt: Date?
  private var exitCode: Int32?
  private var signal: Int32?
  private var terminationEscalated = false
  private var writeQueue: [InputWrite] = []
  private var activeWrite: Task<Void, Never>?
  private var inputRetired = false
  private var inputFinished = false
  private var lastError: String?
  private var outputBuffer = Data()
  private var shutdownRequested = false
  private var launchFinished = false

  init(
    continuation: AsyncThrowingStream<String, Error>.Continuation,
    maximumMessageBytes: Int,
    ownerProcessID: Int32,
    inputObserver: (@Sendable (ManagedLineProcess.InputEvent) -> Void)?
  ) {
    self.continuation = continuation
    self.maximumMessageBytes = maximumMessageBytes
    self.ownerProcessID = ownerProcessID
    self.inputObserver = inputObserver
  }

  func attach(execution: ManagedLineExecution, inputWriter: StandardInputWriter) {
    self.execution = execution
    self.inputWriter = inputWriter
    supervisorProcessID = Int32(execution.processIdentifier.value)
    startedAt = Date()
    if shutdownRequested {
      state = .stopping
    }
  }

  func attachChild(processID: Int32) {
    self.processID = processID
    guard !shutdownRequested else { return }
    state = .running
    admitNextWrite()
  }

  func send(line: String) async throws {
    try Task.checkCancellation()
    switch state {
    case .starting, .running: break
    case .stopping, .stopped: throw ManagedLineProcessError.closed
    case .failed:
      throw ManagedLineProcessError.launchFailed(lastError ?? "Unknown launch failure.")
    }
    guard !inputRetired else { throw ManagedLineProcessError.closed }
    guard line.utf8.count <= maximumMessageBytes else {
      throw ManagedLineProcessError.oversizedMessage(maximumMessageBytes)
    }
    guard !line.contains("\n") else { throw ManagedLineProcessError.invalidConfiguration }
    let admission = ManagedLineInputAdmission()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        writeQueue.append(
          InputWrite(
            admission: admission, frame: Array((line + "\n").utf8), continuation: continuation))
        admitNextWrite()
      }
    } onCancel: {
      admission.cancel()
      Task { await self.cancelQueuedWrite(admission) }
    }
  }

  private func admitNextWrite() {
    guard activeWrite == nil, state == .running, !inputRetired, let inputWriter else { return }
    while !writeQueue.isEmpty {
      let write = writeQueue.removeFirst()
      guard write.admission.admit() else {
        write.continuation.resume(throwing: CancellationError())
        continue
      }
      // This unstructured task belongs to the input owner. Caller cancellation
      // cannot truncate an admitted frame; process-exit I/O cancellation still can.
      activeWrite = Task {
        inputObserver?(.writeStarted)
        let result: Result<Void, Error>
        do {
          let count = try await inputWriter.write(write.frame)
          inputObserver?(.writeSettled(bytesWritten: count))
          if count > 0 && count < write.frame.count {
            retireInput()
          }
          result =
            count == write.frame.count ? .success(()) : .failure(ManagedLineProcessError.closed)
        } catch {
          inputObserver?(.writeSettled(bytesWritten: nil))
          result = .failure(error)
        }
        activeWrite = nil
        write.continuation.resume(with: result)
        admitNextWrite()
      }
      return
    }
  }

  private func cancelQueuedWrite(_ admission: ManagedLineInputAdmission) {
    guard let index = writeQueue.firstIndex(where: { $0.admission === admission }) else { return }
    writeQueue.remove(at: index).continuation.resume(throwing: CancellationError())
  }

  private func retireInput(error: Error = ManagedLineProcessError.closed) {
    inputRetired = true
    let queued = writeQueue
    writeQueue.removeAll()
    for write in queued {
      write.continuation.resume(throwing: write.admission.isCancelled ? CancellationError() : error)
    }
  }

  func appendStandardOutput(_ data: Data) throws {
    guard !data.isEmpty else { return }
    outputBuffer.append(data)
    guard outputBuffer.count <= maximumMessageBytes || outputBuffer.contains(0x0A) else {
      let error = ManagedLineProcessError.oversizedMessage(maximumMessageBytes)
      continuation.finish(throwing: error)
      throw error
    }

    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      var line = outputBuffer[..<newline]
      if line.last == 0x0D {
        line = line.dropLast()
      }
      outputBuffer.removeSubrange(...newline)
      guard line.count <= maximumMessageBytes else {
        let error = ManagedLineProcessError.oversizedMessage(maximumMessageBytes)
        continuation.finish(throwing: error)
        throw error
      }
      guard let text = String(data: line, encoding: .utf8) else {
        let error = ManagedLineProcessError.launchFailed(
          "Managed process stdout was not valid UTF-8."
        )
        continuation.finish(throwing: error)
        throw error
      }
      switch continuation.yield(text) {
      case .enqueued: break
      case .dropped: throw ManagedLineProcessError.bufferOverflow
      case .terminated: throw ManagedLineProcessError.closed
      @unknown default: throw ManagedLineProcessError.closed
      }
    }
    guard outputBuffer.count <= maximumMessageBytes else {
      throw ManagedLineProcessError.oversizedMessage(maximumMessageBytes)
    }
  }

  func beginShutdown() {
    shutdownRequested = true
    retireInput()
    if state == .starting || state == .running {
      state = .stopping
    }
  }

  func finishInput() async throws {
    retireInput()
    await activeWrite?.value
    guard !inputFinished, let inputWriter else { return }
    inputFinished = true
    inputObserver?(.finishStarted)
    try await inputWriter.finish()
  }

  func runningExecution() -> ManagedLineExecution? {
    guard !hasFinished() else { return nil }
    return execution
  }

  func isShuttingDown() -> Bool { shutdownRequested }

  func canSignalOwnedProcess() -> Bool { processID != nil || hasFinished() }

  func signalChildGroup(_ signal: Int32) -> Bool {
    // The live supervisor pins the child identity. Its exit does not authorize signalling a reused group.
    guard !hasFinished(), let processID, processID > 1 else { return false }
    let signalled = Darwin.kill(-processID, signal) == 0 || errno == ESRCH
    if signalled { inputObserver?(.terminationSignalled(signal)) }
    return signalled
  }

  func recordTerminationEscalation() {
    terminationEscalated = true
  }

  func recordStreamError(_ error: Error) {
    guard state != .stopped else { return }
    lastError = Self.safeMessage(error)
    continuation.finish(throwing: error)
  }

  func finish(status: TerminationStatus) {
    launchFinished = true
    switch status {
    case .exited(let code):
      exitCode = code
    case .signaled(let code):
      signal = code
    }
    inputWriter = nil
    execution = nil
    stoppedAt = Date()
    if state != .failed {
      state = .stopped
    }
    retireInput()
    continuation.finish()
  }

  func failLaunch(_ error: Error) {
    guard !hasFinished() else { return }
    launchFinished = true
    state = .failed
    lastError = Self.safeMessage(error)
    stoppedAt = Date()
    inputWriter = nil
    execution = nil
    let launchError = ManagedLineProcessError.launchFailed(
      Self.safeMessage(error)
    )
    retireInput(error: launchError)
    continuation.finish(throwing: launchError)
  }

  func failTerminationTimeout() {
    guard !cleanupIsConfirmed() else { return }
    state = .failed
    let error = ManagedLineProcessError.terminationTimedOut(processID: processID)
    lastError = Self.safeMessage(error)
    stoppedAt = Date()
    retireInput()
    continuation.finish(throwing: error)
  }

  func hasFinished() -> Bool {
    launchFinished && execution == nil
  }

  func cleanupIsConfirmed() -> Bool {
    guard hasFinished() else { return false }
    guard let processID else { return supervisorProcessID == nil }
    return Darwin.kill(-processID, 0) == -1 && errno == ESRCH
  }

  func snapshot() -> ManagedLineProcessSnapshot {
    ManagedLineProcessSnapshot(
      state: hasFinished() && !cleanupIsConfirmed() ? .failed : state,
      processID: processID,
      supervisorProcessID: supervisorProcessID,
      parentProcessID: ownerProcessID,
      processGroupID: processID,
      startedAt: startedAt,
      stoppedAt: stoppedAt,
      exitCode: exitCode,
      signal: signal,
      terminationEscalated: terminationEscalated,
      pendingWrites: writeQueue.count + (activeWrite == nil ? 0 : 1),
      hasExited: hasFinished(),
      lastError: hasFinished() && !cleanupIsConfirmed()
        ? "Supervisor exited; child process-group cleanup is unconfirmed." : lastError,
      cleanupConfirmed: cleanupIsConfirmed()
    )
  }

  private static func safeMessage(_ error: Error) -> String {
    // Generic I/O errors can contain argv, environment values or protocol payloads.
    guard let error = error as? ManagedLineProcessError else {
      return "Managed process I/O failed."
    }
    return error.localizedDescription
  }
}
