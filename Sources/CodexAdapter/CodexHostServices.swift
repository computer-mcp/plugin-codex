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

/// Private host diagnostics use project vocabulary. Native ownership receipts
/// retain their persisted workspace representation.
struct CodexHostDiagnosticOwner: Decodable {
  let projectID: String?
  let profileID: String?
  let caller: String?
  let transport: String?
  let socketConnectionID: String?
  let tunnelInstanceID: String?
  let tunnelProfileID: String?
  let principalID: String?

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case profileID = "profile_id"
    case caller
    case transport
    case socketConnectionID = "socket_connection_id"
    case tunnelInstanceID = "tunnel_instance_id"
    case tunnelProfileID = "tunnel_profile_id"
    case principalID = "principal_id"
  }

  var runtimeOwner: CodexRuntimeOwner {
    .init(
      workspaceID: projectID, profileID: profileID, caller: caller, transport: transport,
      socketConnectionID: socketConnectionID, tunnelInstanceID: tunnelInstanceID,
      tunnelProfileID: tunnelProfileID, principalID: principalID)
  }
}

/// The host preflights and authorizes using the connection's immutable caller and selected project.
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
