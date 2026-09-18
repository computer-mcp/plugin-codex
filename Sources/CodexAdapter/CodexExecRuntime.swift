import CodexExec
import Foundation

protocol CodexExecRuntimeProtocol: Sendable {
  func start(prompt: String, model: String?, options: JSONValue?) async throws -> JSONValue
  func resume(upstreamSessionID: String, prompt: String?, model: String?, options: JSONValue?)
    async throws -> JSONValue
  func list() async -> JSONValue
  func events(sessionID: String, afterCursor: Int, maxResults: Int) async throws -> JSONValue
  func result(sessionID: String) async throws -> JSONValue
  func cancel(sessionID: String) async throws -> JSONValue
  func shutdown() async
}

extension CodexExecRuntimeProtocol {
  func shutdown() async {}
}

struct CodexExecRuntimeError: Error, LocalizedError, Equatable, Sendable {
  let code: String
  let message: String

  var errorDescription: String? {
    "\(code): \(message)"
  }
}

protocol CodexExecProcessHandleAdapter: Sendable {
  var stdoutLines: AsyncThrowingStream<String, Error> { get }
  func waitForTermination() async throws -> CodexExecTermination
}

protocol CodexExecClientAdapter: Sendable {
  func run(_ request: CodexExecRunRequest) async throws -> any CodexExecProcessHandleAdapter
  func resume(_ request: CodexExecResumeRequest) async throws
    -> any CodexExecProcessHandleAdapter
}

extension CodexExecProcessHandle: CodexExecProcessHandleAdapter {}

private struct LiveCodexExecClientAdapter: CodexExecClientAdapter {
  let configuration: CodexConfig
  let workspaceURL: URL

  private func makeClient() throws -> CodexExecClient {
    let environment = CodexProcessEnvironment.resolved()
    return CodexExecClient(
      configuration: .init(
        executableURL: try configuration.resolvedExecutableURL(
          workspaceURL: workspaceURL, environment: environment),
        environmentOverride: environment,
        defaultWorkingDirectory: workspaceURL))
  }

  func run(_ request: CodexExecRunRequest) async throws
    -> any CodexExecProcessHandleAdapter
  {
    try await makeClient().run(request)
  }

  func resume(_ request: CodexExecResumeRequest) async throws
    -> any CodexExecProcessHandleAdapter
  {
    try await makeClient().resume(request)
  }
}

actor LiveCodexExecRuntime: CodexExecRuntimeProtocol {
  private enum Operation: String, Sendable {
    case start
    case resume
  }

  private enum State: String, Sendable {
    case running
    case cancellationRequested = "cancellation_requested"
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
      self != .running && self != .cancellationRequested
    }
  }

  private struct Session: Sendable {
    let id: String
    let operation: Operation
    let createdAt: Date
    let eventBuffer: CodexEventBuffer
    let requestedUpstreamSessionID: String?
    let model: String?
    var updatedAt: Date
    var state: State
    var cancellationRequested = false
    var cleanupConfirmed = false
    var upstreamSessionID: String?
    var finalMessage: String?
    var termination: CodexExecTermination?
    var partialObservation: CodexExecPartialObservation?
    var failure: CodexExecRuntimeError?
    var streamTask: Task<Void, Never>?
    var waitTask: Task<Void, Never>?
  }

  private let configuration: CodexConfig
  private let workspaceURL: URL
  private let outputBounds: CodexOutputBounds
  private let client: any CodexExecClientAdapter
  private let threadOwnerIndex: CodexThreadOwnerIndex?
  private var sessions: [String: Session] = [:]
  private var pendingLaunches = 0

  init(
    configuration: CodexConfig,
    workspaceURL: URL,
    maxOutputBytes: Int = 1_048_576, threadOwnerIndex: CodexThreadOwnerIndex? = nil
  ) {
    let standardizedWorkspace = workspaceURL.standardizedFileURL
    self.threadOwnerIndex = threadOwnerIndex
    self.configuration = configuration
    self.workspaceURL = standardizedWorkspace
    self.outputBounds = CodexOutputBounds(maxOutputBytes: maxOutputBytes)
    self.client = LiveCodexExecClientAdapter(
      configuration: configuration, workspaceURL: standardizedWorkspace
    )
  }

  init(
    configuration: CodexConfig,
    workspaceURL: URL,
    maxOutputBytes: Int = 1_048_576,
    client: any CodexExecClientAdapter, threadOwnerIndex: CodexThreadOwnerIndex? = nil
  ) {
    self.threadOwnerIndex = threadOwnerIndex
    self.configuration = configuration
    self.workspaceURL = workspaceURL.standardizedFileURL
    self.outputBounds = CodexOutputBounds(maxOutputBytes: maxOutputBytes)
    self.client = client
  }

  func start(prompt: String, model: String? = nil, options: JSONValue? = nil) async throws
    -> JSONValue
  {
    let validatedPrompt = try Self.validatedPrompt(prompt, required: true)
    let validatedModel = try Self.validatedModel(model)
    let native = try CodexExecOptions(
      options, model: validatedModel, configuration: configuration, workspaceURL: workspaceURL)
    try reserveSessionSlot()

    let request = CodexExecRunRequest(
      promptInput: native.stdin.map { .textWithStdinContext(prompt: validatedPrompt, stdin: $0) }
        ?? .text(validatedPrompt),
      outputMode: .jsonl,
      options: native.request,
      outputSchemaFile: native.outputSchemaFile,
      outputLastMessageFile: native.outputLastMessageFile
    )
    let handle: any CodexExecProcessHandleAdapter
    do {
      handle = try await client.run(request)
    } catch {
      pendingLaunches -= 1
      throw Self.runtimeError(for: error)
    }
    pendingLaunches -= 1

    return await register(
      handle: handle,
      operation: .start,
      requestedUpstreamSessionID: nil,
      model: validatedModel
    )
  }

  func resume(
    upstreamSessionID: String, prompt: String?, model: String? = nil, options: JSONValue? = nil
  ) async throws -> JSONValue {
    let validatedSessionID = try Self.validatedUpstreamSessionID(upstreamSessionID)
    try threadOwnerIndex?.check(threadID: validatedSessionID)
    let validatedPrompt = try Self.validatedPrompt(prompt, required: false)
    let native = try CodexExecOptions(
      options, model: Self.validatedModel(model), configuration: configuration,
      workspaceURL: workspaceURL)
    try threadOwnerIndex?.claim(threadID: validatedSessionID)
    try reserveSessionSlot()
    let request = CodexExecResumeRequest(
      selector: .sessionID(validatedSessionID),
      promptInput: native.stdin.map { input in
        validatedPrompt.map { .textWithStdinContext(prompt: $0, stdin: input) } ?? .stdin(input)
      } ?? validatedPrompt.map(CodexExecPromptInput.text),
      outputMode: .jsonl,
      options: native.request,
      outputSchemaFile: native.outputSchemaFile,
      outputLastMessageFile: native.outputLastMessageFile
    )
    let handle: any CodexExecProcessHandleAdapter
    do {
      handle = try await client.resume(request)
    } catch {
      pendingLaunches -= 1
      throw Self.runtimeError(for: error)
    }
    pendingLaunches -= 1

    return await register(
      handle: handle,
      operation: .resume,
      requestedUpstreamSessionID: validatedSessionID,
      model: native.request.model
    )
  }

  func list() -> JSONValue {
    let rows = sessions.values
      .sorted {
        if $0.createdAt == $1.createdAt {
          return $0.id < $1.id
        }
        return $0.createdAt < $1.createdAt
      }
      .map(sessionSummary)
    return .object([
      "sessions": .array(rows),
      "max_sessions": .number(Double(configuration.maxSessions)),
    ])
  }

  func events(
    sessionID: String,
    afterCursor: Int,
    maxResults: Int
  ) async throws -> JSONValue {
    let session = try session(named: sessionID)
    return await session.eventBuffer.read(
      afterCursor: max(afterCursor, 0),
      maxResults: maxResults
    )
  }

  func result(sessionID: String) throws -> JSONValue {
    let session = try session(named: sessionID)
    guard session.state.isTerminal else {
      throw CodexExecRuntimeError(
        code: "codex.exec.not_finished",
        message: "Exec session '\(sessionID)' is still running."
      )
    }

    var result = sessionSummary(session).objectValue ?? [:]
    result["workspace"] = .string(workspaceURL.path)
    if let finalMessage = session.finalMessage {
      let bounded = outputBounds.text(finalMessage)
      result["final_message"] = .string(bounded.value)
      result["final_message_original_bytes"] = .number(Double(bounded.originalBytes))
      result["final_message_truncated"] = .bool(bounded.truncated)
    } else {
      result["final_message"] = .null
      result["final_message_original_bytes"] = .number(0)
      result["final_message_truncated"] = .bool(false)
    }
    result["termination"] = session.termination.map { terminationJSON($0) } ?? .null
    result["error"] = session.failure.map { errorJSON($0) } ?? .null
    result["output_capture"] =
      (session.termination?.outputCapture ?? session.partialObservation?.outputCapture)
      .map(Self.outputCaptureJSON) ?? .null
    return .object(result)
  }

  func cancel(sessionID: String) async throws -> JSONValue {
    var session = try session(named: sessionID)
    guard !session.state.isTerminal else {
      throw CodexExecRuntimeError(
        code: "codex.exec.already_finished",
        message: "Exec session '\(sessionID)' is already \(session.state.rawValue)."
      )
    }

    session.state = .cancellationRequested
    session.cancellationRequested = true
    session.updatedAt = Date()
    sessions[sessionID] = session
    await session.eventBuffer.append(
      kind: "session.cancellation_requested",
      payload: .object(["session_id": .string(sessionID)]))
    session.streamTask?.cancel()
    session.waitTask?.cancel()
    return .object([
      "session_id": .string(sessionID),
      "state": .string(State.cancellationRequested.rawValue),
      "cancellation_requested": .bool(true),
      "cleanup_confirmed": .bool(false),
    ])
  }

  func shutdown() async {
    let owned = sessions.values.filter { !$0.state.isTerminal }
    for session in owned { _ = try? await cancel(sessionID: session.id) }
    for session in owned { await session.waitTask?.value }
    pendingLaunches = 0
  }

  private func register(
    handle: any CodexExecProcessHandleAdapter,
    operation: Operation,
    requestedUpstreamSessionID: String?,
    model: String?
  ) async -> JSONValue {
    let sessionID = UUID().uuidString.lowercased()
    let now = Date()
    let eventBuffer = CodexEventBuffer(
      capacity: configuration.maxEventsPerSession,
      maxOutputBytes: outputBounds.maxOutputBytes
    )
    let session = Session(
      id: sessionID,
      operation: operation,
      createdAt: now,
      eventBuffer: eventBuffer,
      requestedUpstreamSessionID: requestedUpstreamSessionID,
      model: model,
      updatedAt: now,
      state: .running
    )
    sessions[sessionID] = session
    await eventBuffer.append(
      kind: "session.started",
      payload: .object([
        "session_id": .string(sessionID),
        "operation": .string(operation.rawValue),
      ])
    )

    let streamTask = Task { [weak self, handle] in
      guard let self else {
        return
      }
      await self.consumeOutput(from: handle, sessionID: sessionID)
    }
    let waitTask = Task { [weak self, handle, streamTask] in
      do {
        let termination = try await handle.waitForTermination()
        await streamTask.value
        await self?.complete(sessionID: sessionID, termination: termination)
      } catch {
        await streamTask.value
        await self?.fail(sessionID: sessionID, error: error)
      }
    }
    if var registered = sessions[sessionID], !registered.state.isTerminal {
      registered.streamTask = streamTask
      registered.waitTask = waitTask
      sessions[sessionID] = registered
    }
    return sessionSummary(sessions[sessionID] ?? session)
  }

  private func consumeOutput(
    from handle: any CodexExecProcessHandleAdapter,
    sessionID: String
  ) async {
    let decoder = CodexExecJSONLDecoder()
    do {
      for try await line in handle.stdoutLines {
        if Task.isCancelled {
          return
        }
        await record(line: line, decoder: decoder, sessionID: sessionID)
      }
    } catch is CancellationError {
      return
    } catch {
      await recordStreamFailure(sessionID: sessionID, error: error)
    }
  }

  private func record(
    line: String,
    decoder: CodexExecJSONLDecoder,
    sessionID: String
  ) async {
    guard var session = sessions[sessionID], !session.state.isTerminal else {
      return
    }

    let payload: JSONValue
    let kind: String
    do {
      payload = try Self.jsonValue(fromLine: line)
      kind = payload.objectValue?["type"]?.stringValue ?? "jsonl.unknown"
    } catch {
      payload = .object(["raw": .string(line)])
      kind = "jsonl.malformed"
    }

    do {
      let event = try decoder.decodeLine(line)
      switch event {
      case .threadStarted(let id):
        do { try threadOwnerIndex?.claim(threadID: id) } catch {
          await recordStreamFailure(sessionID: sessionID, error: error)
          sessions[sessionID]?.waitTask?.cancel()
          return
        }
        session.upstreamSessionID = id
      case .itemStarted(let item), .itemUpdated(let item), .itemCompleted(let item):
        if case .agentMessage(let message) = item {
          session.finalMessage = message.text
        }
      default:
        break
      }
    } catch {
      // The raw malformed line remains observable; the waiter supplies the terminal error.
    }

    session.updatedAt = Date()
    sessions[sessionID] = session
    await session.eventBuffer.append(kind: kind, payload: payload)
  }

  private func recordStreamFailure(sessionID: String, error: Error) async {
    guard var session = sessions[sessionID], !session.state.isTerminal else {
      return
    }
    let runtimeError = Self.runtimeError(for: error)
    session.failure = runtimeError
    session.updatedAt = Date()
    sessions[sessionID] = session
    await session.eventBuffer.append(
      kind: "stream.failed",
      payload: errorJSON(runtimeError)
    )
  }

  private func complete(sessionID: String, termination: CodexExecTermination) async {
    guard var session = sessions[sessionID], !session.state.isTerminal else {
      return
    }
    session.state = session.failure == nil ? .completed : .failed
    session.updatedAt = Date()
    session.termination = termination
    session.cleanupConfirmed = true
    session.streamTask = nil
    session.waitTask = nil
    sessions[sessionID] = session
    await session.eventBuffer.append(
      kind: session.state == .completed ? "session.completed" : "session.failed",
      payload: session.failure.map { errorJSON($0) } ?? terminationJSON(termination)
    )
  }

  private func fail(sessionID: String, error: Error) async {
    guard var session = sessions[sessionID], !session.state.isTerminal else {
      return
    }
    let runtimeError = Self.runtimeError(for: error)
    session.state = runtimeError.code == "codex.exec.cancelled" ? .cancelled : .failed
    session.updatedAt = Date()
    session.failure = runtimeError
    session.partialObservation = Self.partialObservation(error)
    session.cleanupConfirmed = Self.terminationConfirmed(error)
    session.finalMessage = session.finalMessage ?? session.partialObservation?.finalMessageText
    session.upstreamSessionID =
      session.upstreamSessionID ?? session.partialObservation?.resolvedSessionID
    session.streamTask = nil
    session.waitTask = nil
    sessions[sessionID] = session
    await session.eventBuffer.append(
      kind: session.state == .cancelled ? "session.cancelled" : "session.failed",
      payload: errorJSON(runtimeError)
    )
  }

  private func reserveSessionSlot() throws {
    while sessions.count + pendingLaunches >= configuration.maxSessions {
      guard
        let evicted = sessions.values
          .filter({ $0.state.isTerminal && $0.cleanupConfirmed })
          .min(by: {
            if $0.updatedAt == $1.updatedAt {
              return $0.id < $1.id
            }
            return $0.updatedAt < $1.updatedAt
          })
      else {
        throw CodexExecRuntimeError(
          code: "codex.exec.session_limit",
          message:
            "The configured limit of \(configuration.maxSessions) active sessions was reached."
        )
      }
      sessions.removeValue(forKey: evicted.id)
    }
    pendingLaunches += 1
  }

  private func session(named sessionID: String) throws -> Session {
    guard let session = sessions[sessionID] else {
      throw CodexExecRuntimeError(
        code: "codex.exec.session_unknown",
        message: "Unknown or evicted exec session '\(sessionID)'."
      )
    }
    return session
  }

  private func sessionSummary(_ session: Session) -> JSONValue {
    .object([
      "session_id": .string(session.id),
      "operation": .string(session.operation.rawValue),
      "state": .string(session.state.rawValue),
      "cancellation_requested": .bool(session.cancellationRequested),
      "cleanup_confirmed": .bool(session.cleanupConfirmed),
      "created_at": .string(session.createdAt.formatted(Self.timestampFormat)),
      "updated_at": .string(session.updatedAt.formatted(Self.timestampFormat)),
      "upstream_session_id": session.upstreamSessionID.map(JSONValue.string) ?? .null,
      "requested_upstream_session_id":
        session.requestedUpstreamSessionID.map(JSONValue.string) ?? .null,
      "model": session.model.map(JSONValue.string) ?? .null,
    ])
  }

  private static func validatedPrompt(_ prompt: String?, required: Bool) throws -> String? {
    guard let prompt else {
      if required {
        throw CodexExecRuntimeError(
          code: "codex.exec.invalid_prompt",
          message: "prompt is required."
        )
      }
      return nil
    }
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CodexExecRuntimeError(
        code: "codex.exec.invalid_prompt",
        message: "prompt must not be empty."
      )
    }
    guard prompt.utf8.count <= 1_048_576 else {
      throw CodexExecRuntimeError(
        code: "codex.exec.invalid_prompt",
        message: "prompt must not exceed 1048576 UTF-8 bytes."
      )
    }
    return prompt
  }

  private static func validatedPrompt(_ prompt: String, required: Bool) throws -> String {
    try validatedPrompt(Optional(prompt), required: required) ?? ""
  }

  private static func validatedModel(_ model: String?) throws -> String? {
    guard let model else {
      return nil
    }
    guard !model.isEmpty, model.utf8.count <= 256,
      model.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
      throw CodexExecRuntimeError(
        code: "codex.exec.invalid_model",
        message: "model must contain 1 to 256 UTF-8 bytes without control characters."
      )
    }
    return model
  }

  private static func validatedUpstreamSessionID(_ sessionID: String) throws -> String {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    )
    guard !sessionID.isEmpty, sessionID.utf8.count <= 256,
      sessionID.unicodeScalars.allSatisfy(allowed.contains)
    else {
      throw CodexExecRuntimeError(
        code: "codex.exec.invalid_upstream_session_id",
        message:
          "upstream_session_id must contain 1 to 256 ASCII letters, digits, '_' or '-'."
      )
    }
    return sessionID
  }

  private static func jsonValue(fromLine line: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
  }

  private static func runtimeError(for error: Error) -> CodexExecRuntimeError {
    let mapped = unredactedRuntimeError(for: error)
    return CodexExecRuntimeError(
      code: mapped.code,
      message: CodexApprovalRedactor.redactString(mapped.message)
    )
  }

  private static func unredactedRuntimeError(for error: Error) -> CodexExecRuntimeError {
    if let error = error as? CodexExecRuntimeError {
      return error
    }
    guard let error = error as? CodexExecError else {
      return CodexExecRuntimeError(
        code: "codex.exec.execution_failed",
        message: error.localizedDescription
      )
    }
    switch error {
    case .launchFailure(let description):
      return .init(code: "codex.exec.launch_failed", message: description)
    case .invalidInvocation(let description):
      return .init(code: "codex.exec.invalid_invocation", message: description)
    case .resumeTargetNotFound:
      return .init(
        code: "codex.exec.resume_target_not_found",
        message: "The requested upstream Codex session was not found."
      )
    case .nonZeroExit(let code, let stderr, _):
      return .init(
        code: "codex.exec.non_zero_exit",
        message: "Codex exited with code \(code): \(stderr)"
      )
    case .malformedJSONL:
      return .init(
        code: "codex.exec.malformed_jsonl",
        message: "Codex emitted malformed JSONL output."
      )
    case .interrupted:
      return .init(
        code: "codex.exec.interrupted",
        message: "Codex execution was interrupted."
      )
    case .cancelled:
      return .init(
        code: "codex.exec.cancelled",
        message: "Codex execution was cancelled."
      )
    case .outputCaptureLimitExceeded:
      return .init(
        code: "codex.exec.output_capture_limit",
        message: "Codex output exceeded the capture budget; preserved output is incomplete.")
    case .outputFileFailure(_, let description, _):
      return .init(code: "codex.exec.output_file_failed", message: description)
    }
  }

  private static func partialObservation(_ error: Error) -> CodexExecPartialObservation? {
    guard let error = error as? CodexExecError else { return nil }
    switch error {
    case .launchFailure, .invalidInvocation: return nil
    case .resumeTargetNotFound(_, let partial), .nonZeroExit(_, _, let partial),
      .malformedJSONL(_, let partial), .interrupted(let partial), .cancelled(let partial),
      .outputFileFailure(_, _, let partial):
      return partial
    case .outputCaptureLimitExceeded(let partial): return partial
    }
  }

  private static func terminationConfirmed(_ error: Error) -> Bool {
    guard let error = error as? CodexExecError else { return false }
    switch error {
    case .launchFailure, .invalidInvocation: return false
    case .resumeTargetNotFound, .nonZeroExit, .malformedJSONL, .interrupted, .cancelled,
      .outputCaptureLimitExceeded, .outputFileFailure:
      return true
    }
  }

  private static func outputCaptureJSON(_ capture: CodexExecOutputCapture) -> JSONValue {
    .object([
      "complete": .bool(capture.isComplete),
      "stdout_dropped_bytes": .number(Double(capture.stdoutDroppedBytes)),
      "stderr_dropped_bytes": .number(Double(capture.stderrDroppedBytes)),
    ])
  }

  private func terminationJSON(_ termination: CodexExecTermination) -> JSONValue {
    let exit: JSONValue
    switch termination.exitInterpretation {
    case .exited(let code):
      exit = .object([
        "kind": .string("exited"),
        "code": .number(Double(code)),
      ])
    case .signaled(let signal):
      exit = .object([
        "kind": .string("signaled"),
        "signal": .number(Double(signal)),
      ])
    }
    let stderr = outputBounds.text(termination.capturedStderrText)
    return .object([
      "operation": .string(
        termination.operation == .run ? Operation.start.rawValue : Operation.resume.rawValue
      ),
      "working_directory":
        termination.effectiveWorkingDirectory.map { .string($0.path) } ?? .null,
      "exit": exit,
      "stderr": .string(stderr.value),
      "stderr_original_bytes": .number(Double(stderr.originalBytes)),
      "stderr_truncated": .bool(stderr.truncated),
    ])
  }

  private func errorJSON(_ error: CodexExecRuntimeError) -> JSONValue {
    let message = outputBounds.text(error.message)
    return .object([
      "code": .string(error.code),
      "message": .string(message.value),
      "message_original_bytes": .number(Double(message.originalBytes)),
      "message_truncated": .bool(message.truncated),
    ])
  }

  private static let timestampFormat = Date.ISO8601FormatStyle(
    includingFractionalSeconds: true
  )
}
