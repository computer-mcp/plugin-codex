enum CodexOperationRisk: String, Codable, Equatable, Sendable {
  case readOnly = "read-only"
  case workspaceWrite = "workspace-write"
  case externalWrite = "external-write"
  case destructive
  case fullShell = "full-shell"
}
