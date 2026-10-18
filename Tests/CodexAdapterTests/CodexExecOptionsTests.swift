import CodexExec
import Foundation
import Testing

@testable import CodexAdapter

struct CodexExecOptionsTests {
  @Test func nativeOverridesArePreservedWithoutWorkspaceConfinement() throws {
    let options = try CodexExecOptions(
      .object([
        "cwd": .string("/tmp/native-cwd"), "sandbox": .string("danger-full-access"),
        "approval_policy": .string("never"), "profile": .string("personal"),
        "config": .array([.string("model_provider=\"personal\""), .string("web_search=\"cached\"")]
        ),
        "images": .array([.string("input.png")]), "add_dirs": .array([.string("../extra")]),
        "enable": .array([.string("feature-a")]), "disable": .array([.string("feature-b")]),
        "search": .bool(false), "ephemeral": .bool(true), "stdin": .string("context"),
        "output_schema": .string("schema.json"), "output_last_message": .string("last.txt"),
      ]), model: "native-model", configuration: .init(),
      workspaceURL: URL(fileURLWithPath: "/tmp/initial"))
    #expect(options.request.workingDirectory?.path == "/tmp/native-cwd")
    #expect(options.request.sandboxMode == "danger-full-access")
    #expect(options.request.approvalMode == "never")
    #expect(options.request.profile == "personal")
    #expect(options.request.images.map(\.path) == ["/tmp/native-cwd/input.png"])
    #expect(options.request.additionalWritableDirectories.map(\.path) == ["/tmp/extra"])
    #expect(options.request.searchEnabled == false)
    #expect(options.request.configOverrides.count == 2)
    #expect(options.request.enabledFeatures == ["feature-a"])
    #expect(options.request.disabledFeatures == ["feature-b"])
    #expect(options.request.ephemeral)
    #expect(!options.request.ignoreUserConfig)
    #expect(options.stdin == "context")
    #expect(options.outputSchemaFile?.path == "/tmp/native-cwd/schema.json")
    #expect(options.outputLastMessageFile?.path == "/tmp/native-cwd/last.txt")
  }

  @Test(arguments: [
    JSONValue.object(["full_auto": .bool(true)]), .object(["sandbox": .string("custom")]),
    .object(["approval_policy": .string("custom")]), .object(["search": .string("true")]),
    .object(["config": .array([.bool(true)])]), .string("not-an-object"),
  ])
  func invalidNativeOptionsFailBeforeDispatch(_ value: JSONValue) {
    #expect(throws: CodexToolError.self) {
      try CodexExecOptions(
        value, model: nil, configuration: .init(), workspaceURL: URL(fileURLWithPath: "/tmp"))
    }
  }
}
