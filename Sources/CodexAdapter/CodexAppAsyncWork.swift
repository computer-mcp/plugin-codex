import Foundation

/// Native asynchronous starts acknowledge admission, not background completion.
struct CodexAppAsyncWork: Sendable {
  private enum Scope: Hashable, Sendable {
    case account
    case mcp(name: String, threadID: String?)
    case realtime(threadID: String)

    var kind: String {
      switch self {
      case .account: "codex.app.login"
      case .mcp: "codex.app.mcp-login"
      case .realtime: "codex.app.realtime"
      }
    }
  }

  struct Ticket: Sendable {
    let id: UUID
  }

  private struct Entry: Sendable {
    let scope: Scope
    let generation: Int
    let binding: CodexWorkBinding
    var awaitingReply = true
    var loginID: String?
    var completed = false
    var earlyCompletions: Set<String> = []
    var state: CodexWorkResource.State = .active
  }

  private var entries: [UUID: Entry] = [:]
  private var untrackedGenerations: Set<Int> = []
  var isEmpty: Bool { entries.isEmpty && untrackedGenerations.isEmpty }

  func hasWork(threadID: String) -> Bool {
    entries.values.contains { entry in
      switch entry.scope {
      case .account: false
      case .mcp(_, let id): id == threadID
      case .realtime(let id): id == threadID
      }
    }
  }

  mutating func prepare(method: String, params: JSONValue?, generation: Int) throws -> Ticket? {
    let scope: Scope
    let params = params?.objectValue ?? [:]
    switch method {
    case "account/login/start":
      guard let type = params["type"]?.stringValue,
        ["chatgpt", "chatgptDeviceCode"].contains(type)
      else { return nil }
      scope = .account
    case "mcpServer/oauth/login":
      guard let name = params["name"]?.stringValue else { return nil }
      scope = .mcp(name: name, threadID: params["threadId"]?.stringValue)
    case "thread/realtime/start":
      guard let threadID = params["threadId"]?.stringValue else { return nil }
      scope = .realtime(threadID: threadID)
    default: return nil
    }
    // MCP and realtime completion have no attempt ID. A second start on the same scope
    // cannot be correlated safely until the first completion is observed.
    let conflicts = entries.values.contains { entry in
      guard entry.scope == scope else { return false }
      return scope != .account || entry.awaitingReply
    }
    guard !conflicts, entries.count < 256 else {
      throw CodexToolError.disabled(
        "codex.app.async_work_busy: Native background work is still settling or capacity is reached."
      )
    }
    let ticket = Ticket(id: UUID())
    entries[ticket.id] = .init(
      scope: scope, generation: generation,
      binding: .init(origin: .init(invocation: CodexWorkInvocation.current)))
    return ticket
  }

  mutating func replied(_ ticket: Ticket?, response: JSONValue) {
    guard let ticket, var entry = entries[ticket.id] else { return }
    entry.awaitingReply = false
    if entry.scope == .account {
      guard let loginID = response.objectValue?["loginId"]?.stringValue else {
        // An undecodable acknowledgement cannot prove whether a login task exists.
        entry.state = .uncertain
        entries[ticket.id] = entry
        return
      }
      entry.loginID = loginID
      entry.completed = entry.earlyCompletions.contains(loginID)
      entry.earlyCompletions.removeAll()
    }
    if entry.completed {
      entries.removeValue(forKey: ticket.id)
    } else {
      entries[ticket.id] = entry
    }
  }

  mutating func failed(_ ticket: Ticket?, rejected: Bool) {
    guard let ticket, entries[ticket.id] != nil else { return }
    if rejected {
      entries.removeValue(forKey: ticket.id)
    } else {
      entries[ticket.id]?.state = .uncertain
    }
  }

  mutating func notified(method: String, params: [String: JSONValue], generation: Int) {
    if method == "thread/realtime/started", let threadID = params["threadId"]?.stringValue {
      let scope = Scope.realtime(threadID: threadID)
      if !entries.values.contains(where: { $0.scope == scope && $0.generation == generation }) {
        guard entries.count < 256, threadID.utf8.count <= 1_024 else {
          untrackedGenerations.insert(generation)
          return
        }
        entries[UUID()] = .init(
          scope: scope, generation: generation, binding: .init(), awaitingReply: false)
      }
      return
    }
    guard
      ["account/login/completed", "mcpServer/oauthLogin/completed", "thread/realtime/closed"]
        .contains(method)
    else { return }
    for id in entries.keys {
      guard var entry = entries[id], entry.generation == generation else { continue }
      switch entry.scope {
      case .account:
        guard method == "account/login/completed",
          let loginID = params["loginId"]?.stringValue, loginID.utf8.count <= 1_024
        else { continue }
        if entry.awaitingReply {
          if entry.earlyCompletions.count < 256 { entry.earlyCompletions.insert(loginID) }
        } else if entry.loginID == loginID {
          entry.completed = true
        }
      case .mcp(let name, let threadID):
        guard method == "mcpServer/oauthLogin/completed",
          params["name"]?.stringValue == name, params["threadId"]?.stringValue == threadID
        else { continue }
        entry.completed = true
      case .realtime(let threadID):
        guard method == "thread/realtime/closed", params["threadId"]?.stringValue == threadID else {
          continue
        }
        entry.completed = true
      }
      if entry.completed && !entry.awaitingReply {
        entries.removeValue(forKey: id)
      } else {
        entries[id] = entry
      }
    }
  }

  func workResources() throws -> [CodexWorkResource] {
    guard untrackedGenerations.isEmpty else {
      throw CodexToolError.executionFailed(
        "codex.app.work_unavailable: Native background work exceeds tracked capacity.")
    }
    return try entries.values.map { entry in
      var handles: [String: JSONValue] = [:]
      switch entry.scope {
      case .account:
        if let id = entry.loginID { handles["login_id"] = .string(id) }
      case .mcp(let name, let threadID):
        handles["name"] = .string(name)
        if let threadID { handles["thread_id"] = .string(threadID) }
      case .realtime(let threadID):
        handles["thread_id"] = .string(threadID)
      }
      return try entry.binding.resource(entry.scope.kind, state: entry.state, handles: handles)
    }
  }

  mutating func retired(generation: Int) {
    entries = entries.filter { $0.value.generation != generation }
    untrackedGenerations.remove(generation)
  }
}
