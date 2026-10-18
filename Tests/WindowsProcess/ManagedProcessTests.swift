import CodexAppServerRuntime
import CodexAppServerStdio
import Foundation
import Testing
import WinSDK

@testable import ManagedProcess

@Suite("Windows adapter process ownership", .timeLimit(.minutes(1)))
struct ManagedProcessTests {
  @Test("Host callback handles and provenance do not enter vendor environments")
  func hostEnvironmentIsolation() {
    let environment = CodexProcessEnvironment.resolved(
      base: [
        "computer_mcp_host_context": "bound-by-host", "Computer_Mcp_Host_Fd": "3",
        "computer_mcp_host_read_handle": "144", "COMPUTER_MCP_HOST_WRITE_HANDLE": "148",
        "PRESERVE_VALUE": "user-owned",
      ], systemProxy: .init())
    #expect(environment["PRESERVE_VALUE"] == "user-owned")
    #expect(!environment.keys.contains { $0.lowercased().hasPrefix("computer_mcp_host_") })
  }

  @Test("Graceful EOF preserves final output and a cancelled close caller joins cleanup")
  func gracefulClose() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let process = try makeProcess(mode: "input-finish", directory: directory, grace: 5_000)
    do {
      var lines = process.inboundLines.makeAsyncIterator()
      try await process.sendLine("汉字 🐈")
      #expect(try await lines.next() == "汉字 🐈")
      let root = try observe("main", in: directory)
      let closing = Task { await process.close() }
      closing.cancel()
      #expect(try await lines.next() == "eof")
      await #expect(throws: ManagedLineProcessError.self) { try await process.sendLine("late") }
      #expect(!root.hasExited)
      #expect(await process.snapshot().cleanupConfirmed == false)
      try Data().write(to: directory.appendingPathComponent("release"))
      await closing.value
      let stopped = await process.snapshot()
      #expect(stopped.cleanupConfirmed == true && stopped.hasExited)
      #expect(stopped.exitCode == 23 && !stopped.terminationEscalated)
      #expect(stopped.processID == Int32(bitPattern: root.identifier))
      #expect(stopped.processGroupID == nil && stopped.supervisorProcessID == nil)
      #expect(root.hasExited)
      #expect(try await lines.next() == nil)
    } catch {
      await process.close()
      throw error
    }
  }

  @Test("Forced close joins a blocked writer and concurrent observers")
  func blockedInput() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let process = try makeProcess(mode: "blocked-input", directory: directory)
    do {
      var lines = process.inboundLines.makeAsyncIterator()
      #expect(try await lines.next() == "ready")
      let root = try observe("root", in: directory)
      let sending = Task { try await process.sendLine(String(repeating: "x", count: 2_000_000)) }
      #expect(try await lines.next() == "receiving")
      async let first: Void = process.close()
      async let second: Void = process.close()
      await first
      await second
      guard case .failure = await sending.result else {
        Issue.record("A blocked native pipe accepted the complete frame.")
        return
      }
      let stopped = await process.snapshot()
      #expect(stopped.cleanupConfirmed == true && stopped.hasExited)
      #expect(stopped.terminationEscalated && stopped.pendingWrites == 0)
      #expect(root.hasExited)
    } catch {
      await process.close()
      throw error
    }
  }

  @Test("Natural root exit joins inherited descendants")
  func naturalExit() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let process = try makeProcess(mode: "tree-exit", directory: directory)
    do {
      var lines = process.inboundLines.makeAsyncIterator()
      #expect(try await lines.next() == "ready")
      let members = try ["root", "branch", "leaf"].map { try observe($0, in: directory) }
      try Data().write(to: directory.appendingPathComponent("release"))
      #expect(try await lines.next() == nil)
      try await waitForCleanup(process)
      await process.close()
      #expect(members.allSatisfy { $0.hasExited })
      #expect(await process.snapshot().exitCode == 0)
    } catch {
      await process.close()
      throw error
    }
  }

  @Test("Owner exit cleans only its child tree and preserves an independent invocation")
  func externalOwnerExit() async throws {
    let firstDirectory = try temporaryDirectory()
    let secondDirectory = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: firstDirectory)
      try? FileManager.default.removeItem(at: secondDirectory)
    }
    let owner = try CodexAppServerStdioTransport(
      configuration: .init(executableURL: fixture(), environment: environment(mode: "lines")))
    do {
      let first = try makeProcess(
        mode: "tree", directory: firstDirectory, owner: owner.processIdentifier)
      do {
        let second = try makeProcess(mode: "tree", directory: secondDirectory)
        do {
          var firstLines = first.inboundLines.makeAsyncIterator()
          var secondLines = second.inboundLines.makeAsyncIterator()
          #expect(try await firstLines.next() == "ready")
          #expect(try await secondLines.next() == "ready")
          let firstMembers = try ["root", "branch", "leaf"].map {
            try observe($0, in: firstDirectory)
          }
          let secondMembers = try ["root", "branch", "leaf"].map {
            try observe($0, in: secondDirectory)
          }
          await owner.close()
          try await waitForCleanup(first)
          #expect(firstMembers.allSatisfy { $0.hasExited })
          #expect(secondMembers.allSatisfy { !$0.hasExited })
          #expect(await second.snapshot().cleanupConfirmed == false)
          await second.close()
          #expect(secondMembers.allSatisfy { $0.hasExited })
        } catch {
          await second.close()
          throw error
        }
        await first.close()
      } catch {
        await first.close()
        throw error
      }
    } catch {
      await owner.close()
      throw error
    }
    await owner.close()
  }

  @Test("A retained terminated owner fails before child admission")
  func terminatedOwner() async throws {
    let directory = try temporaryDirectory()
    let childDirectory = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
      try? FileManager.default.removeItem(at: childDirectory)
    }
    let owner = try CodexAppServerStdioTransport(
      configuration: .init(
        executableURL: fixture(), environment: environment(mode: "lines", directory: directory)))
    do {
      var lines = owner.inboundLines.makeAsyncIterator()
      try await owner.sendLine("ready")
      #expect(try await lines.next() == "ready")
      let retained = try observe("main", in: directory)
      await owner.close()
      #expect(retained.hasExited)
      #expect(throws: ManagedLineProcessError.self) {
        _ = try makeProcess(
          mode: "lines", directory: childDirectory, owner: Int32(bitPattern: retained.identifier))
      }
      #expect(
        !FileManager.default.fileExists(atPath: childDirectory.appendingPathComponent("main").path))
    } catch {
      await owner.close()
      throw error
    }
  }

  @Test("The adapter's lower outgoing bound preserves the running process")
  func outgoingBound() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let process = try makeProcess(mode: "lines", directory: directory, limit: 4)
    do {
      await #expect(throws: ManagedLineProcessError.self) { try await process.sendLine("🐈x") }
      var lines = process.inboundLines.makeAsyncIterator()
      try await process.sendLine("🐈")
      #expect(try await lines.next() == "🐈")
      #expect(await process.snapshot().state == .running)
      await process.close()
      #expect(await process.snapshot().cleanupConfirmed == true)
    } catch {
      await process.close()
      throw error
    }
  }

  @Test("The adapter's lower incoming bound joins the process on overflow")
  func incomingBound() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let process = try makeProcess(mode: "oversized-frame", directory: directory, limit: 64)
    do {
      var lines = process.inboundLines.makeAsyncIterator()
      #expect(try await lines.next() == "ready")
      let root = try observe("root", in: directory)
      try await process.sendLine("start")
      await #expect(
        throws: CodexAppServerConnectionFoundation.FoundationError.messageTooLarge(limitBytes: 64)
      ) { try await lines.next() }
      try await waitForCleanup(process)
      #expect(root.hasExited)
      await process.close()
    } catch {
      await process.close()
      throw error
    }
  }

  private func fixture() throws -> URL {
    URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CODEX_WINDOWS_FIXTURE"]))
  }

  private func makeProcess(
    mode: String, directory: URL, grace: Int = 0,
    limit: Int = 16 * 1_024 * 1_024,
    owner: Int32 = ProcessInfo.processInfo.processIdentifier
  ) throws -> ManagedLineProcess {
    try ManagedLineProcess(
      configuration: .init(
        executable: fixture().path, environment: environment(mode: mode, directory: directory),
        workingDirectory: directory, terminationGraceMilliseconds: grace,
        killGraceMilliseconds: 5_000, maximumMessageBytes: limit, ownerProcessID: owner))
  }

  private func environment(mode: String, directory: URL? = nil) -> [String: String] {
    var result = ["CODEX_FIXTURE_MODE": mode]
    for key in ["PATH", "SystemRoot"] {
      if let value = ProcessInfo.processInfo.environment.first(where: {
        $0.key.caseInsensitiveCompare(key) == .orderedSame
      })?.value {
        result[key] = value
      }
    }
    if let directory { result["CODEX_FIXTURE_DIRECTORY"] = directory.path }
    return result
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "adapter 汉字 \(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }

  private func observe(_ name: String, in directory: URL) throws -> NativeProcessObservation {
    let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    let identifier = try #require(DWORD(text))
    let handle = try #require(OpenProcess(DWORD(SYNCHRONIZE), false, identifier))
    return NativeProcessObservation(handle: handle, identifier: identifier)
  }

  private func waitForCleanup(_ process: ManagedLineProcess) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while await process.snapshot().cleanupConfirmed != true {
      guard ContinuousClock.now < deadline else { throw CleanupTimeout() }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private struct CleanupTimeout: Error {}

  private final class NativeProcessObservation {
    let handle: HANDLE
    let identifier: DWORD
    init(handle: HANDLE, identifier: DWORD) {
      self.handle = handle
      self.identifier = identifier
    }
    deinit { CloseHandle(handle) }
    var hasExited: Bool { WaitForSingleObject(handle, 0) == DWORD(WAIT_OBJECT_0) }
  }
}
