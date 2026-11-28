import Foundation

enum CodexManagedWorktreeState: String, Codable, Equatable, Sendable {
  case planned
  case provisioning
  case active
  case removalPlanned = "removal_planned"
  case removing
  case removed
  case failed
  case unmanaged
}

enum CodexManagedWorktreeError: Error, LocalizedError, Sendable {
  case unavailable
  case invalid(String)
  case unknown(String)
  case revisionConflict(expected: Int, actual: Int)
  case state(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "Managed Codex worktrees require adapter persistence."
    case .invalid(let detail):
      return "Invalid managed worktree request: \(detail)"
    case .unknown(let id):
      return "Unknown Computer MCP-managed worktree '\(id)'."
    case .revisionConflict(let expected, let actual):
      return "Managed worktree revision conflict: expected \(expected), current \(actual)."
    case .state(let detail):
      return "Managed worktree state does not allow this operation: \(detail)"
    }
  }
}
