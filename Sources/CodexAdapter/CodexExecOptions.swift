import CodexExec
import Foundation

/// Native Exec overrides. Omitted values are owned by the user's Codex configuration.
struct CodexExecOptions: Sendable {
  let request: CodexExecRequestOptions
  let outputSchemaFile: URL?
  let outputLastMessageFile: URL?
  let stdin: String?

  init(_ value: JSONValue?, model: String?, configuration: CodexConfig, workspaceURL: URL) throws {
    let object = value?.objectValue ?? [:]
    guard value == nil || value?.objectValue != nil,
      Set(object.keys).isSubset(of: Set(Self.properties.keys))
    else {
      throw CodexToolError.invalidArguments("Exec options must match the declared native options.")
    }
    func string(_ key: String) throws -> String? {
      guard let value = object[key] else { return nil }
      guard let text = value.stringValue, !text.isEmpty, !text.contains("\0") else {
        throw CodexToolError.invalidArguments("Exec option '\(key)' must be a nonempty string.")
      }
      return text
    }
    func boolean(_ key: String) throws -> Bool? {
      guard let value = object[key] else { return nil }
      guard let flag = value.boolValue else {
        throw CodexToolError.invalidArguments("Exec option '\(key)' must be boolean.")
      }
      return flag
    }
    func strings(_ key: String) throws -> [String] {
      guard let value = object[key] else { return [] }
      guard let values = value.arrayValue, values.count <= 256,
        values.allSatisfy({ $0.stringValue.map { !$0.isEmpty && !$0.contains("\0") } == true })
      else {
        throw CodexToolError.invalidArguments("Exec option '\(key)' must be an array of strings.")
      }
      return values.compactMap(\.stringValue)
    }
    let cwd =
      try string("cwd").map {
        ($0.hasPrefix("/")
          ? URL(fileURLWithPath: $0, isDirectory: true)
          : workspaceURL.appendingPathComponent($0, isDirectory: true)).standardizedFileURL
      } ?? workspaceURL
    func url(_ text: String) -> URL {
      (text.hasPrefix("/") ? URL(fileURLWithPath: text) : cwd.appendingPathComponent(text))
        .standardizedFileURL
    }
    let sandbox = try string("sandbox") ?? configuration.sandbox?.rawValue
    let approval = try string("approval_policy") ?? configuration.approvalPolicy?.rawValue
    if let sandbox, CodexSandboxMode(rawValue: sandbox) == nil {
      throw CodexToolError.invalidArguments("Unsupported native Exec sandbox value.")
    }
    if let approval, CodexApprovalPolicy(rawValue: approval) == nil {
      throw CodexToolError.invalidArguments("Unsupported native Exec approval policy.")
    }
    request = try CodexExecRequestOptions(
      images: strings("images").map(url),
      additionalWritableDirectories: strings("add_dirs").map(url),
      approvalMode: approval,
      searchEnabled: boolean("search"),
      enabledFeatures: strings("enable"),
      disabledFeatures: strings("disable"),
      model: model,
      useOSS: boolean("oss") ?? false,
      workingDirectory: cwd,
      colorMode: "never",
      dangerouslyBypassApprovalsAndSandbox:
        boolean("dangerously_bypass_approvals_and_sandbox") ?? false,
      ephemeral: boolean("ephemeral") ?? false,
      ignoreUserConfig: boolean("ignore_user_config") ?? false,
      profile: string("profile"),
      sandboxMode: sandbox,
      skipGitRepoCheck: boolean("skip_git_repo_check") ?? false,
      configOverrides: strings("config")
    )
    outputSchemaFile = try string("output_schema").map(url)
    outputLastMessageFile = try string("output_last_message").map(url)
    stdin = try string("stdin")
  }

  static let properties: [String: JSONValue] = {
    var result: [String: JSONValue] = [:]
    for key in [
      "cwd", "sandbox", "approval_policy", "profile", "output_schema", "output_last_message",
      "stdin",
    ] {
      result[key] = .object(["type": .string("string"), "minLength": .number(1)])
    }
    for key in ["images", "add_dirs", "enable", "disable", "config"] {
      result[key] = .object([
        "type": .string("array"), "maxItems": .number(256),
        "items": .object(["type": .string("string"), "minLength": .number(1)]),
      ])
    }
    for key in [
      "search", "oss", "dangerously_bypass_approvals_and_sandbox", "ephemeral",
      "ignore_user_config", "skip_git_repo_check",
    ] {
      result[key] = .object(["type": .string("boolean")])
    }
    return result
  }()

  static var schema: JSONValue {
    .object([
      "type": .string("object"), "properties": .object(properties),
      "additionalProperties": .bool(false),
    ])
  }
}
