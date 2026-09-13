import Foundation

/// The host authorizes the read for the immutable launch scope, reconciles grant
/// expiry and returns only visible, bounded audit receipts and elevation records.
/// This interface does not confer database access or approval authority.
protocol CodexHostDiagnostics: Sendable {
  func snapshot(limit: Int, now: Date) async throws -> CodexHostDiagnosticSnapshot
}

struct CodexHostDiagnosticSnapshot: Sendable {
  let owner: CodexRuntimeOwner
  /// Normalized audit fields only; command input, output and secrets stay with the host.
  let recentToolAudits: [JSONValue]
  let elevationGrants: [CodexElevationGrantRecord]
}

/// The host preflights and authorizes using the connection's immutable caller and workspace.
/// It must recheck current policy and audit each execution; a risk hint alone grants nothing.
protocol CodexHostTools: Sendable {
  func discard(requestID: String) async
  func risk(named name: String, arguments: JSONValue, requestID: String, workspaceID: String?)
    async throws -> CodexOperationRisk
  func execute(name: String, arguments: JSONValue, requestID: String, workspaceID: String?)
    async throws -> JSONValue
}

extension CodexHostTools {
  func discard(requestID: String) async {}
}

/// Only the host can issue locally approved grants. The adapter can consume an exact
/// bound claim or invalidate it, but cannot approve or create grants.
protocol CodexElevationAuthority: Sendable {
  func claimCodexElevationGrant(
    workspaceID: String, canonicalRoot: String, profileID: String,
    requestingCaller: String, requestingConnectionID: String?, threadID: String?,
    runtimeID: String, action: CodexElevationAction, now: Date
  ) async throws -> CodexElevationClaim?
  func commitCodexElevationClaim(
    _ claim: CodexElevationClaim, runtimeID: String, threadID: String, turnID: String?, now: Date
  ) async throws -> CodexElevationGrantRecord
  func invalidateCodexElevationClaim(
    _ claim: CodexElevationClaim, reason: String, now: Date
  ) async throws
  func invalidateCodexElevationGrants(
    workspaceID: String?, threadID: String?, consumedRuntimeIDs: Set<String>, reason: String
  ) async throws
}
