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
    subcommands: [CompareSchema.self, MigrateState.self])

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

  struct MigrateState: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "migrate-state",
      abstract: "Preview or apply an offline Codex domain-state migration.",
      discussion:
        "Requires an offline SQLite snapshot and a stopped destination adapter. Transfers domain records, never host grants, audit, credentials or vendor state. Preview is the default; apply requires its exact digest. This command does not stop any runtime."
    )

    @Option(
      name: .customLong("source-snapshot"),
      help: "Absolute path to an offline, checkpointed source SQLite snapshot.")
    var sourceSnapshot: String

    @Option(help: "Absolute path to a new or existing adapter-only SQLite database.")
    var destination: String

    @Flag(help: "Apply the reviewed plan; otherwise only preview.")
    var apply = false

    @Option(
      name: .customLong("expected-plan-digest"),
      help: "SHA-256 digest from a fresh migration preview.")
    var expectedPlanDigest: String?

    mutating func validate() throws {
      guard sourceSnapshot.hasPrefix("/"), destination.hasPrefix("/"),
        !sourceSnapshot.contains("\0"), !destination.contains("\0")
      else { throw ValidationError("Database paths must be absolute local paths.") }
      guard apply == (expectedPlanDigest != nil) else {
        throw ValidationError("--apply and --expected-plan-digest must be supplied together.")
      }
    }

    mutating func run() throws {
      let result = try CodexAdapterServer.migrateState(
        source: URL(fileURLWithPath: sourceSnapshot),
        destination: URL(fileURLWithPath: destination),
        expectedPlanDigest: expectedPlanDigest)
      try FileHandle.standardOutput.write(contentsOf: result + Data([10]))
    }
  }

}
