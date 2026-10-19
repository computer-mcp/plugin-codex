import ArgumentParser
import CodexAdapter
import Foundation

@main
struct CodexMCPAdapter: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "codex-mcp-adapter",
    abstract: "Serve Codex execution and protocol inspection through standard MCP.",
    discussion:
      "Without --config, serves protocol inspection. Execution settings are local JSON Codex configuration. Logs and errors go to stderr; serving uses MCP on stdin/stdout.",
    version: CodexAdapterBuildInfo.version,
    subcommands: [CompareSchema.self])

  @Option(name: .customLong("config"), help: "Path to local Codex JSON configuration.")
  var configurationPath: String?

  @Option(
    name: .customLong("state-directory"),
    help: "Directory for adapter-owned records and native thread ownership.")
  var stateDirectoryPath: String?

  mutating func validate() throws {
    if configurationPath?.isEmpty == true { throw ValidationError("--config must not be empty.") }
    if stateDirectoryPath?.isEmpty == true {
      throw ValidationError("--state-directory must not be empty.")
    }
  }

  mutating func run() async throws {
    try await CodexAdapterServer.run(
      configurationURL: configurationPath.map { URL(fileURLWithPath: $0) },
      stateDirectory: stateDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) })
  }

  struct CompareSchema: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "compare-schema",
      abstract: "Compare exported protocol schemas without starting Codex.")

    @Argument(help: "Baseline directory containing protocol JSON schema files.")
    var baseline: String

    @Argument(help: "Current directory containing protocol JSON schema files.")
    var current: String

    mutating func run() async throws {
      let data = try CodexAdapterServer.compareSchemas(
        baseline: URL(fileURLWithPath: baseline), current: URL(fileURLWithPath: current))
      try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
  }

}
