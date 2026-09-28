import Foundation

#if os(Windows)
  import WinSDK
#endif

package struct CodexConfig: Codable, Equatable, Sendable {
  package var enabled: Bool
  package var executable: String
  package var appServerEnabled: Bool
  package var execEnabled: Bool
  package var experimentalAPI: Bool
  package var appServerRequestTimeoutSeconds: Int
  package var appServerAppListTimeoutSeconds: Int
  package var appServerTerminationGraceMilliseconds: Int
  package var appServerKillGraceMilliseconds: Int
  package var appServerApprovalTimeoutSeconds: Int
  package var sandbox: CodexSandboxMode?
  package var approvalPolicy: CodexApprovalPolicy?
  package var maxSessions: Int
  package var maxEventsPerSession: Int

  package init(
    enabled: Bool = false,
    executable: String = "codex",
    appServerEnabled: Bool = true,
    execEnabled: Bool = true,
    experimentalAPI: Bool = true,
    appServerRequestTimeoutSeconds: Int = 30,
    appServerAppListTimeoutSeconds: Int = 120,
    appServerTerminationGraceMilliseconds: Int = 1_000,
    appServerKillGraceMilliseconds: Int = 2_000,
    appServerApprovalTimeoutSeconds: Int = 300,
    sandbox: CodexSandboxMode? = nil,
    approvalPolicy: CodexApprovalPolicy? = nil,
    maxSessions: Int = 8,
    maxEventsPerSession: Int = 1_024
  ) {
    self.enabled = enabled
    self.executable = executable
    self.appServerEnabled = appServerEnabled
    self.execEnabled = execEnabled
    self.experimentalAPI = experimentalAPI
    self.appServerRequestTimeoutSeconds = appServerRequestTimeoutSeconds
    self.appServerAppListTimeoutSeconds = appServerAppListTimeoutSeconds
    self.appServerTerminationGraceMilliseconds = appServerTerminationGraceMilliseconds
    self.appServerKillGraceMilliseconds = appServerKillGraceMilliseconds
    self.appServerApprovalTimeoutSeconds = appServerApprovalTimeoutSeconds
    self.sandbox = sandbox
    self.approvalPolicy = approvalPolicy
    self.maxSessions = maxSessions
    self.maxEventsPerSession = maxEventsPerSession
  }

  private enum CodingKeys: String, CodingKey {
    case enabled
    case executable
    case appServerEnabled = "app_server_enabled"
    case execEnabled = "exec_enabled"
    case experimentalAPI = "experimental_api"
    case appServerRequestTimeoutSeconds = "app_server_request_timeout_seconds"
    case appServerAppListTimeoutSeconds = "app_server_app_list_timeout_seconds"
    case appServerTerminationGraceMilliseconds = "app_server_termination_grace_milliseconds"
    case appServerKillGraceMilliseconds = "app_server_kill_grace_milliseconds"
    case appServerApprovalTimeoutSeconds = "app_server_approval_timeout_seconds"
    case sandbox
    case approvalPolicy = "approval_policy"
    case maxSessions = "max_sessions"
    case maxEventsPerSession = "max_events_per_session"
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    executable = try container.decodeIfPresent(String.self, forKey: .executable) ?? "codex"
    appServerEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .appServerEnabled) ?? true
    execEnabled = try container.decodeIfPresent(Bool.self, forKey: .execEnabled) ?? true
    experimentalAPI =
      try container.decodeIfPresent(Bool.self, forKey: .experimentalAPI) ?? true
    appServerRequestTimeoutSeconds =
      try container.decodeIfPresent(Int.self, forKey: .appServerRequestTimeoutSeconds) ?? 30
    appServerAppListTimeoutSeconds =
      try container.decodeIfPresent(Int.self, forKey: .appServerAppListTimeoutSeconds) ?? 120
    appServerTerminationGraceMilliseconds =
      try container.decodeIfPresent(Int.self, forKey: .appServerTerminationGraceMilliseconds)
      ?? 1_000
    appServerKillGraceMilliseconds =
      try container.decodeIfPresent(Int.self, forKey: .appServerKillGraceMilliseconds) ?? 2_000
    appServerApprovalTimeoutSeconds =
      try container.decodeIfPresent(Int.self, forKey: .appServerApprovalTimeoutSeconds) ?? 300
    sandbox = try container.decodeIfPresent(CodexSandboxMode.self, forKey: .sandbox)
    approvalPolicy = try container.decodeIfPresent(
      CodexApprovalPolicy.self, forKey: .approvalPolicy)
    maxSessions = try container.decodeIfPresent(Int.self, forKey: .maxSessions) ?? 8
    maxEventsPerSession =
      try container.decodeIfPresent(Int.self, forKey: .maxEventsPerSession) ?? 1_024
  }

  func validate() throws {
    guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ConfigurationError.invalid("codex.executable must not be empty.")
    }
    guard maxSessions > 0 && maxSessions <= 64 else {
      throw ConfigurationError.invalid("codex.max_sessions must be between 1 and 64.")
    }
    guard appServerRequestTimeoutSeconds >= 1 && appServerRequestTimeoutSeconds <= 300 else {
      throw ConfigurationError.invalid(
        "codex.app_server_request_timeout_seconds must be between 1 and 300."
      )
    }
    guard appServerAppListTimeoutSeconds >= 1 && appServerAppListTimeoutSeconds <= 300 else {
      throw ConfigurationError.invalid(
        "codex.app_server_app_list_timeout_seconds must be between 1 and 300."
      )
    }
    guard
      appServerTerminationGraceMilliseconds >= 0
        && appServerTerminationGraceMilliseconds <= 30_000
    else {
      throw ConfigurationError.invalid(
        "codex.app_server_termination_grace_milliseconds must be between 0 and 30000."
      )
    }
    guard appServerKillGraceMilliseconds >= 100 && appServerKillGraceMilliseconds <= 30_000 else {
      throw ConfigurationError.invalid(
        "codex.app_server_kill_grace_milliseconds must be between 100 and 30000."
      )
    }
    guard appServerApprovalTimeoutSeconds >= 1 && appServerApprovalTimeoutSeconds <= 3_600 else {
      throw ConfigurationError.invalid(
        "codex.app_server_approval_timeout_seconds must be between 1 and 3600."
      )
    }
    guard maxEventsPerSession >= 64 && maxEventsPerSession <= 16_384 else {
      throw ConfigurationError.invalid(
        "codex.max_events_per_session must be between 64 and 16384."
      )
    }
    if enabled && !appServerEnabled && !execEnabled {
      throw ConfigurationError.invalid(
        "At least one Codex path must be enabled when [codex].enabled is true."
      )
    }
  }

  func resolvedExecutableURL(workspaceURL: URL, environment: [String: String]) throws -> URL {
    #if os(Windows)
      let candidates = try windowsExecutableCandidates(
        workspaceURL: workspaceURL, environment: environment)
    #else
      let candidates: [URL]
      if executable.contains("/") {
        candidates = [
          executable.hasPrefix("/")
            ? URL(fileURLWithPath: executable)
            : workspaceURL.appendingPathComponent(executable)
        ]
      } else if let path = environment["PATH"] {
        candidates = path.split(separator: ":", omittingEmptySubsequences: false).map { entry in
          let directory =
            entry.hasPrefix("/")
            ? URL(fileURLWithPath: String(entry), isDirectory: true)
            : workspaceURL.appendingPathComponent(String(entry), isDirectory: true)
          return directory.appendingPathComponent(executable)
        }
      } else {
        candidates = []
      }
    #endif
    for candidate in candidates {
      let url = candidate.standardizedFileURL
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path)
      {
        return url
      }
    }
    throw ConfigurationError.invalid(
      "Cannot resolve configured Codex executable '\(executable)' in the launch workspace and PATH."
    )
  }

  #if os(Windows)
    private func windowsExecutableCandidates(workspaceURL: URL, environment: [String: String])
      throws
      -> [URL]
    {
      guard workspaceURL.isFileURL, !executable.isEmpty, !executable.utf16.contains(0) else {
        throw ConfigurationError.invalid("Invalid Windows Codex executable or workspace.")
      }
      let workspace = workspaceURL.path.replacingOccurrences(of: "/", with: "\\")
      guard Self.isWindowsAbsolutePath(workspace) else {
        throw ConfigurationError.invalid("Codex launch workspace must be absolute.")
      }
      if executable.contains(where: { "/\\:".contains($0) }) {
        return [try Self.windowsURL(executable, relativeTo: workspace)]
      }
      let entries = environment.filter { CodexProcessEnvironment.namesMatch($0.key, "PATH") }
      guard entries.count <= 1 else {
        throw ConfigurationError.invalid(
          "Codex launch environment contains ambiguous Windows PATH names.")
      }
      guard let path = entries.first?.value else { return [] }
      guard !path.utf16.contains(0) else {
        throw ConfigurationError.invalid("Codex launch PATH contains a NUL character.")
      }
      let name = executable.lowercased().hasSuffix(".exe") ? executable : executable + ".exe"
      return try path.split(separator: ";").compactMap { entry in
        var directory = String(entry)
        if directory.hasPrefix("\""), directory.hasSuffix("\""), directory.count >= 2 {
          directory.removeFirst()
          directory.removeLast()
        }
        // An empty entry does not add the ambient process directory to native discovery.
        guard !directory.isEmpty else { return nil }
        return try Self.windowsURL(directory + "\\" + name, relativeTo: workspace)
      }
    }

    private static func windowsURL(_ input: String, relativeTo workspace: String) throws -> URL {
      let path = input.replacingOccurrences(of: "/", with: "\\")
      let absolute = isWindowsAbsolutePath(path)
      guard !path.utf16.contains(0), !path.contains("\""),
        absolute || (!path.hasPrefix("\\") && !path.contains(":"))
      else {
        throw ConfigurationError.invalid(
          "Codex executable paths must be absolute or workspace-relative.")
      }
      let joined = absolute ? path : workspace + "\\" + path
      guard joined.utf16.count < 32_767 else {
        throw ConfigurationError.invalid("Codex executable path exceeds the Windows path limit.")
      }
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      let length = GetFullPathNameW(Array(joined.utf16) + [0], DWORD(buffer.count), &buffer, nil)
      guard length > 0, length < buffer.count else {
        throw ConfigurationError.invalid("Cannot normalize the configured Codex executable path.")
      }
      return URL(fileURLWithPath: String(decoding: buffer.prefix(Int(length)), as: UTF16.self))
    }

    private static func isWindowsAbsolutePath(_ path: String) -> Bool {
      let prefix = Array(path.utf8.prefix(3))
      return path.hasPrefix("\\\\")
        || (prefix.count == 3 && ((65...90).contains(prefix[0]) || (97...122).contains(prefix[0]))
          && prefix[1] == 58 && prefix[2] == 92)
    }
  #endif
}

package enum CodexSandboxMode: String, Codable, Equatable, Sendable {
  case readOnly = "read-only"
  case workspaceWrite = "workspace-write"
  case dangerFullAccess = "danger-full-access"
}

package enum CodexApprovalPolicy: String, Codable, Equatable, Sendable {
  case untrusted
  case onFailure = "on-failure"
  case onRequest = "on-request"
  case never
}
package enum ConfigurationError: Error, LocalizedError, Equatable {
  case invalid(String)

  package var errorDescription: String? {
    switch self {
    case .invalid(let message):
      return message
    }
  }
}
