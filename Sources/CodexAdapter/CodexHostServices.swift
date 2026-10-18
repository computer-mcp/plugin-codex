import Foundation

/// The host authorizes the read for the immutable launch scope and returns
/// visible, bounded audit receipts.
/// This interface does not confer database access or approval authority.
protocol CodexHostDiagnostics: Sendable {
  func snapshot(limit: Int, now: Date) async throws -> CodexHostDiagnosticSnapshot
}

struct CodexHostDiagnosticSnapshot: Sendable {
  let owner: CodexRuntimeOwner
  /// Normalized audit fields only; command input, output and secrets stay with the host.
  let recentToolAudits: [JSONValue]
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
