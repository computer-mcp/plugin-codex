import Foundation
import Testing

@testable import CodexAdapter

struct CodexAppAsyncWorkTests {
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
