import Foundation
import Testing

@testable import CodexAdapter

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
    let resolved = try configuration.resolvedExecutableURL(
      workspaceURL: root, environment: ["PATH": ""])
    #expect(resolved == executable.standardizedFileURL)
  }

  private func installExecutable(in directory: URL, name: String) throws -> URL {
    let executable = directory.appendingPathComponent(name)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
  }
}
