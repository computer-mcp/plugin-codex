import Testing

@testable import CodexMCPAdapter

struct CommandTests {
  @Test func parsesServingAndSchemaComparisonWithoutStartingAProcess() throws {
    let serving = try CodexMCPAdapter.parse(["--config=/tmp/config with spaces.json"])
    #expect(serving.configurationPath == "/tmp/config with spaces.json")
    let persistent = try CodexMCPAdapter.parse([
      "--state-directory=/tmp/adapter state", "--config", "/tmp/config.json",
    ])
    #expect(persistent.stateDirectoryPath == "/tmp/adapter state")
    #expect(try CodexMCPAdapter.parse([]).configurationPath == nil)
    let command = try #require(
      CodexMCPAdapter.parseAsRoot(["compare-schema", "/tmp/baseline", "/tmp/current"])
        as? CodexMCPAdapter.CompareSchema)
    #expect(command.baseline == "/tmp/baseline")
    #expect(command.current == "/tmp/current")
  }

  @Test(arguments: [
    ["--unknown"], ["--config"], ["--config", ""], ["--state-directory"],
    ["--state-directory", ""],
    ["compare-schema", "/tmp/one"],
  ])
  func invalidArgumentsFailBeforeServing(arguments: [String]) {
    #expect(throws: (any Error).self) { try CodexMCPAdapter.parseAsRoot(arguments) }
  }

  @Test func helpDescribesCurrentCommandSurface() {
    let help = CodexMCPAdapter.helpMessage()
    #expect(help.contains("--config"))
    #expect(help.contains("--state-directory"))
    #expect(help.contains("compare-schema"))
    #expect(CodexMCPAdapter.CompareSchema.helpMessage().contains("<baseline> <current>"))
  }

  @Test func parsesOfflineMigrationWithoutStartingServer() throws {
    let command = try #require(
      CodexMCPAdapter.parseAsRoot([
        "migrate-state", "--source-snapshot", "/tmp/source snapshot.sqlite", "--destination",
        "/tmp/target.sqlite",
      ]) as? CodexMCPAdapter.MigrateState)
    #expect(!command.apply)
    #expect(command.expectedPlanDigest == nil)
    #expect(command.sourceSnapshot == "/tmp/source snapshot.sqlite")
    #expect(CodexMCPAdapter.helpMessage().contains("migrate-state"))
    for extra in [["--apply"], ["--expected-plan-digest", "digest"]] {
      #expect(throws: (any Error).self) {
        try CodexMCPAdapter.parseAsRoot(
          [
            "migrate-state", "--source-snapshot", "/tmp/source", "--destination", "/tmp/target",
          ] + extra)
      }
    }
  }

}
