import Foundation

/// Native handles belong to one App Server connection, even when their RPC has returned.
struct CodexNativeResources: Sendable {
  struct Key: Hashable, Sendable {
    let kind: String
    let id: String
  }
  struct Ticket: Sendable {
    let key: Key
    let generation: Int
    let token: UUID
    let starts: Bool
    let ends: Bool
  }
  private struct Entry: Sendable {
    let generation: Int
    let token: UUID
  }
  private var entries: [Key: Entry] = [:]
  var count: Int { entries.count }

  mutating func prepare(method: String, params: JSONValue?, generation: Int) throws -> Ticket? {
    let kind: String
    let field: String
    let starts: Bool
    let ends: Bool
    switch method {
    case "command/exec": (kind, field, starts, ends) = ("command", "processId", true, true)
    case "command/exec/write", "command/exec/resize":
      (kind, field, starts, ends) = ("command", "processId", false, false)
    case "command/exec/terminate":
      (kind, field, starts, ends) = ("command", "processId", false, false)
    case "process/spawn": (kind, field, starts, ends) = ("process", "processHandle", true, false)
    case "process/writeStdin", "process/resizePty", "process/kill":
      (kind, field, starts, ends) = ("process", "processHandle", false, false)
    case "fs/watch": (kind, field, starts, ends) = ("watch", "watchId", true, false)
    case "fs/unwatch": (kind, field, starts, ends) = ("watch", "watchId", false, true)
    case "mcpServer/event/stream/start":
      (kind, field, starts, ends) = ("stream", "subscriptionId", true, false)
    case "mcpServer/event/stream/stop":
      (kind, field, starts, ends) = ("stream", "subscriptionId", false, true)
    default: return nil
    }
    guard let id = params?.objectValue?[field]?.stringValue else {
      // A synchronous command need not expose an interactive handle.
      if method == "command/exec" { return nil }
      throw CodexToolError.invalidArguments("Native request requires \(field).")
    }
    guard !id.isEmpty, id.utf8.count <= 1_024,
      id.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw CodexToolError.invalidArguments("Native resource handle is invalid.") }
    let key = Key(kind: kind, id: id)
    if starts {
      guard entries[key] == nil, entries.count < 256 else {
        throw CodexToolError.disabled(
          "codex.app.resource_busy: Native handle is reserved or resource capacity is reached.")
      }
      let token = UUID()
      entries[key] = Entry(generation: generation, token: token)
      return Ticket(key: key, generation: generation, token: token, starts: true, ends: ends)
    }
    guard let entry = entries[key], entry.generation == generation else {
      throw CodexToolError.disabled(
        "codex.app.resource_unknown: Native handle is not owned by this connection generation.")
    }
    return Ticket(key: key, generation: generation, token: entry.token, starts: false, ends: ends)
  }

  mutating func completed(_ ticket: Ticket?, rejected: Bool = false) {
    guard let ticket, rejected ? ticket.starts : ticket.ends,
      let entry = entries[ticket.key], entry.generation == ticket.generation,
      entry.token == ticket.token
    else { return }
    entries.removeValue(forKey: ticket.key)
  }

  mutating func processExited(handle: String, generation: Int) {
    let key = Key(kind: "process", id: handle)
    if entries[key]?.generation == generation { entries.removeValue(forKey: key) }
  }

  mutating func retired(generation: Int) {
    entries = entries.filter { $0.value.generation != generation }
  }
}
