import Foundation

/// The host rechecks the bound source workspace, caller and profile before registering
/// a derived workspace. It owns registration, grants and their rollback; the adapter
/// supplies the exact persisted worktree receipt, never a caller-selected profile.
/// Removal is idempotent and must reject registrations not owned by that receipt.
protocol CodexManagedWorkspaceHost: Sendable {
  func registerDerivedWorkspace(_ worktree: CodexManagedWorktree, now: Date) async throws
  func unregisterDerivedWorkspace(_ worktree: CodexManagedWorktree, now: Date) async throws
  /// Validates the current invocation's host-owned destructive-operation ticket.
  func authorizeRemoval(_ worktree: CodexManagedWorktree) async throws
}
