enum CodexOperationRisk: String, Codable, Equatable, Sendable {
  case readOnly = "read-only"
  case workspaceWrite = "workspace-write"
  case externalWrite = "external-write"
  case destructive
  case fullShell = "full-shell"

  var hostValue: String { self == .workspaceWrite ? "project-write" : rawValue }

  init?(hostValue: String) {
    if hostValue == "project-write" {
      self = .workspaceWrite
    } else if hostValue == Self.workspaceWrite.rawValue {
      return nil
    } else {
      self.init(rawValue: hostValue)
    }
  }
}
