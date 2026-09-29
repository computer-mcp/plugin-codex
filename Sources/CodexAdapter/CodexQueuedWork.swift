import Foundation

/// Queued user messages can start a turn before enqueue returns its durable ID.
struct CodexQueuedWork: Sendable {
  struct Ticket: Sendable {
    let threadID: String
    let clientID: String
    let workID: String
  }
  private struct Key: Hashable, Sendable {
    let threadID: String
    let clientID: String
  }
  private struct Entry: Sendable {
    let generation: Int
    let binding: CodexWorkBinding
    var submissionID: String?
    var turnID: String?
    var awaitingReply = true
    var completed = false
    var state: CodexWorkResource.State = .active
  }
  private var entries: [Key: Entry] = [:]
  var isEmpty: Bool { entries.isEmpty }

  func hasPending(threadID: String) -> Bool {
    entries.contains { $0.key.threadID == threadID && $0.value.turnID == nil }
  }

  mutating func prepare(method: String, params: JSONValue?, generation: Int) throws -> Ticket? {
    guard method == "thread/queue/add",
      let threadID = params?.objectValue?["threadId"]?.stringValue,
      let clientID = params?.objectValue?["clientUserMessageId"]?.stringValue
    else { return nil }
    let key = Key(threadID: threadID, clientID: clientID)
    guard entries[key] == nil, entries.count < 256, clientID.utf8.count <= 1_024 else {
      throw CodexToolError.disabled(
        "codex.app.queue_work_busy: The client message identity is still owned or queue capacity is reached."
      )
    }
    let binding = CodexWorkBinding(origin: .init(invocation: CodexWorkInvocation.current))
    entries[key] = .init(generation: generation, binding: binding)
    return .init(threadID: threadID, clientID: clientID, workID: binding.id)
  }

  mutating func replied(_ ticket: Ticket?, response: JSONValue) {
    guard let ticket else { return }
    let key = Key(threadID: ticket.threadID, clientID: ticket.clientID)
    guard var entry = entries[key], entry.binding.id == ticket.workID else { return }
    entry.awaitingReply = false
    entry.submissionID = response.objectValue?["queuedSubmission"]?.objectValue?["id"]?.stringValue
    if entry.completed { entries.removeValue(forKey: key) } else { entries[key] = entry }
  }

  mutating func failed(_ ticket: Ticket?, rejected: Bool) {
    guard let ticket else { return }
    let key = Key(threadID: ticket.threadID, clientID: ticket.clientID)
    guard entries[key]?.binding.id == ticket.workID else { return }
    if rejected && entries[key]?.turnID == nil {
      entries.removeValue(forKey: key)
    } else {
      entries[key]?.state = .uncertain
    }
  }

  mutating func consumed(
    threadID: String, clientID: String, turnID: String, generation: Int
  ) -> CodexWorkOrigin? {
    let key = Key(threadID: threadID, clientID: clientID)
    guard let entry = entries[key], entry.generation == generation,
      entry.turnID == nil || entry.turnID == turnID
    else { return nil }
    entries[key]?.turnID = turnID
    return entry.binding.origin
  }

  func origin(threadID: String, submissionID: String?) -> CodexWorkOrigin? {
    guard let submissionID else { return nil }
    return entries.first {
      $0.key.threadID == threadID && $0.value.submissionID == submissionID
    }?.value.binding.origin
  }

  mutating func completed(threadID: String, turnID: String, generation: Int) {
    for key in entries.keys where key.threadID == threadID {
      guard let entry = entries[key], entry.generation == generation, entry.turnID == turnID else {
        continue
      }
      if entry.awaitingReply {
        entries[key]?.completed = true
      } else {
        entries.removeValue(forKey: key)
      }
    }
  }

  mutating func deleted(method: String, params: JSONValue?, response: JSONValue, generation: Int) {
    guard method == "thread/queue/delete", response.objectValue?["deleted"] == .bool(true),
      let threadID = params?.objectValue?["threadId"]?.stringValue,
      let submissionID = params?.objectValue?["queuedSubmissionId"]?.stringValue
    else { return }
    entries = entries.filter {
      $0.key.threadID != threadID || $0.value.generation != generation
        || $0.value.submissionID != submissionID || $0.value.turnID != nil
    }
  }

  func workResources() throws -> [CodexWorkResource] {
    try entries.filter { $0.value.turnID == nil }.map { key, entry in
      var handles: [String: JSONValue] = [
        "thread_id": .string(key.threadID), "client_id": .string(key.clientID),
      ]
      if let id = entry.submissionID { handles["submission_id"] = .string(id) }
      return try entry.binding.resource(
        "codex.app.queued-input", state: entry.state, handles: handles)
    }
  }

  mutating func retired(generation: Int) {
    entries = entries.filter { $0.value.generation != generation }
  }
}
