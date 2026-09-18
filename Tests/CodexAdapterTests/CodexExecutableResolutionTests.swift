import Foundation
import Testing

@testable import CodexAdapter

struct CodexExecutableResolutionTests {
  @Test(arguments: ["absolute", "relative", "path", "relative-path", "empty-path-entry"])
  func resolvesTheConfiguredNameInLaunchContext(form: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("custom-codex")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let name =
      form == "absolute" ? executable.path : form == "relative" ? "./custom-codex" : "custom-codex"
    let path = form == "relative-path" ? "." : form == "empty-path-entry" ? "" : root.path
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
    for file in [bin.appendingPathComponent("codex"), root.appendingPathComponent("custom-codex")] {
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
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
}
