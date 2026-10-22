import Darwin
import Foundation
import Testing

@testable import CodexAdapter

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ManagedLineProcessLifecycleTests {
  @Test
  func overlappingLargeFramesArriveIntactInFIFOOrder() async throws {
    try await withGatedInputProcess { process, gate, probe in
      var lines = process.inboundLines.makeAsyncIterator()
      let capacityLine = try #require(try await lines.next())
      let pipeCapacity = try #require(Int(capacityLine))
      let frames = [
        "{\"id\":1,\"payload\":\"" + String(repeating: "a", count: 1_048_576) + "\"}",
        "{\"id\":2,\"payload\":\"" + String(repeating: "b", count: 1_048_576) + "\"}",
        String(repeating: "λ", count: 350_000),
      ]
      try #require(frames.allSatisfy { $0.utf8.count > pipeCapacity })

      let first = Task { try await process.sendLine(frames[0]) }
      try await requireBackpressure(in: probe, reading: &lines)
      let second = Task { try await process.sendLine(frames[1]) }
      try await waitForPendingWrites(2, in: process)
      let third = Task { try await process.sendLine(frames[2]) }
      try await waitForPendingWrites(3, in: process)

      try gate.write(contentsOf: Data("R".utf8))
      try await first.value
      try await second.value
      try await third.value
      for frame in frames { #expect(try await lines.next() == frame) }
      let running = await process.snapshot()
      #expect(running.state == .running && !running.hasExited)
      #expect(running.pendingWrites == 0)
      #expect(kill(try #require(running.processID), 0) == 0)
      #expect(probe.events.filter { $0 == .writeStarted }.count == frames.count)
    }
  }

  @Test
  func cancelledQueuedWriterLeavesBeforeTheActiveWriteUnblocks() async throws {
    try await withGatedInputProcess { process, gate, probe in
      var lines = process.inboundLines.makeAsyncIterator()
      _ = try #require(try await lines.next())
      let frame = String(repeating: "a", count: 1_048_576)
      let first = Task { try await process.sendLine(frame) }
      try await requireBackpressure(in: probe, reading: &lines)
      let cancelled = Task {
        defer { probe.completeCaller(1) }
        try await process.sendLine("cancelled frame")
      }
      try await waitForPendingWrites(2, in: process)
      let next = Task { try await process.sendLine("next frame") }
      try await waitForPendingWrites(3, in: process)

      cancelled.cancel()
      try await waitFor("queued cancellation before opening the read gate") { probe.didComplete(1) }
      await #expect(throws: CancellationError.self) { try await cancelled.value }
      try await waitForPendingWrites(2, in: process)
      #expect(probe.events == [.writeStarted])

      try gate.write(contentsOf: Data("R".utf8))
      try await first.value
      try await next.value
      #expect(try await lines.next() == frame)
      #expect(try await lines.next() == "next frame")
      #expect(await process.snapshot().pendingWrites == 0)
    }
  }

  @Test
  func cancellingTheActiveCallerPreservesItsFrameAndTheInput() async throws {
    try await withGatedInputProcess { process, gate, probe in
      var lines = process.inboundLines.makeAsyncIterator()
      _ = try #require(try await lines.next())
      let frame = String(repeating: "a", count: 1_048_576)
      let first = Task {
        defer { probe.completeCaller(1) }
        try await process.sendLine(frame)
      }
      try await requireBackpressure(in: probe, reading: &lines)
      first.cancel()
      let next = Task { try await process.sendLine("next frame") }
      try await waitForPendingWrites(2, in: process)
      #expect(!probe.didComplete(1))
      #expect(probe.events == [.writeStarted])

      try gate.write(contentsOf: Data("R".utf8))
      try await first.value
      try await next.value
      #expect(try await lines.next() == frame)
      #expect(try await lines.next() == "next frame")
      #expect(probe.events.contains(.writeSettled(bytesWritten: frame.utf8.count + 1)))
      #expect(await process.snapshot().state == .running)
      #expect(await process.snapshot().pendingWrites == 0)
    }
  }

  @Test
  func alreadyCancelledCallerNeverWrites() async throws {
    try await withGatedInputProcess { process, gate, probe in
      var lines = process.inboundLines.makeAsyncIterator()
      _ = try #require(try await lines.next())
      let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await process.sendLine("cancelled frame")
      }
      await #expect(throws: CancellationError.self) { try await cancelled.value }
      #expect(probe.events.isEmpty)
      #expect(await process.snapshot().pendingWrites == 0)

      let frame = String(repeating: "a", count: 1_048_576)
      let next = Task { try await process.sendLine(frame) }
      try await requireBackpressure(in: probe, reading: &lines)
      try gate.write(contentsOf: Data("R".utf8))
      try await next.value
      #expect(try await lines.next() == frame)
    }
  }

  @Test
  func processExitDuringWriteRetiresInputBeforeTheQueuedWrite() async throws {
    try await withGatedInputProcess(retainInputAfterExit: true) { process, gate, probe in
      var lines = process.inboundLines.makeAsyncIterator()
      _ = try #require(try await lines.next())
      let frame = String(repeating: "x", count: 1_048_576)
      let first = Task { try await process.sendLine(frame) }
      try await requireBackpressure(in: probe, reading: &lines)
      let queued = Task { try await process.sendLine("queued frame") }
      try await waitForPendingWrites(2, in: process)

      try gate.write(contentsOf: Data("X".utf8))
      await expectClosed(first)
      await expectClosed(queued)
      let count = try #require(
        probe.events.compactMap { event -> Int? in
          if case .writeSettled(let count) = event { return count }
          return nil
        }.first)
      #expect(count > 0 && count < frame.utf8.count + 1)
      #expect(probe.events.filter { $0 == .writeStarted }.count == 1)
      await expectClosed(Task { try await process.sendLine("later frame") })
      await process.close()
      #expect(await process.snapshot().pendingWrites == 0)
      #expect(await process.snapshot().cleanupConfirmed == true)
      try requireFinishAfterWrite(in: probe)
    }
  }

  @Test
  func inputRemainsOpenAcrossRequestsAndCloseDeliversEOF() async throws {
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/bin/sh",
        arguments: [
          "-c", #"while IFS= read -r line; do printf '%s\n' "$line"; done; printf 'eof\n'"#,
        ],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 2_000))
    do {
      var lines = process.inboundLines.makeAsyncIterator()
      for line in ["first", "second"] {
        try await process.sendLine(line)
        #expect(try await lines.next() == line)
      }
      await process.close()
      #expect(try await lines.next() == "eof")
      #expect(try await lines.next() == nil)
      let result = await process.snapshot()
      #expect(result.hasExited && result.exitCode == 0)
      #expect(result.cleanupConfirmed == true)
      #expect(!result.terminationEscalated && result.pendingWrites == 0)
    } catch {
      await process.close()
      throw error
    }
  }

  @Test
  func closeSignalsBeforeDrainingAndFinishesAfterTheWriteSettles() async throws {
    try await withGatedInputProcess(ignoreTermination: true) { process, _, probe in
      var lines = process.inboundLines.makeAsyncIterator()
      _ = try #require(try await lines.next())
      let childLine = try #require(try await lines.next())
      let child = try #require(Int32(childLine))
      let writing = Task { try await process.sendLine(String(repeating: "x", count: 1_048_576)) }
      try await requireBackpressure(in: probe, reading: &lines)
      let queued = Task {
        defer { probe.completeCaller(1) }
        try await process.sendLine("queued frame")
      }
      try await waitForPendingWrites(2, in: process)

      let started = ContinuousClock.now
      let first = Task { await process.close() }
      let second = Task { await process.close() }
      try await waitFor("queued write rejected during termination") { probe.didComplete(1) }
      await expectClosed(queued)
      try await waitFor("TERM delivered during the blocked write") {
        probe.events.contains(.terminationSignalled(SIGTERM))
      }
      #expect(started.duration(to: .now) < .seconds(3))
      await first.value
      await second.value
      #expect(started.duration(to: .now) < .seconds(3))
      if case .success = await writing.result { Issue.record("An incomplete frame must fail.") }
      let events = probe.events
      let term = try #require(events.firstIndex(of: .terminationSignalled(SIGTERM)))
      let settled = try #require(
        events.firstIndex {
          if case .writeSettled = $0 { return true }
          return false
        })
      #expect(term < settled)
      try requireFinishAfterWrite(in: probe)
      #expect(events.filter { $0 == .writeStarted }.count == 1)
      let result = await process.snapshot()
      #expect(result.hasExited && result.terminationEscalated)
      #expect(result.pendingWrites == 0 && result.cleanupConfirmed == true)
      #expect(kill(child, 0) == -1 && errno == ESRCH)
      #expect(kill(try #require(result.processID), 0) == -1 && errno == ESRCH)
      #expect(kill(try #require(result.supervisorProcessID), 0) == -1 && errno == ESRCH)
    }
  }

  @Test
  func brokenInputPipeReportsTheLibraryError() async throws {
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/bin/sh",
        arguments: ["-c", "exec 0<&-; printf 'ready\\n'; exec /bin/sleep 30"],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 100))
    do {
      var lines = process.inboundLines.makeAsyncIterator()
      #expect(try await lines.next() == "ready")
      do {
        try await process.sendLine("write to a closed child input")
        Issue.record("A broken input pipe must fail the write.")
      } catch {
        #expect(!(error is ManagedLineProcessError))
      }
      #expect(await process.snapshot().pendingWrites == 0)
      await process.close()
      #expect(await process.snapshot().cleanupConfirmed == true)
    } catch {
      await process.close()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func outputRejectsOversizedFrames(newline: Bool) async throws {
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/bin/sh",
        arguments: ["-c", newline ? "printf '%065d\\n' 0" : "printf '%065d' 0"],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 100, maximumMessageBytes: 64))
    await #expect(throws: (any Error).self) {
      for try await _ in process.inboundLines { Issue.record("An oversized frame was delivered.") }
    }
    await process.close()
    #expect(await process.snapshot().hasExited)
    #expect(await process.snapshot().lastError?.contains("64 bytes") == true)
  }

  @Test
  func outputQueueOverflowIsReported() async throws {
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/bin/sh",
        arguments: ["-c", "i=0; while [ $i -lt 32 ]; do printf 'line\\n'; i=$((i+1)); done"],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 100))
    let deadline = ContinuousClock.now + .seconds(2)
    while await process.snapshot().lastError == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    var count = 0
    do {
      for try await _ in process.inboundLines { count += 1 }
      Issue.record("The bounded output queue must report overflow.")
    } catch {
      if case ManagedLineProcessError.bufferOverflow = error {
        #expect(count == 16)
      } else {
        Issue.record("Expected output queue overflow, received \(error).")
      }
    }
    await process.close()
    #expect(await process.snapshot().cleanupConfirmed == true)
  }

  @Test
  func managedChildStartsWithDefaultSIGPIPE() async throws {
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/bin/sh", arguments: ["-c", "kill -PIPE $$; echo survived"],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 100))
    var lines = process.inboundLines.makeAsyncIterator()
    #expect(try await lines.next() == nil)
    await process.close()
    let result = await process.snapshot()
    // The supervisor reports a signaled child's shell wait status.
    #expect(result.exitCode == 128 + SIGPIPE)
    #expect(result.cleanupConfirmed == true)
  }

  @Test
  func foundationChildStartsWithDefaultSIGPIPE() async throws {
    let managed = try ManagedLineProcess(
      configuration: .init(
        executable: "/usr/bin/true", workingDirectory: FileManager.default.temporaryDirectory))
    await managed.close()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", "kill -PIPE $$; echo survived"]
    let output = Pipe()
    child.standardOutput = output
    try child.run()
    child.waitUntilExit()
    #expect(child.terminationReason == .uncaughtSignal)
    #expect(child.terminationStatus == SIGPIPE)
    #expect(try (output.fileHandleForReading.readToEnd() ?? Data()).isEmpty)
  }

  private func waitFor(_ reason: String, until condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for \(reason).")
      try Task.checkCancellation()
      await Task.yield()
    }
  }

  private func waitForPendingWrites(_ count: Int, in process: ManagedLineProcess) async throws {
    try await waitFor("\(count) pending writes") { await process.snapshot().pendingWrites == count }
  }

  private func requireBackpressure(
    in probe: InputProbe, reading lines: inout AsyncThrowingStream<String, Error>.Iterator
  ) async throws {
    // The child reports a full pipe without reading from it. The owner separately
    // reports entry into write after validation; queue depth alone proves neither.
    try #require(try await lines.next() == "blocked")
    try await waitFor("admitted write") { probe.events.contains(.writeStarted) }
    try #require(probe.events == [.writeStarted])
  }

  private func requireFinishAfterWrite(in probe: InputProbe) throws {
    let events = probe.events
    let settled = try #require(
      events.firstIndex {
        if case .writeSettled = $0 { return true }
        return false
      })
    let finish = try #require(events.firstIndex(of: .finishStarted))
    #expect(settled < finish)
  }

  private func expectClosed(_ task: Task<Void, Error>) async {
    do {
      try await task.value
      Issue.record("Expected the closed transport error.")
    } catch ManagedLineProcessError.closed {
    } catch {
      Issue.record("Expected the closed transport error, received \(error).")
    }
  }

  private func withGatedInputProcess(
    ignoreTermination: Bool = false,
    retainInputAfterExit: Bool = false,
    _ body: (ManagedLineProcess, FileHandle, InputProbe) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("read-gate").path
    let holderPath = directory.appendingPathComponent("holder.pid")
    try #require(mkfifo(path, 0o600) == 0)
    let descriptor = open(path, O_RDWR | O_NONBLOCK)
    try #require(descriptor >= 0)
    let gate = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? gate.close() }
    let probe = InputProbe()
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/usr/bin/python3",
        arguments: [
          "-c",
          """
          import array, fcntl, os, select, signal, subprocess, sys, termios
          if sys.argv[2] == "True":
              signal.signal(signal.SIGTERM, signal.SIG_IGN)
              child = subprocess.Popen(["/bin/sleep", "30"])
          if sys.argv[3] == "True":
              ready_read, ready_write = os.pipe()
              holder = os.fork()
              if holder == 0:
                  os.close(ready_read)
                  os.setsid()
                  os.close(1)
                  os.close(2)
                  os.write(ready_write, b"ready")
                  os.close(ready_write)
                  # Keep stdin open beyond supervisor exit, without consuming it.
                  select.select([], [], [])
                  os._exit(0)
              os.close(ready_write)
              os.read(ready_read, 5)
              os.close(ready_read)
              with open(sys.argv[4], "w") as pid_file:
                  pid_file.write(str(holder))
          with open(sys.argv[1], "rb", buffering=0) as gate:
              print(os.fstat(0).st_blksize, flush=True)
              if sys.argv[2] == "True":
                  print(child.pid, flush=True)
              select.select([0], [], [])
              while True:
                  available = array.array("i", [0])
                  fcntl.ioctl(0, termios.FIONREAD, available, True)
                  if available[0] >= os.fstat(0).st_blksize:
                      break
              print("blocked", flush=True)
              command = gate.read(1)
              if command == b"X":
                  os._exit(0)
          for line in sys.stdin.buffer:
              sys.stdout.buffer.write(line)
              sys.stdout.buffer.flush()
          """,
          path, ignoreTermination ? "True" : "False", retainInputAfterExit ? "True" : "False",
          holderPath.path,
        ],
        workingDirectory: directory,
        terminationGraceMilliseconds: 100, maximumMessageBytes: 2_097_152),
      inputObserver: { probe.record($0) })
    do {
      try await body(process, gate, probe)
      await process.close()
      try await stopInputHolder(at: holderPath)
      #expect(await process.snapshot().cleanupConfirmed == true)
    } catch {
      await process.close()
      try await stopInputHolder(at: holderPath)
      throw error
    }
  }

  private func stopInputHolder(at path: URL) async throws {
    guard let text = try? String(contentsOf: path, encoding: .utf8), let pid = Int32(text) else {
      return
    }
    try FileManager.default.removeItem(at: path)
    #expect(kill(pid, SIGKILL) == 0)
    try await waitFor("input holder exit") { kill(pid, 0) == -1 && errno == ESRCH }
  }
}

/// The lock protects observations made by the input owner and caller tasks.
private final class InputProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedEvents: [ManagedLineProcess.InputEvent] = []
  private var completedCallers: Set<Int> = []

  var events: [ManagedLineProcess.InputEvent] { lock.withLock { recordedEvents } }

  func record(_ event: ManagedLineProcess.InputEvent) {
    lock.withLock { recordedEvents.append(event) }
  }

  func completeCaller(_ id: Int) {
    _ = lock.withLock { completedCallers.insert(id) }
  }

  func didComplete(_ id: Int) -> Bool { lock.withLock { completedCallers.contains(id) } }
}
