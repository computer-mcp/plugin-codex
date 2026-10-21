import Darwin
import Foundation
import Testing

@testable import CodexAdapter

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ManagedLineProcessLifecycleTests {
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
  func closeCancelsBlockedWriteAndReapsTheEntireGroup() async throws {
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/bin/sh",
        arguments: [
          "-c",
          #"trap '' TERM; /bin/sh -c 'trap "" TERM; /bin/sleep 30' & printf '%s\n' "$!"; wait"#,
        ],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 100, maximumMessageBytes: 2_097_152))
    do {
      var lines = process.inboundLines.makeAsyncIterator()
      let ready = try #require(try await lines.next())
      let child = try #require(Int32(ready))
      let writing = Task { try await process.sendLine(String(repeating: "x", count: 1_048_576)) }
      let deadline = ContinuousClock.now + .seconds(2)
      while await process.snapshot().pendingWrites == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(await process.snapshot().pendingWrites == 1)
      let started = ContinuousClock.now
      async let first: Void = process.close()
      async let second: Void = process.close()
      _ = await (first, second)
      #expect(started.duration(to: .now) < .seconds(3))
      if case .success = await writing.result {
        Issue.record("A cancelled, incomplete protocol write must fail.")
      }
      let result = await process.snapshot()
      #expect(result.hasExited && result.terminationEscalated)
      #expect(result.pendingWrites == 0 && result.cleanupConfirmed == true)
      #expect(kill(child, 0) == -1 && errno == ESRCH)
      #expect(kill(try #require(result.processID), 0) == -1 && errno == ESRCH)
      #expect(kill(try #require(result.supervisorProcessID), 0) == -1 && errno == ESRCH)
    } catch {
      await process.close()
      throw error
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
}
