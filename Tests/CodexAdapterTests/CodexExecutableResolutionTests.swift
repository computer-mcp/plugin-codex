import Foundation
import Testing

@testable import CodexAdapter

#if os(Windows)
  import WinSDK
#endif

struct CodexExecutableResolutionTests {
  @Test(arguments: ["absolute", "relative", "path", "relative-path"])
  func resolvesTheConfiguredNameInLaunchContext(form: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try installExecutable(in: root, name: "custom-codex")
    let name =
      form == "absolute"
      ? executable.path : form == "relative" ? "./" + executable.lastPathComponent : "custom-codex"
    let path = form == "relative-path" ? "." : root.path
    let result = try CodexConfig(executable: name).resolvedExecutableURL(
      workspaceURL: root, environment: ["PATH": path])
    #expect(result == executable.standardizedFileURL)
  }

  @Test
  func missingCustomNameDoesNotFallBackToDefaultOrCurrentDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try installExecutable(in: bin, name: "codex")
    _ = try installExecutable(in: root, name: "custom-codex")
    for environment in [["PATH": bin.path], [:]] {
      #expect(throws: ConfigurationError.self) {
        try CodexConfig(executable: "custom-codex").resolvedExecutableURL(
          workspaceURL: root, environment: environment)
      }
    }
    #expect(throws: ConfigurationError.self) {
      try CodexConfig(executable: bin.path).resolvedExecutableURL(
        workspaceURL: root, environment: [:])
    }
  }

  @Test
  func emptyPathEntryFollowsTheNativeDiscoveryContract() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try installExecutable(in: root, name: "custom-codex")
    let configuration = CodexConfig(executable: "custom-codex")
    #if os(Windows)
      #expect(FileManager.default.fileExists(atPath: executable.path))
      #expect(throws: ConfigurationError.self) {
        try configuration.resolvedExecutableURL(workspaceURL: root, environment: ["Path": ""])
      }
    #else
      let resolved = try configuration.resolvedExecutableURL(
        workspaceURL: root, environment: ["PATH": ""])
      #expect(resolved == executable.standardizedFileURL)
    #endif
  }

  #if os(Windows)
    @Test
    func nativePathSpellingAndQuotedEntriesUseTheLaunchWorkspace() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let bin = root.appendingPathComponent("tools 雪 with space")
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let executable = try installExecutable(in: bin, name: "custom-codex")
      let byPath = try CodexConfig(executable: "custom-codex").resolvedExecutableURL(
        workspaceURL: root, environment: ["pAtH": "missing;\"tools 雪 with space\";;"])
      let byRelative = try CodexConfig(executable: "tools 雪 with space\\custom-codex.exe")
        .resolvedExecutableURL(workspaceURL: root, environment: [:])
      #expect(byPath == executable.standardizedFileURL)
      #expect(byRelative == executable.standardizedFileURL)
    }

    @Test
    func ambiguousEnvironmentAndDriveRelativeNamesFailWithoutShellDiscovery() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      _ = try installExecutable(in: root, name: "custom-codex")
      #expect(throws: ConfigurationError.self) {
        try CodexConfig(executable: "custom-codex").resolvedExecutableURL(
          workspaceURL: root, environment: ["PATH": root.path, "Path": root.path])
      }
      #expect(throws: ConfigurationError.self) {
        try CodexConfig(executable: "C:custom-codex.exe").resolvedExecutableURL(
          workspaceURL: root, environment: [:])
      }
      try Data("@exit /b 0\r\n".utf8).write(to: root.appendingPathComponent("script-only.cmd"))
      #expect(throws: ConfigurationError.self) {
        try CodexConfig(executable: "script-only").resolvedExecutableURL(
          workspaceURL: root, environment: ["Path": root.path, "PATHEXT": ".CMD"])
      }
    }
  #endif

  private func installExecutable(in directory: URL, name: String) throws -> URL {
    #if os(Windows)
      var system = [WCHAR](repeating: 0, count: 32_768)
      let length = GetSystemDirectoryW(&system, UINT(system.count))
      try #require(length > 0 && length < system.count)
      let source = URL(
        fileURLWithPath: String(decoding: system.prefix(Int(length)), as: UTF16.self)
      )
      .appendingPathComponent("cmd.exe")
      let executable = directory.appendingPathComponent(name + ".exe")
      try FileManager.default.copyItem(at: source, to: executable)
    #else
      let executable = directory.appendingPathComponent(name)
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    #endif
    return executable
  }
}
