import Foundation
import Testing

@testable import CodexAdapter

struct CodexAppAsyncWorkTests {
  @Test
  func nativeLoginAcknowledgementEnrichesTheSameOwnedLifetime() throws {
    var work = CodexAppAsyncWork()
    let creator = UUID()
    let ticket = try CodexWorkInvocation.$current.withValue(creator) {
      try work.prepare(
        method: "account/login/start", params: .object(["type": .string("chatgpt")]),
        generation: 1)
    }
    let pending = try #require(work.workResources().first)
    #expect(pending.handles.isEmpty)
    work.replied(ticket, response: .object(["loginId": .string("native-login")]))
    let acknowledged = try #require(work.workResources().first)
    #expect(acknowledged.id == pending.id && acknowledged.acquiredBy == creator)
    #expect(acknowledged.handles == ["login_id": .string("native-login")])
    work.failed(ticket, rejected: false)
    let uncertain = try #require(work.workResources().first)
    #expect(uncertain.handles == acknowledged.handles && uncertain.state == .uncertain)
    work.notified(
      method: "account/login/completed", params: ["loginId": .string("other")], generation: 1)
    #expect(try work.workResources() == [uncertain])
    work.notified(
      method: "account/login/completed", params: ["loginId": .string("native-login")],
      generation: 1)
    #expect(try work.workResources().isEmpty)
  }

  @Test
  func excessUnboundNativeSessionsCannotTurnIntoAnEmptySnapshot() throws {
    var work = CodexAppAsyncWork()
    for index in 0...256 {
      work.notified(
        method: "thread/realtime/started", params: ["threadId": .string("thread-\(index)")],
        generation: 1)
    }
    for index in 0...256 {
      work.notified(
        method: "thread/realtime/closed", params: ["threadId": .string("thread-\(index)")],
        generation: 1)
    }
    #expect(!work.isEmpty)
    #expect(throws: (any Error).self) { try work.workResources() }
    work.retired(generation: 2)
    #expect(throws: (any Error).self) { try work.workResources() }
    work.retired(generation: 1)
    #expect(work.isEmpty)
    #expect(try work.workResources().isEmpty)
  }
}
