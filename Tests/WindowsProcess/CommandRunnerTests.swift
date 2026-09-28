import Foundation
import Testing
import WinSDK

@testable import ManagedProcess

@Suite("Windows adapter finite commands", .timeLimit(.minutes(1)))
struct CommandRunnerTests {
  @Test(
    "Native argv, Unicode cwd, overridden environment and stdin EOF survive synchronous execution")
  func launchContext() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let arguments = ["", "a b", "汉字 🐈", "quote\"inside", "trailing slash \\", "&|<>%"]
    let executable = try fixture()
    let runner = ProcessCommandRunner(
      environment: environment(mode: "echo").merging(["Value": "base"]) { _, new in new })
    let result = try await Task.detached {
      try runner.runData(
        executable: executable.path, arguments: arguments, workingDirectory: directory,
        environment: ["VALUE": "覆盖"], timeoutMilliseconds: 10_000, maxOutputBytes: 16_384)
    }.value
    let value = try JSONDecoder().decode(JSONValue.self, from: result.stdout)
    #expect(value.objectValue?["arguments"] == .array(arguments.map(JSONValue.string)))
    #expect(value.objectValue?["cwd"]?.stringValue == directory.path)
    #expect(value.objectValue?["value"] == .string("覆盖"))
    #expect(value.objectValue?["input"] == .string(""))
    #expect(result.exitCode == 0 && !result.timedOut)
    #expect(!result.stdoutTruncated && !result.stderrTruncated)
  }

  @Test("Both output pipes drain beyond their retained prefixes")
  func boundedOutput() async throws {
    let result = try await ProcessCommandRunner(environment: environment(mode: "output"))
      .runDataAsync(
        executable: fixture().path, arguments: [], workingDirectory: nil, environment: [:],
        timeoutMilliseconds: 10_000, maxOutputBytes: 64)
    #expect(result.stdout == Data(("kept\n" + String(repeating: "x", count: 59)).utf8))
    #expect(result.stderr == Data(repeating: 121, count: 64))
    #expect(result.stdoutTruncated && result.stderrTruncated)
    #expect(result.exitCode == 0 && !result.timedOut)
  }

  enum End: String, CaseIterable { case natural, timeout, cancellation }

  @Test(
    "Every completion route joins descendants and preserves an independent command",
    arguments: End.allCases)
  func treeCleanup(_ end: End) async throws {
    let directory = try temporaryDirectory()
    let siblingDirectory = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
      try? FileManager.default.removeItem(at: siblingDirectory)
    }
    let executable = try fixture().path
    let runner = ProcessCommandRunner(
      environment: environment(mode: end == .natural ? "tree-exit" : "tree", directory: directory))
    let siblingRunner = ProcessCommandRunner(
      environment: environment(mode: "tree", directory: siblingDirectory))
    let command = Task {
      try await runner.runDataAsync(
        executable: executable, arguments: [], workingDirectory: directory,
        environment: [:], timeoutMilliseconds: end == .timeout ? 5_000 : 20_000, maxOutputBytes: 64)
    }
    let sibling = Task {
      try await siblingRunner.runDataAsync(
        executable: executable, arguments: [], workingDirectory: siblingDirectory,
        environment: [:], timeoutMilliseconds: 20_000, maxOutputBytes: 64)
    }
    do {
      let members = try await observeTree(directory)
      let others = try await observeTree(siblingDirectory)
      if end == .natural { try Data().write(to: directory.appendingPathComponent("release")) }
      if end == .cancellation { command.cancel() }
      switch await command.result {
      case .success(let result):
        #expect(end != .cancellation)
        #expect(result.timedOut == (end == .timeout))
        #expect(result.stdout == Data("ready\n".utf8))
        if end == .natural { #expect(result.exitCode == 0) }
      case .failure(let error):
        #expect(end == .cancellation && error is CancellationError)
      }
      #expect(members.allSatisfy { $0.hasExited })
      #expect(others.allSatisfy { !$0.hasExited })
      sibling.cancel()
      await #expect(throws: CancellationError.self) { try await sibling.value }
      #expect(others.allSatisfy { $0.hasExited })
    } catch {
      command.cancel()
      sibling.cancel()
      _ = await command.result
      _ = await sibling.result
      throw error
    }
  }

  @Test("Codex and finite commands share explicit Windows PATH discovery")
  func discovery() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let binaryDirectory = directory.appendingPathComponent("命令 tools")
    try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: false)
    let executable = binaryDirectory.appendingPathComponent("fixture.exe")
    try FileManager.default.copyItem(at: fixture(), to: executable)
    let environment = ["Path": "\"命令 tools\";;", "PATHEXT": ".cmd"]
    let native = try WindowsExecutable.resolve(
      "fixture", workspace: directory, environment: environment)
    let configured = try CodexConfig(executable: "fixture").resolvedExecutableURL(
      workspaceURL: directory, environment: environment)
    #expect(native == configured && native == executable)
    for invalid in ["C:fixture.exe", "\\fixture.exe", "NUL", "\\\\.\\pipe\\fixture"] {
      #expect(throws: CommandRunnerError.self) {
        try WindowsExecutable.resolve(invalid, workspace: directory, environment: environment)
      }
    }
    #expect(throws: CommandRunnerError.self) {
      try WindowsExecutable.resolve(
        "fixture", workspace: directory,
        environment: ["Path": binaryDirectory.path, "PATH": binaryDirectory.path])
    }
  }

  @Test("Environment aliases and invalid execution limits fail before child launch")
  func admission() async throws {
    let merged = try WindowsProcessEnvironment.merging(
      ["Path": "base", "=C:": "C:\\base"], overrides: ["PATH": "child"])
    #expect(merged == ["PATH": "child", "=C:": "C:\\base"])
    #expect(WindowsProcessEnvironment.namesMatch("path", "PATH"))
    #expect(!WindowsProcessEnvironment.namesMatch("PATH\0extra", "PATH"))
    for invalid in [["Path": "a", "PATH": "b"], ["=C:": "C:\\bad"], ["KEY": "a\0b"]] {
      #expect(throws: CommandRunnerError.self) {
        try WindowsProcessEnvironment.merging([:], overrides: invalid)
      }
    }
    for (deadline, limit) in [(0, 64), (10_000, 0), (3_600_001, 64)] {
      await #expect(throws: CommandRunnerError.self) {
        try await ProcessCommandRunner().runDataAsync(
          executable: "missing", arguments: [],
          workingDirectory: nil, environment: [:], timeoutMilliseconds: deadline,
          maxOutputBytes: limit)
      }
    }
  }

  private func fixture() throws -> URL {
    URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CODEX_WINDOWS_FIXTURE"]))
  }

  private func environment(mode: String, directory: URL? = nil) -> [String: String] {
    var result = ["CODEX_FIXTURE_MODE": mode]
    for key in ["PATH", "SystemRoot"] {
      if let entry = ProcessInfo.processInfo.environment.first(where: {
        WindowsProcessEnvironment.namesMatch($0.key, key)
      }) {
        result[key] = entry.value
      }
    }
    if let directory { result["CODEX_FIXTURE_DIRECTORY"] = directory.path }
    return result
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "command 汉字 \(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }

  private func observeTree(_ directory: URL) async throws -> [Observation] {
    let ready = directory.appendingPathComponent("root")
    let deadline = ContinuousClock.now + .seconds(10)
    while !FileManager.default.fileExists(atPath: ready.path) {
      guard ContinuousClock.now < deadline else { throw ReadinessTimeout() }
      try await Task.sleep(for: .milliseconds(10))
    }
    return try ["root", "branch", "leaf"].map { name in
      let value = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
      let pid = try #require(DWORD(value))
      return Observation(try #require(OpenProcess(DWORD(SYNCHRONIZE), false, pid)))
    }
  }

  private struct ReadinessTimeout: Error {}
  private final class Observation {
    let handle: HANDLE
    init(_ handle: HANDLE) { self.handle = handle }
    deinit { CloseHandle(handle) }
    var hasExited: Bool { WaitForSingleObject(handle, 0) == DWORD(WAIT_OBJECT_0) }
  }
}
