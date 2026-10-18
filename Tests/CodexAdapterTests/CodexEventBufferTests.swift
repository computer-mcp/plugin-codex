import CodexAppServerProtocol
import Foundation
import Testing

@testable import CodexAdapter

@Suite

final class CodexEventBufferTests {
  @Test
  func testLargeEventPayloadIsReplacedWithBoundedMechanicalPreview() async throws {
    let buffer = CodexEventBuffer(capacity: 64, maxOutputBytes: 4_096)
    await buffer.append(
      kind: "server_message",
      payload: .object(["html": .string(String(repeating: "x", count: 32_000))])
    )

    let result = await buffer.read(afterCursor: 0, maxResults: 100)
    let event = try #require(result.objectValue?["events"]?.arrayValue?.first?.objectValue)
    let payload = try #require(event["payload"]?.objectValue)

    #expect((payload["truncated"]) == (.bool(true)))
    #expect((payload["encoding"]) == (.string("json")))
    #expect((payload["original_bytes"]?.intValue ?? 0) > (32_000))
    #expect((payload["preview"]?.stringValue?.utf8.count ?? .max) < (4_096))
    #expect((result.objectValue?["result_truncated"]) == (.bool(false)))
  }

  @Test
  func testEventPageStopsAtByteBudgetAndCursorCanContinue() async throws {
    let buffer = CodexEventBuffer(capacity: 64, maxOutputBytes: 4_096)
    for sequence in 1...12 {
      await buffer.append(
        kind: "chunk",
        payload: .object([
          "sequence": .number(Double(sequence)),
          "text": .string(String(repeating: "a", count: 240)),
        ])
      )
    }

    let first = await buffer.read(afterCursor: 0, maxResults: 100)
    let firstCount = try #require(first.objectValue?["returned_events"]?.intValue)
    let firstCursor = try #require(first.objectValue?["next_cursor"]?.intValue)

    #expect((firstCount) > (0))
    #expect((firstCount) < (12))
    #expect((first.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((first.objectValue?["remaining_events"]) == (.number(Double(12 - firstCount))))

    let second = await buffer.read(afterCursor: firstCursor, maxResults: 100)
    #expect((second.objectValue?["returned_events"]?.intValue ?? 0) > (0))
    #expect((second.objectValue?["after_cursor"]) == (.number(Double(firstCursor))))
  }

  @Test
  func testEventPayloadIsRedactedBeforeRetention() async throws {
    let buffer = CodexEventBuffer(capacity: 8, maxOutputBytes: 4_096)
    await buffer.append(
      kind: "diagnostic",
      payload: .object([
        "message": .string("Authorization: Bearer event-secret"),
        "token": .string("event-secret"),
      ])
    )

    let result = await buffer.read(afterCursor: 0, maxResults: 10)
    let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    #expect(encoded.contains("[REDACTED]"))
    #expect(!encoded.contains("event-secret"))
  }

  @Test
  func nativeUsageCountersSurviveEventRetentionExactly() async throws {
    let usage = CodexAppServerProtocol.Stable.TokenUsageBreakdown(
      cacheWriteInputTokens: 2,
      cachedInputTokens: 3,
      inputTokens: 9_007_199_254_740_993,
      outputTokens: 5,
      reasoningOutputTokens: 7,
      totalTokens: Int64.max
    )
    let native = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(usage))
    let execEncoder = JSONEncoder()
    execEncoder.keyEncodingStrategy = .convertToSnakeCase
    let exec = try JSONDecoder().decode(JSONValue.self, from: execEncoder.encode(usage))
    let buffer = CodexEventBuffer(capacity: 8, maxOutputBytes: 65_536)
    await buffer.append(kind: "turn.completed", payload: .object(["usage": exec]))
    await buffer.append(
      kind: "notification",
      payload: .object([
        "method": .string("thread/tokenUsage/updated"),
        "params": .object([
          "tokenUsage": .object([
            "last": native, "total": native, "modelContextWindow": .integer(Int64.max),
          ])
        ]),
      ]))
    await buffer.append(
      kind: "goal/updated",
      payload: .object(["tokenBudget": .null, "tokensUsed": .integer(9_007_199_254_740_993)]))

    let result = await buffer.read(afterCursor: 0, maxResults: 10)
    let events = try #require(result.objectValue?["events"]?.arrayValue)
    #expect(events.count == 3)
    #expect(events[0].objectValue?["payload"]?.objectValue?["usage"] == exec)
    let retained = try #require(
      events[1].objectValue?["payload"]?.objectValue?["params"]?.objectValue?["tokenUsage"]?
        .objectValue?["total"])
    #expect(
      try JSONDecoder().decode(
        CodexAppServerProtocol.Stable.TokenUsageBreakdown.self,
        from: JSONEncoder().encode(retained)) == usage)
    #expect(events[2].objectValue?["payload"]?.objectValue?["tokenBudget"] == .null)
    #expect(
      events[2].objectValue?["payload"]?.objectValue?["tokensUsed"]
        == .integer(9_007_199_254_740_993))
  }

  @Test
  func usageContainersStillRedactCredentialsAndInvalidCounters() async throws {
    let buffer = CodexEventBuffer(capacity: 8, maxOutputBytes: 65_536)
    await buffer.append(
      kind: "notification",
      payload: .object([
        "tokenUsage": .object([
          "accessToken": .string("nested-secret"),
          "last": .object([
            "inputTokens": .string("counter-secret"),
            "outputTokens": .integer(3),
            "tokenBudget": .object(["credential": .string("budget-secret")]),
          ]),
        ]),
        "token_usage": .string("container-secret"),
        "refresh_token": .integer(123_456),
        "password": .integer(987_654),
        "authorization": .string("Bearer auth-secret"),
      ]))
    let result = await buffer.read(afterCursor: 0, maxResults: 10)
    let payload = try #require(
      result.objectValue?["events"]?.arrayValue?.first?.objectValue?["payload"]?.objectValue)
    let usage = try #require(payload["tokenUsage"]?.objectValue)
    #expect(usage["accessToken"] == .string("[REDACTED]"))
    #expect(usage["last"]?.objectValue?["inputTokens"] == .string("[REDACTED]"))
    #expect(usage["last"]?.objectValue?["outputTokens"] == .integer(3))
    #expect(usage["last"]?.objectValue?["tokenBudget"] == .string("[REDACTED]"))
    for key in ["token_usage", "refresh_token", "password", "authorization"] {
      #expect(payload[key] == .string("[REDACTED]"))
    }
    let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    #expect(!encoded.contains("secret"))
    #expect(!encoded.contains("123456"))
    #expect(!encoded.contains("987654"))
  }

  @Test(arguments: ["api_key", "apiKey", "api-key", "APIKEY"])
  func usageContainersRedactAPIKeys(key: String) async throws {
    let buffer = CodexEventBuffer(capacity: 8, maxOutputBytes: 65_536)
    await buffer.append(
      kind: "notification",
      payload: .object([
        "tokenUsage": .object([
          key: .string("api-credential-fixture"), "inputTokens": .integer(3),
        ])
      ]))
    let result = await buffer.read(afterCursor: 0, maxResults: 10)
    let usage = try #require(
      result.objectValue?["events"]?.arrayValue?.first?.objectValue?["payload"]?.objectValue?[
        "tokenUsage"]?.objectValue)
    #expect(usage[key] == .string("[REDACTED]"))
    #expect(usage["inputTokens"] == .integer(3))
  }
}
