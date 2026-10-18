import Foundation

/// Native remote-control status describes desired connectivity, not joined cleanup.
struct CodexRemoteControlWork: Sendable {
  private struct Entry: Sendable {
    let generation: Int
    let binding: CodexWorkBinding
    var initialStatusPending: Bool
    var enabled = false
    var state: CodexWorkResource.State = .uncertain
  }

  private var entry: Entry?
  var isEmpty: Bool { entry == nil }

  mutating func started(generation: Int, origin: CodexWorkOrigin) {
    entry = .init(
      generation: generation, binding: .init(origin: origin), initialStatusPending: true)
  }

  mutating func prepare(method: String, generation: Int) {
    if method == "remoteControl/disable" {
      entry?.state = .uncertain
      return
    }
    guard method == "remoteControl/enable" || method == "remoteControl/pairing/start" else {
      return
    }
    if entry == nil || entry?.initialStatusPending == true {
      entry = .init(
        generation: generation,
        binding: .init(origin: .init(invocation: CodexWorkInvocation.current)),
        initialStatusPending: false)
    }
    entry?.enabled = true
  }

  mutating func notified(params: [String: JSONValue], generation: Int) {
    guard let status = params["status"]?.stringValue else { return }
    if status == "disabled" {
      if entry?.initialStatusPending == true, entry?.enabled == false {
        entry = nil
      } else {
        entry?.state = .uncertain
      }
      return
    }
    if entry == nil {
      // Another native client can enable the same process. Observing its status
      // cannot grant an adapter invocation ownership of that external action.
      entry = .init(generation: generation, binding: .init(), initialStatusPending: false)
    }
    entry?.initialStatusPending = false
    entry?.enabled = true
    entry?.state = status == "connected" || status == "connecting" ? .active : .uncertain
  }

  func workResources() throws -> [CodexWorkResource] {
    guard let entry else { return [] }
    return [try entry.binding.resource("codex.app.remote-control", state: entry.state)]
  }

  mutating func retired(generation: Int) {
    if entry?.generation == generation { entry = nil }
  }
}
