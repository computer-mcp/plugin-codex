import CodexAppServerClient
import CodexAppServerProtocol
import CryptoKit
import Foundation

struct CodexRuntimeOwner: Codable, Equatable, Sendable {
  let workspaceID: String?
  let profileID: String?
  let caller: String?
  let transport: String?
  let socketConnectionID: String?
  let tunnelInstanceID: String?
  let tunnelProfileID: String?
  var principalID: String? = nil

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
    case profileID = "profile_id"
    case caller
    case transport
    case socketConnectionID = "socket_connection_id"
    case tunnelInstanceID = "tunnel_instance_id"
    case tunnelProfileID = "tunnel_profile_id"
    case principalID = "principal_id"
  }

}

private final class WeakCodexRuntimeBox: @unchecked Sendable {
  weak var runtime: LiveCodexAppServerRuntime?

  init(_ runtime: LiveCodexAppServerRuntime) {
    self.runtime = runtime
  }
}

final class CodexRuntimeDirectory: @unchecked Sendable {
  static let shared = CodexRuntimeDirectory()

  private let lock = NSLock()
  private var entries: [String: WeakCodexRuntimeBox] = [:]

  private init() {}

  func register(_ runtime: LiveCodexAppServerRuntime, id: String) {
    lock.withLock {
      entries[id] = WeakCodexRuntimeBox(runtime)
      pruneLocked()
    }
  }

  func unregister(id: String) {
    lock.withLock {
      _ = entries.removeValue(forKey: id)
    }
  }

  func runtime(id: String, workspaceID: String? = nil) -> LiveCodexAppServerRuntime? {
    lock.withLock {
      defer { pruneLocked() }
      guard let runtime = entries[id]?.runtime else { return nil }
      guard workspaceID == nil || runtime.owner?.workspaceID == workspaceID else { return nil }
      return runtime
    }
  }

  func statuses(workspaceID: String? = nil) async -> JSONValue {
    let runtimes = lock.withLock { () -> [LiveCodexAppServerRuntime] in
      pruneLocked()
      return entries.values.compactMap(\.runtime).filter {
        workspaceID == nil || $0.owner?.workspaceID == workspaceID
      }
    }
    var statuses: [JSONValue] = []
    for runtime in runtimes {
      statuses.append(await runtime.status())
    }
    statuses.sort {
      ($0.objectValue?["runtime_id"]?.stringValue ?? "")
        < ($1.objectValue?["runtime_id"]?.stringValue ?? "")
    }
    return .object(["runtimes": .array(statuses)])
  }

  func runtimes(
    owning threadID: String,
    workspaceID: String? = nil
  ) async -> [LiveCodexAppServerRuntime] {
    let runtimes = snapshot(workspaceID: workspaceID)
    var matches: [LiveCodexAppServerRuntime] = []
    for runtime in runtimes where await runtime.hasLiveOwnership(of: threadID) {
      matches.append(runtime)
    }
    return matches.sorted { $0.runtimeID < $1.runtimeID }
  }

  func runtimeIDs(
    owning threadID: String,
    workspaceID: String? = nil
  ) async -> [String] {
    await runtimes(owning: threadID, workspaceID: workspaceID).map(\.runtimeID)
  }

  private func snapshot(workspaceID: String?) -> [LiveCodexAppServerRuntime] {
    lock.withLock {
      pruneLocked()
      return entries.values.compactMap(\.runtime).filter {
        workspaceID == nil || $0.owner?.workspaceID == workspaceID
      }
    }
  }

  private func pruneLocked() {
    entries = entries.filter { $0.value.runtime != nil }
  }
}

protocol CodexAppServerRuntimeProtocol: Sendable {
  func status() async -> JSONValue
  func call(method: String, params: JSONValue?) async throws -> JSONValue
  func events(afterCursor: Int, maxResults: Int) async -> JSONValue
  func pendingRequests() async -> JSONValue
  func respond(requestID: String, response: JSONValue) async throws -> JSONValue
  func approvals(state: String?, limit: Int) async throws -> JSONValue
  func approval(id: String) async throws -> JSONValue
  func respondToApproval(id: String, response: JSONValue) async throws -> JSONValue
  func workResources() async throws -> [CodexWorkResource]
  func shutdown() async
}

extension CodexAppServerRuntimeProtocol {
  func workResources() async throws -> [CodexWorkResource] {
    throw CodexToolError.disabled("codex.app.work_unavailable: Runtime ownership is unavailable.")
  }
  func approvals(state: String?, limit: Int) async throws -> JSONValue {
    .object(["approvals": .array([])])
  }

  func approval(id: String) async throws -> JSONValue {
    throw CodexApprovalBrokerError.unknown(id)
  }

  func respondToApproval(id: String, response: JSONValue) async throws -> JSONValue {
    throw CodexApprovalBrokerError.unknown(id)
  }

  func shutdown() async {}
}

private final class CodexTimedRequestCompletion<Value: Sendable>: @unchecked Sendable {
  enum Participant {
    case operation
    case timeout
    case cancellation
  }

  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?
  private var operationTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var resolved = false

  func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !resolved else {
      return false
    }
    self.continuation = continuation
    return true
  }

  func installTasks(
    operation: Task<Void, Never>,
    timeout: Task<Void, Never>
  ) {
    lock.lock()
    operationTask = operation
    timeoutTask = timeout
    let shouldCancel = resolved
    lock.unlock()
    if shouldCancel {
      operation.cancel()
      timeout.cancel()
    }
  }

  func claim(_ participant: Participant) -> CheckedContinuation<Value, any Error>? {
    lock.lock()
    guard !resolved else {
      lock.unlock()
      return nil
    }
    resolved = true
    let continuation = continuation
    self.continuation = nil
    let operationTask = operationTask
    let timeoutTask = timeoutTask
    lock.unlock()

    switch participant {
    case .operation:
      timeoutTask?.cancel()
    case .timeout:
      operationTask?.cancel()
    case .cancellation:
      operationTask?.cancel()
      timeoutTask?.cancel()
    }
    return continuation
  }

  func resumeOperation(with result: Result<Value, any Error>) {
    claim(.operation)?.resume(with: result)
  }

  func cancel() {
    claim(.cancellation)?.resume(throwing: CancellationError())
  }
}

actor LiveCodexAppServerRuntime: CodexAppServerRuntimeProtocol {
  private typealias Stable = CodexAppServerProtocol.Stable
  private struct PendingUserInputRequest: Sendable {
    let handle: CodexAppServerRawServerRequest
    let connection: CodexAppServerConnection
    let payload: JSONValue
    let threadID: String?
    var kind: String {
      handle.method == "item/tool/requestUserInput" ? "user_input" : "mcp_elicitation"
    }
  }
  private typealias PendingApprovalHandle = CodexAppServerRawServerRequest

  private struct ConnectionStartup: Sendable {
    let id: UUID
    let work: CodexWorkBinding
    let transport: ManagedCodexAppServerTransport
    let task: Task<CodexAppServerConnection, Error>
  }

  private struct RequestGenerationRetirement: Sendable {
    let id: UUID
    let work: CodexWorkBinding
    let generation: Int
    let transport: ManagedCodexAppServerTransport?
    let task: Task<CodexAppServerProcessSnapshot?, Never>
  }

  private struct TurnWorkKey: Hashable, Sendable {
    let threadID: String
    let turnID: String
  }

  private struct ServerRequestWorkKey: Hashable, Sendable {
    let connection: ObjectIdentifier
    let requestID: String
  }

  private struct ServerRequestWork: Sendable {
    let binding: CodexWorkBinding
    let connection: CodexAppServerConnection
    let generation: Int
    let threadID: String?
    let turnID: String?
    var state: CodexWorkResource.State = .active
    var handlerActive = true
    var nativeSettled = false
  }

  private struct NativeReply: Sendable {
    let connection: CodexAppServerConnection
    let value: JSONValue
  }

  struct RequestTimeoutError: Error, LocalizedError, Sendable {
    let seconds: Int

    var errorDescription: String? {
      "Codex App Server request exceeded the \(seconds)-second deadline."
    }
  }

  private let configuration: CodexConfig
  private let workspaceURL: URL
  private let outputBounds: CodexOutputBounds
  private let eventBuffer: CodexEventBuffer
  nonisolated let runtimeID = UUID().uuidString
  private let createdAt = Date()
  nonisolated let owner: CodexRuntimeOwner?
  private let database: CodexDatabase?
  private let dynamicToolDispatcher: (any CodexHostTools)?
  private var connection: CodexAppServerConnection?
  private var processTransport: ManagedCodexAppServerTransport?
  private var connectionStartup: ConnectionStartup?
  private var timedOutConnectionStartupIDs: Set<UUID> = []
  private var requestGenerationRetirement: RequestGenerationRetirement?
  private var lastProcessSnapshot: CodexAppServerProcessSnapshot?
  private var notificationTask: Task<Void, Never>?
  private var requestTask: Task<Void, Never>?
  private var pendingUserInputRequests: [String: PendingUserInputRequest] = [:]
  private var approvalRecords: [String: CodexApprovalRecord] = [:]
  private var pendingApprovalHandles: [String: PendingApprovalHandle] = [:]
  private var approvalTimeoutTasks: [String: Task<Void, Never>] = [:]
  private let threadOwnerIndex: CodexThreadOwnerIndex?
  private var workspaceScopedThreadIDs: Set<String> = []
  private var loadedThreadIDs: Set<String> = []
  private var subscribedThreadIDs: Set<String> = []
  private var threadStates: [String: JSONValue] = [:]
  private var activeTurnIDs: [String: String] = [:]
  private var turnStartInFlight: Set<String> = []
  private var completedTurnsDuringStart: Set<TurnWorkKey> = []
  private var threadStartInFlight = false
  private var threadResumeInFlight: Set<String> = []
  private var handoffPreparations: [String: UUID] = [:]
  private var connectionState = "idle"
  private var connectionID: String?
  private var connectionGeneration = 0
  private var nativeResources = CodexNativeResources()
  private var threadWork: [String: CodexWorkBinding] = [:]
  private var turnWork: [TurnWorkKey: CodexWorkBinding] = [:]
  private var goalWork: [String: CodexWorkBinding] = [:]
  private var goalObservationToken = UUID()
  private var goalMutationInFlight: Set<String> = []
  private var pendingGoalOrigins: [String: CodexWorkOrigin] = [:]
  private var goalNotificationsDuringMutation: Set<String> = []
  private var uncertainGoalWork: Set<String> = []
  private var pendingCallWork: [String: CodexWorkBinding] = [:]
  private var serverRequestWork: [ServerRequestWorkKey: ServerRequestWork] = [:]
  private var cleanupWork: CodexWorkBinding?
  private var unconfirmedTransport: (generation: Int, transport: ManagedCodexAppServerTransport)?
  private var shutdownReason: String?
  private var isShutdown = false
  private var lastError: String?
  private var activeRequestCount = 0
  private var currentRequestState = "idle"
  private var lastRequestFailure: CodexRuntimeRequestFailure?

  init(
    configuration: CodexConfig,
    workspaceURL: URL,
    owner: CodexRuntimeOwner? = nil,
    database: CodexDatabase? = nil,
    dynamicToolDispatcher: (any CodexHostTools)? = nil,
    threadOwnerIndex: CodexThreadOwnerIndex? = nil,
    maxOutputBytes: Int = 1_048_576
  ) {
    self.configuration = configuration
    self.workspaceURL = workspaceURL.standardizedFileURL
    self.owner = owner
    self.database = database
    self.dynamicToolDispatcher = dynamicToolDispatcher
    self.threadOwnerIndex = threadOwnerIndex
    self.outputBounds = CodexOutputBounds(maxOutputBytes: maxOutputBytes)
    self.eventBuffer = CodexEventBuffer(
      capacity: configuration.maxEventsPerSession,
      maxOutputBytes: maxOutputBytes
    )
    for var record in (try? database?.codexApprovals(limit: 5_000)) ?? []
    where Self.isApprovalVisible(record, to: owner) {
      if record.state == .pending, Self.isApprovalOwnerGone(record, database: database) {
        record.state = .interrupted
        record.resolvedAt = Date()
        record.resolutionReason = "The owning runtime is no longer active."
        try? database?.saveCodexApproval(record)
      }
      approvalRecords[record.id] = record
    }
    CodexRuntimeDirectory.shared.register(self, id: runtimeID)
  }

  private static func isApprovalOwnerGone(
    _ record: CodexApprovalRecord, database: CodexDatabase?
  ) -> Bool {
    guard CodexRuntimeDirectory.shared.runtime(id: record.runtimeID) == nil else { return false }
    // The directory is process-local; another adapter can still own the recorded process.
    // Unreadable ownership evidence must not invalidate a pending native request.
    return
      (try? CodexThreadOwnershipReconciliation.hasLiveReceiptedProcess(
        database: database, runtimeID: record.runtimeID)) == false
  }

  func workResources() async throws -> [CodexWorkResource] {
    await recheckProcessCleanup()
    let state: CodexWorkResource.State =
      requestGenerationRetirement != nil || unconfirmedTransport != nil ? .uncertain : .active
    var rows = try nativeResources.workResources()
    for id in loadedThreadIDs.union(subscribedThreadIDs) {
      rows.append(try threadBinding(id).resource("codex.app.thread", state: state))
    }
    for (threadID, turnID) in activeTurnIDs {
      rows.append(
        try turnBinding(threadID: threadID, turnID: turnID).resource("codex.app.turn", state: state)
      )
    }
    rows += try goalWork.map { threadID, work in
      try work.resource(
        "codex.app.goal", state: uncertainGoalWork.contains(threadID) ? .uncertain : state)
    }
    rows += try pendingCallWork.values.map { try $0.resource("codex.app.call") }
    rows += try serverRequestWork.values.map {
      try $0.binding.resource(
        "codex.app.server-request", state: state == .uncertain ? state : $0.state)
    }
    if let startup = connectionStartup {
      rows.append(try startup.work.resource("codex.app.startup"))
    }
    if let retirement = requestGenerationRetirement {
      rows.append(try retirement.work.resource("codex.app.cleanup", state: .uncertain))
    } else if let cleanupWork, unconfirmedTransport != nil {
      rows.append(try cleanupWork.resource("codex.app.cleanup", state: .uncertain))
    }
    return rows.sorted { ($0.kind, $0.id) < ($1.kind, $1.id) }
  }

  private func threadBinding(_ id: String) -> CodexWorkBinding {
    if let binding = threadWork[id] { return binding }
    let binding = CodexWorkBinding()
    threadWork[id] = binding
    return binding
  }

  private func turnBinding(
    threadID: String, turnID: String, origin: CodexWorkOrigin? = nil
  ) -> CodexWorkBinding {
    let key = TurnWorkKey(threadID: threadID, turnID: turnID)
    if let binding = turnWork[key] { return binding }
    let binding = CodexWorkBinding(origin: origin ?? .init())
    turnWork[key] = binding
    return binding
  }

  private func requestOrigin(threadID: String?, turnID: String?) -> CodexWorkOrigin {
    guard let threadID else { return .init() }
    if let turnID {
      let goalOrigin =
        turnStartInFlight.contains(threadID)
        ? nil : (goalWork[threadID]?.origin ?? pendingGoalOrigins[threadID])
      return turnBinding(threadID: threadID, turnID: turnID, origin: goalOrigin).origin
    }
    return threadBinding(threadID).origin
  }

  private func pruneWorkBindings() {
    let liveThreads = loadedThreadIDs.union(subscribedThreadIDs)
    let pendingThreads = Set(serverRequestWork.values.compactMap(\.threadID))
    threadWork = threadWork.filter {
      liveThreads.contains($0.key) || pendingThreads.contains($0.key)
    }
    let pendingTurns = Set(
      serverRequestWork.values.compactMap { request -> TurnWorkKey? in
        guard let threadID = request.threadID, let turnID = request.turnID else { return nil }
        return .init(threadID: threadID, turnID: turnID)
      })
    completedTurnsDuringStart = completedTurnsDuringStart.filter {
      turnStartInFlight.contains($0.threadID)
    }
    turnWork = turnWork.filter {
      activeTurnIDs[$0.key.threadID] == $0.key.turnID
        || turnStartInFlight.contains($0.key.threadID) || pendingTurns.contains($0.key)
    }
  }

  func status() async -> JSONValue {
    await recheckProcessCleanup()
    let processSnapshot =
      await (processTransport ?? connectionStartup?.transport)?.snapshot()
      ?? lastProcessSnapshot
    let pendingApprovals = approvalRecords.values.filter { $0.state == .pending }
    let pendingApprovalIDs = pendingApprovals.map(\.id).sorted().map(JSONValue.string)
    let threads = workspaceScopedThreadIDs.sorted().map { threadID -> JSONValue in
      let threadPendingApprovalIDs = pendingApprovals.filter {
        $0.threadID == threadID
      }.map(\.id).sorted().map(JSONValue.string)
      let threadPendingUserInputIDs = pendingUserInputRequests.filter {
        $0.value.threadID == threadID
      }.map(\.key).sorted().map(JSONValue.string)
      let fields: [String: JSONValue] = [
        "thread_id": .string(threadID),
        "loaded": .bool(loadedThreadIDs.contains(threadID)),
        "subscribed": .bool(subscribedThreadIDs.contains(threadID)),
        "state": threadStates[threadID] ?? .string("unknown"),
        "active_turn_id": activeTurnIDs[threadID].map(JSONValue.string) ?? .null,
        "pending_approval_ids": .array(threadPendingApprovalIDs),
        "pending_user_input_request_ids": .array(threadPendingUserInputIDs),
      ]
      return .object(fields)
    }
    let fields: [String: JSONValue] = [
      "runtime_id": .string(runtimeID),
      "created_at": (try? JSONValue.encoded(createdAt)) ?? .null,
      "owner": owner.flatMap { try? JSONValue.encoded($0) } ?? .null,
      "state": .string(connectionState),
      "runtime_state": .string(
        unconfirmedTransport != nil ? "cleanup-pending" : (isShutdown ? "stopped" : "running")),
      "connection_state": .string(connectionState),
      "process_state": processSnapshot.map { .string($0.state.rawValue) } ?? .string("absent"),
      "current_request_state": .string(currentRequestState),
      "current_request_count": .integer(Int64(activeRequestCount)),
      "last_request_failure": lastRequestFailure?.json ?? .null,
      "connection_id": connectionID.map(JSONValue.string) ?? .null,
      "connection_generation": .integer(Int64(connectionGeneration)),
      "native_resource_count": .integer(Int64(nativeResources.count)),
      "experimental_api": .bool(configuration.experimentalAPI),
      "workspace": .string(workspaceURL.path),
      "last_error": lastError.map(JSONValue.string) ?? .null,
      "shutdown_reason": shutdownReason.map(JSONValue.string) ?? .null,
      "pending_user_input_requests": .integer(Int64(pendingUserInputRequests.count)),
      "pending_approvals": .integer(Int64(pendingApprovals.count)),
      "pending_approval_ids": .array(pendingApprovalIDs),
      "threads": .array(threads),
      "process": processSnapshot?.json ?? .null,
    ]
    return .object(fields)
  }

  func hasLiveOwnership(of threadID: String) -> Bool {
    loadedThreadIDs.contains(threadID)
      || subscribedThreadIDs.contains(threadID)
      || activeTurnIDs[threadID] != nil
      || approvalRecords.values.contains {
        $0.threadID == threadID && $0.state == .pending
      }
      || pendingUserInputRequests.values.contains { $0.threadID == threadID }
      || serverRequestWork.values.contains { $0.threadID == threadID }
  }

  func prepareForHandoff(
    threadID: String,
    mode: CodexThreadHandoffMode,
    interruptActiveTurn: Bool
  ) throws -> UUID {
    guard handoffPreparations[threadID] == nil else {
      throw CodexToolError.disabled(
        "codex.app.handoff_in_progress: A release transaction is already in progress for this thread."
      )
    }
    let preparationID = UUID()
    handoffPreparations[threadID] = preparationID
    do {
      try validateHandoff(
        threadID: threadID,
        mode: mode,
        interruptActiveTurn: interruptActiveTurn
      )
      return preparationID
    } catch {
      handoffPreparations.removeValue(forKey: threadID)
      throw error
    }
  }

  func cancelHandoffPreparation(threadID: String, preparationID: UUID) {
    guard handoffPreparations[threadID] == preparationID else { return }
    handoffPreparations.removeValue(forKey: threadID)
  }

  func releaseForHandoff(
    threadID: String,
    mode: CodexThreadHandoffMode,
    interruptActiveTurn: Bool,
    preparationID: UUID
  ) async throws -> CodexRuntimeThreadReleaseResult {
    guard handoffPreparations[threadID] == preparationID else {
      throw CodexToolError.disabled(
        "codex.app.handoff_preparation_invalid: The release preparation is missing or no longer current."
      )
    }
    defer { handoffPreparations.removeValue(forKey: threadID) }
    if isShutdown {
      return CodexRuntimeThreadReleaseResult(
        runtimeID: runtimeID,
        priorState: .stopped,
        activeTurnHandling: "none",
        pendingRequestHandling: "none",
        subscriptionRelease: "runtime-stopped",
        loadedState: "runtime-stopped",
        runtimeAction: "already-reaped"
      )
    }
    try validateHandoff(
      threadID: threadID,
      mode: mode,
      interruptActiveTurn: interruptActiveTurn
    )
    let activeTurnID = activeTurnIDs[threadID]
    let pendingApprovalIDs = approvalRecords.values.filter {
      $0.threadID == threadID && $0.state == .pending
    }.map(\.id)
    let pendingUserInputIDs = pendingUserInputRequests.filter {
      $0.value.threadID == threadID
    }.map(\.key)
    let priorState: CodexThreadHandoffState =
      activeTurnID != nil ? .active : .idleLoaded

    var activeTurnHandling = "none"
    let pendingRequestHandling = "none"
    var subscriptionRelease = "not-subscribed"
    var loadedState = "not-loaded"

    if mode == .forceComputerMCPOwnedRuntimeOnly {
      try persistThreadOwnership(threadID: threadID, state: .released)
      await shutdown(reason: "handoff_force_owned_runtime")
      return CodexRuntimeThreadReleaseResult(
        runtimeID: runtimeID,
        priorState: priorState,
        activeTurnHandling: activeTurnID == nil ? "none" : "runtime-stopped",
        pendingRequestHandling:
          pendingApprovalIDs.isEmpty && pendingUserInputIDs.isEmpty
          ? "none" : "interrupted-by-owned-runtime-stop",
        subscriptionRelease: "runtime-stopped",
        loadedState: "runtime-stopped",
        runtimeAction: "reaped"
      )
    }

    if let activeTurnID {
      let activeConnection = try await ensureConnection()
      _ = try await Self.boundedRequest(
        timeoutSeconds: min(5, configuration.appServerRequestTimeoutSeconds),
        onTimeout: {},
        operation: {
          try await activeConnection.turnInterrupt(
            try Self.decodeStableParams(
              Stable.TurnInterruptParams.self,
              from: .object([
                "threadId": .string(threadID),
                "turnId": .string(activeTurnID),
              ])
            )
          )
        }
      )
      activeTurnIDs.removeValue(forKey: threadID)
      threadStates[threadID] = .string("idle")
      activeTurnHandling = "interrupted"
    }

    if loadedThreadIDs.contains(threadID) || subscribedThreadIDs.contains(threadID) {
      let activeConnection = try await ensureConnection()
      do {
        _ = try await Self.boundedRequest(
          timeoutSeconds: min(5, configuration.appServerRequestTimeoutSeconds),
          onTimeout: {},
          operation: {
            try await activeConnection.threadUnsubscribe(
              try Self.decodeStableParams(
                Stable.ThreadUnsubscribeParams.self,
                from: .object(["threadId": .string(threadID)])
              )
            )
          }
        )
        subscriptionRelease = "unsubscribed"
      } catch  where Self.isThreadNotLoaded(error) {
        subscriptionRelease = "already-unsubscribed"
      }

      let response = try await Self.boundedRequest(
        timeoutSeconds: min(5, configuration.appServerRequestTimeoutSeconds),
        onTimeout: {},
        operation: {
          try await Self.sendReviewedRequest(
            method: "thread/loaded/list",
            params: .object([:]),
            connection: activeConnection
          )
        }
      )
      let officialLoaded = Set(
        response.objectValue?["data"]?.arrayValue?.compactMap(\.stringValue) ?? []
      )
      let removed = loadedThreadIDs.union(subscribedThreadIDs).subtracting(officialLoaded)
      for id in removed { threadWork.removeValue(forKey: id) }
      loadedThreadIDs = officialLoaded
      subscribedThreadIDs.formIntersection(officialLoaded)
      loadedState = officialLoaded.contains(threadID) ? "still-loaded" : "not-loaded"
    }

    if loadedState == "still-loaded" {
      if isEligibleForIdleReaping(ignoring: threadID) {
        try persistThreadOwnership(threadID: threadID, state: .released)
        await shutdown(reason: "handoff_empty_runtime")
        return CodexRuntimeThreadReleaseResult(
          runtimeID: runtimeID,
          priorState: priorState,
          activeTurnHandling: activeTurnHandling,
          pendingRequestHandling: pendingRequestHandling,
          subscriptionRelease: subscriptionRelease,
          loadedState: "runtime-stopped",
          runtimeAction: "reaped"
        )
      }
      throw CodexToolError.executionFailed(
        "codex.app.handoff_still_loaded: \(CodexThreadHandoffError.stillLoaded(runtimeID: runtimeID).localizedDescription)"
      )
    }

    loadedThreadIDs.remove(threadID)
    subscribedThreadIDs.remove(threadID)
    activeTurnIDs.removeValue(forKey: threadID)
    threadStates[threadID] = .string("released")
    threadWork.removeValue(forKey: threadID)
    try persistThreadOwnership(threadID: threadID, state: .released)

    if isEligibleForIdleReaping(ignoring: threadID) {
      await shutdown(reason: "handoff_empty_runtime")
      return CodexRuntimeThreadReleaseResult(
        runtimeID: runtimeID,
        priorState: priorState,
        activeTurnHandling: activeTurnHandling,
        pendingRequestHandling: pendingRequestHandling,
        subscriptionRelease: subscriptionRelease,
        loadedState: loadedState,
        runtimeAction: "reaped"
      )
    }

    return CodexRuntimeThreadReleaseResult(
      runtimeID: runtimeID,
      priorState: priorState,
      activeTurnHandling: activeTurnHandling,
      pendingRequestHandling: pendingRequestHandling,
      subscriptionRelease: subscriptionRelease,
      loadedState: loadedState,
      runtimeAction: "preserved-for-other-work"
    )
  }

  private func isEligibleForIdleReaping(ignoring threadID: String) -> Bool {
    let otherLoaded = loadedThreadIDs.subtracting([threadID])
    let otherSubscribed = subscribedThreadIDs.subtracting([threadID])
    let otherActive = activeTurnIDs.keys.contains { $0 != threadID }
    let otherPendingApprovals = approvalRecords.values.contains {
      $0.state == .pending && $0.threadID != threadID
    }
    let otherPendingInput = pendingUserInputRequests.values.contains {
      $0.threadID != threadID
    }
    let otherHandoffs = handoffPreparations.keys.contains { $0 != threadID }
    return otherLoaded.isEmpty && otherSubscribed.isEmpty && !otherActive
      && !otherPendingApprovals && !otherPendingInput && !otherHandoffs
  }

  func call(method: String, params: JSONValue?) async throws -> JSONValue {
    try CodexAppServerMethodCatalog.validate()
    guard let descriptor = CodexAppServerMethodCatalog.method(named: method) else {
      throw CodexToolError.disabled(
        "codex.app.method_not_allowed: App Server method '\(method)' is not adopted by the SDK."
      )
    }
    guard descriptor.channel != .experimental || configuration.experimentalAPI else {
      throw CodexToolError.disabled(
        "Experimental App Server requests are disabled in this runtime.")
    }
    let normalized = try normalize(params: params, for: descriptor)
    try descriptor.validate(params: normalized)
    if let threadID = try Self.workspaceScopedThreadID(method: method, params: normalized) {
      try threadOwnerIndex?.check(threadID: threadID)
      if descriptor.risk != .readOnly, method != "thread/fork" {
        try threadOwnerIndex?.claim(threadID: threadID)
      }
    }
    if let beforeThreadID = normalized?.objectValue?["beforeThreadId"]?.stringValue,
      descriptor.threadParameters["beforeThreadId"] != nil
    {
      try threadOwnerIndex?.check(threadID: Self.validatedThreadID(beforeThreadID))
    }
    let targetThreadID = normalized?.objectValue?["threadId"]?.stringValue
    let previouslyOwnedThreads = loadedThreadIDs.union(subscribedThreadIDs)
    let resumeThreadID = method == "thread/resume" ? targetThreadID : nil
    if let resumeThreadID {
      guard threadResumeInFlight.insert(resumeThreadID).inserted else {
        throw CodexToolError.disabled(
          "codex.app.thread_resume_in_flight: This thread is already being resumed.")
      }
    }
    defer { if let resumeThreadID { threadResumeInFlight.remove(resumeThreadID) } }
    let queriedGoalWorkID = targetThreadID.flatMap { goalWork[$0]?.id }
    let queriedGoalObservation = goalObservationToken
    let goalMutationThreadID =
      ["thread/goal/set", "thread/goal/clear"].contains(method) ? targetThreadID : nil
    if let goalMutationThreadID {
      guard goalMutationInFlight.insert(goalMutationThreadID).inserted else {
        throw CodexToolError.disabled(
          "codex.app.goal_request_in_flight: Another Goal mutation is still settling for this thread."
        )
      }
    }
    defer {
      if let goalMutationThreadID {
        goalMutationInFlight.remove(goalMutationThreadID)
        goalNotificationsDuringMutation.remove(goalMutationThreadID)
        pendingGoalOrigins.removeValue(forKey: goalMutationThreadID)
      }
    }
    let turnStartThreadID =
      method == "turn/start" ? normalized?.objectValue?["threadId"]?.stringValue : nil
    let turnStartPriorState = turnStartThreadID.flatMap { threadStates[$0] }
    let turnStartPriorActiveTurnID = turnStartThreadID.flatMap { activeTurnIDs[$0] }
    if method == "thread/start", !handoffPreparations.isEmpty {
      throw CodexToolError.disabled(
        "codex.app.handoff_in_progress: A thread release transaction is in progress on this runtime."
      )
    }
    if let targetThreadID = normalized?.objectValue?["threadId"]?.stringValue,
      handoffPreparations[targetThreadID] != nil
    {
      throw CodexToolError.disabled(
        "codex.app.handoff_in_progress: The target thread is being released for handoff."
      )
    }
    if let turnStartThreadID {
      guard turnStartInFlight.insert(turnStartThreadID).inserted else {
        throw CodexToolError.disabled(
          "codex.app.turn_start_in_flight: Another turn/start is already being committed for this thread."
        )
      }
      threadStates[turnStartThreadID] = .string("starting")
      activeTurnIDs.removeValue(forKey: turnStartThreadID)
    }
    if method == "thread/start" {
      guard !threadStartInFlight else {
        throw CodexToolError.disabled(
          "codex.app.thread_start_in_flight: Another thread/start is already being committed by this runtime."
        )
      }
      threadStartInFlight = true
    }
    defer {
      if let turnStartThreadID {
        turnStartInFlight.remove(turnStartThreadID)
      }
      if method == "thread/start" {
        threadStartInFlight = false
      }
      pruneWorkBindings()
    }
    let normalizedRequest = normalized
    let creator = CodexWorkInvocation.current
    let work = CodexWorkBinding(origin: .init(invocation: creator))
    if method == "thread/goal/set", let targetThreadID {
      pendingGoalOrigins[targetThreadID] = goalWork[targetThreadID]?.origin ?? work.origin
    }
    pendingCallWork[work.id] = work
    activeRequestCount += 1
    currentRequestState = "running"
    defer {
      pendingCallWork.removeValue(forKey: work.id)
      activeRequestCount = max(0, activeRequestCount - 1)
      currentRequestState = activeRequestCount == 0 ? "idle" : "running"
      persistRuntimeLease(state: connectionState, reason: nil)
    }
    let reply: NativeReply
    do {
      let totalTimeoutSeconds = Self.requestTimeoutSeconds(
        method: method,
        configuredTimeoutSeconds: configuration.appServerRequestTimeoutSeconds,
        appListTimeoutSeconds: configuration.appServerAppListTimeoutSeconds
      )
      let firstAttemptTimeoutSeconds = Self.firstReadOnlyAttemptTimeoutSeconds(
        totalTimeoutSeconds: totalTimeoutSeconds,
        risk: descriptor.risk,
        method: method
      )
      reply = try await Self.boundedRequest(
        timeoutSeconds: totalTimeoutSeconds,
        onTimeout: {
          await self.retireCurrentRequestGeneration(method: method)
        },
        operation: {
          try await Self.withRequestRetry(risk: descriptor.risk) { attempt in
            let runAttempt: @Sendable () async throws -> NativeReply = {
              let connection = try await self.ensureConnection()
              try await self.validateWorkspaceScope(
                method: method,
                params: normalizedRequest,
                connection: connection
              )
              return try await self.sendNativeRequest(
                method: method,
                params: normalizedRequest,
                connection: connection
              )
            }
            guard attempt == 0, let firstAttemptTimeoutSeconds else {
              return try await runAttempt()
            }
            return try await Self.boundedRequest(
              timeoutSeconds: firstAttemptTimeoutSeconds,
              onTimeout: {
                await self.retireCurrentRequestGeneration(method: method)
              },
              operation: runAttempt
            )
          }
        }
      )
    } catch {
      restoreTurnStartState(
        threadID: turnStartThreadID,
        priorState: turnStartPriorState,
        priorActiveTurnID: turnStartPriorActiveTurnID
      )
      if error is CancellationError {
        await retireCurrentRequestGeneration(method: method)
        throw CancellationError()
      }
      if !(error is RequestTimeoutError) {
        recordRequestFailure(
          kind: "request_failed",
          message: Self.errorDescription(error)
        )
      }
      throw CodexToolError.executionFailed(
        "codex.app.request_failed: \(Self.errorDescription(error))"
      )
    }
    guard connection === reply.connection else {
      throw CodexToolError.executionFailed(
        "codex.app.connection_retired: The response belongs to a retired connection.")
    }
    let response = reply.value
    if let threadID = turnStartThreadID,
      let turnID = Self.safeStoredIdentifier(
        response.objectValue?["turn"]?.objectValue?["id"]?.stringValue)
    {
      turnBinding(threadID: threadID, turnID: turnID).origin.bind(to: creator)
    }
    if let turnStartThreadID,
      threadStates[turnStartThreadID] == .string("starting"),
      let turnID = Self.safeStoredIdentifier(
        response.objectValue?["turn"]?.objectValue?["id"]?.stringValue
      )
    {
      let responseStatus = response.objectValue?["turn"]?.objectValue?["status"]?.stringValue
      if completedTurnsDuringStart.contains(.init(threadID: turnStartThreadID, turnID: turnID))
        || responseStatus.map({ ["completed", "failed", "interrupted"].contains($0) }) == true
      {
        activeTurnIDs.removeValue(forKey: turnStartThreadID)
        threadStates[turnStartThreadID] = .string("idle")
      } else {
        activeTurnIDs[turnStartThreadID] = turnID
        threadStates[turnStartThreadID] = .string("active")
      }
    }
    let visibleResponse = try threadOwnerIndex?.filtered(response, method: method) ?? response
    try rememberWorkspaceScopedThreads(
      method: method,
      params: normalizedRequest,
      response: visibleResponse, creator: creator, previouslyOwnedThreads: previouslyOwnedThreads
    )
    if method == "thread/goal/set",
      let threadID = normalizedRequest?.objectValue?["threadId"]?.stringValue
    {
      goalObservationToken = UUID()
      if response.objectValue?["goal"]?.objectValue?["status"] == .string("active") {
        if goalWork[threadID] == nil { goalWork[threadID] = .init(origin: work.origin) }
        if queriedGoalWorkID == nil { goalWork[threadID]?.origin.bind(to: creator) }
        if goalNotificationsDuringMutation.contains(threadID) { uncertainGoalWork.insert(threadID) }
      } else {
        finishGoalMutation(threadID: threadID)
      }
    } else if method == "thread/goal/clear",
      let threadID = normalizedRequest?.objectValue?["threadId"]?.stringValue,
      response.objectValue?["cleared"] == .bool(true)
    {
      goalObservationToken = UUID()
      finishGoalMutation(threadID: threadID)
    } else if method == "thread/goal/get", let threadID = targetThreadID,
      let queriedGoalWorkID, goalWork[threadID]?.id == queriedGoalWorkID,
      queriedGoalObservation == goalObservationToken, !goalMutationInFlight.contains(threadID)
    {
      if response.objectValue?["goal"]?.objectValue?["status"] != .string("active") {
        goalWork.removeValue(forKey: threadID)
      }
      uncertainGoalWork.remove(threadID)
    }
    if method == "thread/turns/list" || method == "thread/items/list" {
      // A truncated page loses both records and its continuation. The caller
      // keeps its input cursor and can retry a smaller page without skipping data.
      guard try JSONEncoder().encode(visibleResponse).count <= outputBounds.maxStructuredBytes
      else {
        throw CodexToolError.executionFailed(
          "codex.app.history_page_too_large: Retry the same cursor with a smaller limit or itemsView=notLoaded for turns. If a single item exceeds the output budget, use codex.app.thread.recent for an explicitly bounded summary."
        )
      }
      return visibleResponse
    }
    return outputBounds.json(visibleResponse)
  }

  private func finishGoalMutation(threadID: String) {
    // Notification and RPC consumers can interleave; a contradictory active
    // notification needs a subsequent read before the owner can be released.
    if goalNotificationsDuringMutation.contains(threadID), goalWork[threadID] != nil {
      uncertainGoalWork.insert(threadID)
    } else {
      goalWork.removeValue(forKey: threadID)
      uncertainGoalWork.remove(threadID)
    }
  }

  private func validateHandoff(
    threadID: String,
    mode: CodexThreadHandoffMode,
    interruptActiveTurn: Bool
  ) throws {
    if let activeTurnID = activeTurnIDs[threadID], !interruptActiveTurn {
      throw CodexToolError.disabled(
        "codex.app.handoff_active_turn: \(CodexThreadHandoffError.activeTurn(runtimeID: runtimeID, turnID: activeTurnID).localizedDescription)"
      )
    }
    guard mode == .graceful else { return }
    let approvals = approvalRecords.values.filter {
      $0.threadID == threadID && $0.state == .pending
    }.count
    let userInput = pendingUserInputRequests.values.filter {
      $0.threadID == threadID
    }.count
    guard approvals == 0, userInput == 0 else {
      throw CodexToolError.disabled(
        "codex.app.handoff_pending_lifecycle: \(CodexThreadHandoffError.pendingLifecycle(runtimeID: runtimeID, approvals: approvals, userInput: userInput).localizedDescription)"
      )
    }
  }

  private func restoreTurnStartState(
    threadID: String?,
    priorState: JSONValue?,
    priorActiveTurnID: String?
  ) {
    guard let threadID, threadStates[threadID] == .string("starting") else { return }
    if let priorState {
      threadStates[threadID] = priorState
    } else {
      threadStates.removeValue(forKey: threadID)
    }
    if let priorActiveTurnID {
      activeTurnIDs[threadID] = priorActiveTurnID
    } else {
      activeTurnIDs.removeValue(forKey: threadID)
    }
  }

  static func withRequestRetry<Value: Sendable>(
    risk: CodexOperationRisk,
    operation: @escaping @Sendable (_ attempt: Int) async throws -> Value
  ) async throws -> Value {
    let maximumAttempts = risk == .readOnly ? 2 : 1
    var attempt = 0
    while true {
      do {
        try Task.checkCancellation()
        return try await operation(attempt)
      } catch {
        try Task.checkCancellation()
        guard
          shouldRetryRequest(
            error,
            risk: risk,
            attempt: attempt,
            maximumAttempts: maximumAttempts
          )
        else {
          throw error
        }
        attempt += 1
      }
    }
  }

  static func shouldRetryRequest(
    _ error: any Error,
    risk: CodexOperationRisk,
    attempt: Int,
    maximumAttempts: Int
  ) -> Bool {
    risk == .readOnly
      && error is RequestTimeoutError
      && attempt + 1 < maximumAttempts
  }

  static func firstReadOnlyAttemptTimeoutSeconds(
    totalTimeoutSeconds: Int,
    risk: CodexOperationRisk,
    method: String? = nil
  ) -> Int? {
    guard risk == .readOnly, totalTimeoutSeconds > 1, method != "app/list" else {
      return nil
    }
    return max(1, totalTimeoutSeconds / 2)
  }

  static func requestTimeoutSeconds(
    method: String,
    configuredTimeoutSeconds: Int,
    appListTimeoutSeconds: Int
  ) -> Int {
    guard method == "app/list" else {
      return configuredTimeoutSeconds
    }
    // Codex can emit a multi-megabyte app/list/updated snapshot before the
    // bounded page response. Restarting midway repeats that snapshot, so this
    // read uses one dedicated generation instead of the normal split retry.
    return appListTimeoutSeconds
  }

  func events(afterCursor: Int, maxResults: Int) async -> JSONValue {
    await eventBuffer.read(afterCursor: afterCursor, maxResults: maxResults)
  }

  func pendingRequests() async -> JSONValue {
    let requests =
      pendingUserInputRequests
      .sorted { $0.key < $1.key }
      .map { id, request -> JSONValue in
        return .object([
          "request_id": .string(id),
          "request": request.payload,
          "kind": .string(request.kind),
        ])
      }
    return outputBounds.json(.object(["requests": .array(requests)]))
  }

  func respond(requestID: String, response: JSONValue) async throws -> JSONValue {
    guard let request = pendingUserInputRequests.removeValue(forKey: requestID) else {
      throw CodexToolError.invalidArguments(
        "codex.app.request_unknown: Unknown or already resolved App Server request '\(requestID)'."
      )
    }
    let connection = request.connection
    do {
      guard self.connection === connection, !isShutdown else {
        throw CodexToolError.disabled(
          "codex.app.request_retired: The request's connection has retired.")
      }
      switch request.handle.method {
      case "item/tool/requestUserInput": _ = try Self.decodeUserInputResponse(response)
      case "mcpServer/elicitation/request": _ = try Self.decodeElicitationResponse(response)
      default: throw CodexToolError.invalidArguments("Unsupported interactive request.")
      }
      try await resolveOwnedServerRequest(request.handle, connection: connection, with: response)
    } catch {
      if self.connection === connection, !isShutdown {
        pendingUserInputRequests[requestID] = request
      }
      throw error
    }
    await eventBuffer.append(
      kind: "server_request_resolved",
      payload: .object(["request_id": .string(requestID)])
    )
    return .object(["resolved": .bool(true), "request_id": .string(requestID)])
  }

  func approvals(state: String?, limit: Int) async throws -> JSONValue {
    try await reconcileApprovalRecords()
    let requestedState: CodexApprovalState?
    if let state {
      guard let parsed = CodexApprovalState(rawValue: state) else {
        throw CodexToolError.invalidArguments(
          "codex.app.approval_state_invalid: Unknown approval state '\(state)'."
        )
      }
      requestedState = parsed
    } else {
      requestedState = nil
    }
    let records = approvalRecords.values
      .filter { requestedState == nil || $0.state == requestedState }
      .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
      .prefix(max(1, min(limit, 1_000)))
      .map(\.json)
    return outputBounds.json(.object(["approvals": .array(records)]))
  }

  func approval(id: String) async throws -> JSONValue {
    try await reconcileApprovalRecords()
    let storedRecord: CodexApprovalRecord?
    if let cached = approvalRecords[id] {
      storedRecord = cached
    } else {
      storedRecord = try database?.codexApproval(id: id)
    }
    guard let record = storedRecord, Self.isApprovalVisible(record, to: owner) else {
      throw CodexToolError.invalidArguments(
        "codex.app.approval_unknown: Unknown Codex approval '\(id)'."
      )
    }
    return outputBounds.json(.object(["approval": record.json]))
  }

  func respondToApproval(id: String, response: JSONValue) async throws -> JSONValue {
    do {
      try await reconcileApprovalRecords()
      let storedRecord: CodexApprovalRecord?
      if let cached = approvalRecords[id] {
        storedRecord = cached
      } else {
        storedRecord = try database?.codexApproval(id: id)
      }
      guard let storedRecord, Self.isApprovalVisible(storedRecord, to: owner) else {
        throw CodexApprovalBrokerError.unknown(id)
      }
      if storedRecord.runtimeID != runtimeID,
        let owningRuntime = CodexRuntimeDirectory.shared.runtime(id: storedRecord.runtimeID)
      {
        return try await owningRuntime.respondToApproval(id: id, response: response)
      }
      let resolvedRecord = try await resolveApproval(id: id, response: response)
      return .object(["approval": resolvedRecord.json])
    } catch let error as CodexApprovalBrokerError {
      throw CodexToolError.invalidArguments(
        "codex.app.approval_response_invalid: \(Self.errorDescription(error))"
      )
    }
  }

  func shutdown() async {
    await shutdown(reason: "requested")
  }

  private func shutdown(reason: String) async {
    if isShutdown {
      await recheckProcessCleanup()
      return
    }
    isShutdown = true
    let retiredGeneration = connectionGeneration
    shutdownReason = reason
    if let requestGenerationRetirement {
      await finishRequestGenerationRetirement(requestGenerationRetirement)
      shutdownReason = reason
    }
    notificationTask?.cancel()
    requestTask?.cancel()
    notificationTask = nil
    requestTask = nil
    let activeConnection = connection
    let activeTransport = processTransport
    let startup = connectionStartup
    if let activeConnection {
      await releaseAllThreads(connection: activeConnection)
      await interruptPendingApprovals(connection: activeConnection, reason: "Runtime stopped.")
    }
    connection = nil
    connectionID = nil
    processTransport = nil
    connectionStartup = nil
    pendingUserInputRequests.removeAll()
    for task in approvalTimeoutTasks.values {
      task.cancel()
    }
    approvalTimeoutTasks.removeAll()
    pendingApprovalHandles.removeAll()
    connectionState = "stopped"
    lastError = nil
    startup?.task.cancel()
    await startup?.transport.close()
    await activeConnection?.close()
    await activeTransport?.close()
    if let startup {
      lastProcessSnapshot = await startup.transport.snapshot()
    } else if let activeTransport {
      lastProcessSnapshot = await activeTransport.snapshot()
    }
    if lastProcessSnapshot?.cleanupConfirmed == true {
      releaseConfirmedGeneration(retiredGeneration)
    } else if let transport = startup?.transport ?? activeTransport {
      unconfirmedTransport = (retiredGeneration, transport)
      cleanupWork = startup?.work ?? .init(origin: .init(invocation: CodexWorkInvocation.current))
    }
    persistRuntimeLease(state: "stopped", reason: shutdownReason)
    unregisterIfDrained()
    _ = try? CodexThreadOwnershipReconciliation.reconcileSafely(
      database: database,
      workspaceID: owner?.workspaceID,
      runtimeID: runtimeID
    )
  }

  private func ensureConnection() async throws -> CodexAppServerConnection {
    guard !isShutdown else {
      throw CodexToolError.disabled(
        "codex.app.runtime_stopped: Runtime '\(runtimeID)' has been stopped. Create a new gateway session to start a new generation."
      )
    }
    if let requestGenerationRetirement {
      await finishRequestGenerationRetirement(requestGenerationRetirement)
      try Task.checkCancellation()
      guard !isShutdown else {
        throw CodexToolError.disabled(
          "codex.app.runtime_stopped: Runtime '\(runtimeID)' has been stopped. Create a new gateway session to start a new generation."
        )
      }
    }
    if let connection {
      return connection
    }
    await recheckProcessCleanup()
    guard unconfirmedTransport == nil, lastProcessSnapshot?.cleanupConfirmed != false else {
      throw CodexToolError.disabled(
        "codex.app.cleanup_unconfirmed: The previous owned process group has not been confirmed gone."
      )
    }
    connectionState = "starting"
    shutdownReason = nil
    lastError = nil
    let startup: ConnectionStartup
    if let connectionStartup {
      startup = connectionStartup
    } else {
      let environment = CodexProcessEnvironment.resolved()
      let transport: ManagedCodexAppServerTransport
      do {
        transport = try ManagedCodexAppServerTransport(
          configuration: .init(
            executable: try configuration.resolvedExecutableURL(
              workspaceURL: workspaceURL, environment: environment
            ).path,
            environment: environment,
            workingDirectory: workspaceURL,
            terminationGraceMilliseconds: configuration.appServerTerminationGraceMilliseconds,
            killGraceMilliseconds: configuration.appServerKillGraceMilliseconds
          )
        )
      } catch {
        throw await connectionStartupFailed(error)
      }
      let client = CodexAppServerClient(
        sessionConfiguration: .init(
          clientInfo: .init(
            name: "codex_mcp_adapter",
            title: "Codex MCP Adapter",
            version: CodexAdapterBuildInfo.version
          ),
          experimentalApi: configuration.experimentalAPI,
          optOutNotificationMethods: [
            "remoteControl/status/changed"
          ],
          inboundMessageMode: .raw
        ),
        transportFactory: { transport }
      )
      let task = Task {
        let connection = try await client.start()
        if Task.isCancelled {
          throw CancellationError()
        }
        return connection
      }
      startup = .init(
        id: UUID(), work: .init(origin: .init(invocation: CodexWorkInvocation.current)),
        transport: transport, task: task)
      connectionStartup = startup
    }
    do {
      let started = try await startup.task.value
      if let connection {
        return connection
      }
      guard connectionStartup?.id == startup.id else {
        await started.close()
        throw CancellationError()
      }
      connectionStartup = nil
      connection = started
      processTransport = startup.transport
      connectionGeneration += 1
      connectionID = UUID().uuidString
      connectionState = "running"
      shutdownReason = nil
      let processSnapshot = await startup.transport.snapshot()
      lastProcessSnapshot = processSnapshot
      persistRuntimeLease(state: "running", process: processSnapshot)
      startConsumers(connection: started)
      await eventBuffer.append(
        kind: "connection_started",
        payload: .object([
          "experimental_api": .bool(configuration.experimentalAPI),
          "runtime_id": .string(runtimeID),
          "connection_id": connectionID.map(JSONValue.string) ?? .null,
          "connection_generation": .integer(Int64(connectionGeneration)),
          "process": processSnapshot.json,
        ])
      )
      return started
    } catch {
      let reachedRequestDeadline = timedOutConnectionStartupIDs.remove(startup.id) != nil
      if connectionStartup?.id == startup.id {
        connectionStartup = nil
      }
      await startup.transport.close()
      let startupProcessSnapshot = await startup.transport.snapshot()
      if reachedRequestDeadline {
        persistRuntimeLease(
          state: "failed",
          process: startupProcessSnapshot,
          reason: "request_timeout"
        )
        throw RequestTimeoutError(seconds: configuration.appServerRequestTimeoutSeconds)
      }
      lastProcessSnapshot = startupProcessSnapshot
      if startupProcessSnapshot.cleanupConfirmed != true {
        unconfirmedTransport = (connectionGeneration, startup.transport)
        cleanupWork = startup.work
      }
      throw await connectionStartupFailed(error)
    }
  }

  private func connectionStartupFailed(_ error: any Error) async -> CodexToolError {
    connectionState = "failed"
    let message = Self.errorDescription(error)
    lastError = message
    persistRuntimeLease(
      state: "failed", process: lastProcessSnapshot, reason: "connection_start_failed")
    await eventBuffer.append(
      kind: "connection_failed", payload: .object(["message": .string(message)]))
    return .executionFailed("codex.app.start_failed: \(message)")
  }

  private func startConsumers(connection: CodexAppServerConnection) {
    CodexWorkInvocation.$current.withValue(nil) {
      startUnboundConsumers(connection: connection)
    }
  }

  private func startUnboundConsumers(connection: CodexAppServerConnection) {
    notificationTask?.cancel()
    requestTask?.cancel()
    notificationTask = Task { [weak self, connection] in
      do {
        for try await notification in connection.rawNotifications {
          guard let self else { return }
          await self.recordNotification(notification, connection: connection)
        }
        await self?.connectionEnded(connection, message: nil)
      } catch {
        await self?.connectionEnded(connection, message: Self.errorDescription(error))
      }
    }
    requestTask = Task { [weak self, connection] in
      do {
        for try await request in connection.rawServerRequests {
          guard let self else { return }
          await self.handleServerRequest(request, connection: connection)
        }
      } catch {
        await self?.recordConsumerFailure(
          kind: "server_request_stream_failed",
          message: error.localizedDescription
        )
      }
    }
  }

  private func recordNotification(
    _ notification: CodexAppServerRawNotification, connection: CodexAppServerConnection
  ) async {
    guard self.connection === connection else { return }
    let rawParams = (try? Self.gatewayJSON(notification.payload))?.objectValue?["params"]?
      .objectValue
    if notification.method == "process/exited",
      let handle = rawParams?["processHandle"]?.stringValue
    {
      nativeResources.processExited(handle: handle, generation: connectionGeneration)
    }
    let payload = CodexApprovalRedactor.redact(
      (try? Self.gatewayJSON(notification.payload)) ?? .null)
    let params = payload.objectValue?["params"]?.objectValue ?? [:]
    let thread = params["thread"]?.objectValue
    let rawThreadID = params["threadId"]?.stringValue ?? thread?["id"]?.stringValue
    if let rawThreadID, let threadID = try? Self.validatedThreadID(rawThreadID) {
      if let threadOwnerIndex, (try? threadOwnerIndex.isVisible(threadID: threadID)) != true {
        return
      }
      switch notification.method {
      case "thread/started":
        workspaceScopedThreadIDs.insert(threadID)
        loadedThreadIDs.insert(threadID)
        subscribedThreadIDs.insert(threadID)
        _ = threadBinding(threadID)
      case "thread/status/changed":
        threadStates[threadID] = params["status"] ?? .string("unknown")
      case "thread/closed":
        loadedThreadIDs.remove(threadID)
        subscribedThreadIDs.remove(threadID)
        activeTurnIDs.removeValue(forKey: threadID)
        threadStates[threadID] = .string("closed")
        threadWork.removeValue(forKey: threadID)
      case "turn/started":
        if let turnID = Self.safeStoredIdentifier(params["turn"]?.objectValue?["id"]?.stringValue) {
          activeTurnIDs[threadID] = turnID
          _ = requestOrigin(threadID: threadID, turnID: turnID)
          threadStates[threadID] = .string("active")
        }
      case "turn/completed":
        if let turnID = params["turn"]?.objectValue?["id"]?.stringValue {
          if turnStartInFlight.contains(threadID) {
            completedTurnsDuringStart.insert(.init(threadID: threadID, turnID: turnID))
          }
          if activeTurnIDs[threadID] == turnID {
            activeTurnIDs.removeValue(forKey: threadID)
            threadStates[threadID] = .string("idle")
          }
        }
      case "thread/goal/updated":
        goalObservationToken = UUID()
        if goalMutationInFlight.contains(threadID) {
          goalNotificationsDuringMutation.insert(threadID)
        } else {
          uncertainGoalWork.remove(threadID)
        }
        if params["goal"]?.objectValue?["status"] == .string("active") {
          if goalWork[threadID] == nil {
            goalWork[threadID] = .init(origin: pendingGoalOrigins[threadID] ?? .init())
          }
        } else {
          goalWork.removeValue(forKey: threadID)
        }
      case "thread/goal/cleared":
        goalObservationToken = UUID()
        if goalMutationInFlight.contains(threadID) {
          goalNotificationsDuringMutation.insert(threadID)
        }
        goalWork.removeValue(forKey: threadID)
        uncertainGoalWork.remove(threadID)
      default: break
      }
      if !turnStartInFlight.contains(threadID) { pruneWorkBindings() }
    }
    await eventBuffer.append(kind: "notification", payload: payload)
  }

  private func handleServerRequest(
    _ request: CodexAppServerRawServerRequest, connection: CodexAppServerConnection
  ) async {
    guard self.connection === connection else {
      await rejectServerRequest(request, method: request.method, connection: connection)
      return
    }
    let id = Self.requestIDString(request.id)
    let params = (try? Self.gatewayJSON(request.params)) ?? .null
    let threadID = Self.serverRequestThreadID(params)
    let turnID = Self.safeStoredIdentifier(params.objectValue?["turnId"]?.stringValue)
    let workKey = ServerRequestWorkKey(connection: ObjectIdentifier(connection), requestID: id)
    serverRequestWork[workKey] = .init(
      binding: .init(origin: requestOrigin(threadID: threadID, turnID: turnID)),
      connection: connection, generation: connectionGeneration,
      threadID: threadID, turnID: turnID)
    let workID = serverRequestWork[workKey]?.binding.id
    defer { finishServerRequestHandler(id: workKey, workID: workID) }
    let payload = CodexApprovalRedactor.redact((try? Self.gatewayJSON(request.payload)) ?? .null)
    if let threadID = Self.serverRequestThreadID(params), let threadOwnerIndex,
      (try? threadOwnerIndex.isVisible(threadID: threadID)) != true
    {
      await rejectServerRequest(request, method: request.method, connection: connection)
      return
    }
    switch request.method {
    case "item/tool/requestUserInput", "mcpServer/elicitation/request":
      pendingUserInputRequests[id] = .init(
        handle: request, connection: connection, payload: payload,
        threadID: Self.serverRequestThreadID(params))
      await eventBuffer.append(
        kind: "user_input_requested",
        payload: .object(["request_id": .string(id), "request": payload]))
    case "item/commandExecution/requestApproval":
      await enqueueApproval(handle: request, kind: .commandExecution, connection: connection)
    case "item/fileChange/requestApproval":
      await enqueueApproval(handle: request, kind: .fileChange, connection: connection)
    case "item/permissions/requestApproval":
      await enqueueApproval(handle: request, kind: .permissions, connection: connection)
    case "applyPatchApproval":
      await enqueueApproval(handle: request, kind: .applyPatch, connection: connection)
    case "execCommandApproval":
      await enqueueApproval(handle: request, kind: .execCommand, connection: connection)
    case "item/tool/call":
      await handleDynamicToolCall(request, connection: connection)
    default:
      await rejectServerRequest(request, method: request.method, connection: connection)
    }
  }

  private func enqueueApproval(
    handle: PendingApprovalHandle,
    kind: CodexApprovalKind,
    connection: CodexAppServerConnection
  ) async {
    let upstreamRequestID = Self.requestIDString(handle.id)
    let rawDetails = (try? Self.gatewayJSON(handle.params)) ?? .object([:])
    let method = handle.method
    let details = CodexApprovalRedactor.redact(rawDetails)
    let object = rawDetails.objectValue ?? [:]
    let rawThreadID = object["threadId"]?.stringValue ?? object["conversationId"]?.stringValue
    let rawTurnID = object["turnId"]?.stringValue
    let rawItemID = object["itemId"]?.stringValue ?? object["callId"]?.stringValue
    let rawCorrelationID = object["callId"]?.stringValue
    let threadID = rawThreadID.flatMap { try? Self.validatedThreadID($0) }
    let turnID = Self.safeStoredIdentifier(rawTurnID)
    let itemID = Self.safeStoredIdentifier(rawItemID)
    let correlationID = Self.safeStoredIdentifier(rawCorrelationID) ?? UUID().uuidString
    let createdAt = Date()
    let id = UUID().uuidString
    let record = CodexApprovalRecord(
      id: id,
      upstreamRequestID: upstreamRequestID,
      kind: kind,
      risk: Self.approvalRisk(kind: kind, details: rawDetails),
      state: .pending,
      workspaceID: owner?.workspaceID,
      workspacePath: workspaceURL.path,
      runtimeID: runtimeID,
      threadID: threadID,
      turnID: turnID,
      itemID: itemID,
      correlationID: correlationID,
      socketConnectionID: owner?.socketConnectionID,
      tunnelInstanceID: owner?.tunnelInstanceID,
      details: details,
      proposedAction: .object(
        [
          "kind": .string(kind.rawValue),
          "method": .string(method),
        ].merging(
          object["tool"].map { ["tool": $0] } ?? [:],
          uniquingKeysWith: { current, _ in current }
        )
      ),
      createdAt: createdAt,
      expiresAt: createdAt.addingTimeInterval(
        TimeInterval(configuration.appServerApprovalTimeoutSeconds)
      ),
      resolvedAt: nil,
      decision: nil,
      scope: nil,
      resolutionReason: nil,
      owner: owner
    )

    do {
      guard rawThreadID == nil || threadID != nil,
        rawTurnID == nil || turnID != nil,
        rawItemID == nil || itemID != nil,
        rawCorrelationID == nil || Self.safeStoredIdentifier(rawCorrelationID) != nil
      else {
        throw CodexToolError.invalidArguments(
          "codex.app.approval_identifier_invalid: Approval identifiers must be bounded opaque values."
        )
      }
      try Self.validateNativeApprovalRequest(method: method, params: rawDetails)
      try persistApproval(record)
    } catch {
      var denied = record
      denied.state = .denied
      denied.resolvedAt = Date()
      denied.decision = .string("decline")
      denied.resolutionReason = Self.errorDescription(error)
      try? persistApproval(denied)
      await rejectApprovalHandle(
        handle,
        connection: connection,
        message: "The native approval request is invalid."
      )
      await eventBuffer.append(kind: "approval_denied", payload: denied.json)
      return
    }

    pendingApprovalHandles[id] = handle
    await eventBuffer.append(kind: "approval_requested", payload: record.json)

    approvalTimeoutTasks[id] = Task { [weak self] in
      do {
        try await Task.sleep(
          for: .seconds(self?.configuration.appServerApprovalTimeoutSeconds ?? 0))
      } catch {
        return
      }
      await self?.timeoutApproval(id: id)
    }
  }

  private func handleDynamicToolCall(
    _ handle: CodexAppServerRawServerRequest, connection: CodexAppServerConnection
  ) async {
    do {
      let params = try Self.decodeStableParams(
        Stable.DynamicToolCallParams.self,
        from: Self.gatewayJSON(handle.params))
      guard params.namespace == nil || params.namespace == "computer-mcp",
        !params.tool.hasPrefix("codex."), let dynamicToolDispatcher
      else {
        await rejectServerRequest(handle, method: handle.method, connection: connection)
        return
      }
      let arguments = try Self.gatewayJSON(params.arguments)
      _ = try await dynamicToolDispatcher.risk(
        named: params.tool, arguments: arguments,
        requestID: params.callId, workspaceID: owner?.workspaceID)
      let result = try await dynamicToolDispatcher.execute(
        name: params.tool, arguments: arguments,
        requestID: params.callId, workspaceID: owner?.workspaceID)
      try await resolveOwnedServerRequest(
        handle, connection: connection,
        with: Self.dynamicToolResponse(
          success: result.objectValue?["isError"] != .bool(true), value: result))
    } catch {
      try? await resolveOwnedServerRequest(
        handle, connection: connection,
        with: Self.dynamicToolResponse(
          success: false,
          value: .object(["error": .string(Self.errorDescription(error))])))
    }
  }

  private func resolveApproval(
    id: String,
    response: JSONValue
  ) async throws -> CodexApprovalRecord {
    let storedRecord: CodexApprovalRecord?
    if let cached = approvalRecords[id] {
      storedRecord = cached
    } else {
      storedRecord = try database?.codexApproval(id: id)
    }
    guard var record = storedRecord, Self.isApprovalVisible(record, to: owner) else {
      throw CodexApprovalBrokerError.unknown(id)
    }
    guard record.state == .pending else {
      throw CodexApprovalBrokerError.alreadyResolved(id)
    }
    guard let handle = pendingApprovalHandles[id], let connection else {
      if record.runtimeID != runtimeID, !Self.isApprovalOwnerGone(record, database: database) {
        throw CodexToolError.disabled(
          "codex.app.approval_owner_unavailable: The recorded owner is still alive or could not be verified. Respond through its owning adapter connection."
        )
      }
      record.state = .interrupted
      record.resolvedAt = Date()
      record.resolutionReason = "The live App Server request is no longer available."
      try persistApproval(record)
      throw CodexApprovalBrokerError.unavailableAfterRestart(id)
    }
    if record.expiresAt <= Date() {
      await timeoutApproval(id: id)
      throw CodexApprovalBrokerError.alreadyResolved(id)
    }
    try Self.validateNativeApprovalResponse(method: handle.method, response: response)

    do {
      // Remove before suspension so concurrent responders cannot both send.
      pendingApprovalHandles.removeValue(forKey: id)
      try await resolveOwnedServerRequest(handle, connection: connection, with: response)
      let decision = response.objectValue?["decision"]
      record.state = Self.approvalState(response)
      record.resolvedAt = Date()
      record.decision = decision
      record.response = response
      record.scope = response.objectValue?["scope"]?.stringValue
      record.resolutionReason = nil
      try persistApproval(record)
      pendingApprovalHandles.removeValue(forKey: id)
      approvalTimeoutTasks.removeValue(forKey: id)?.cancel()
      await eventBuffer.append(kind: "approval_resolved", payload: record.json)
      return record
    } catch {
      record.state = .failed
      record.resolvedAt = Date()
      record.resolutionReason = Self.errorDescription(error)
      try? persistApproval(record)
      pendingApprovalHandles.removeValue(forKey: id)
      approvalTimeoutTasks.removeValue(forKey: id)?.cancel()
      await eventBuffer.append(kind: "approval_response_failed", payload: record.json)
      throw error
    }
  }

  private func timeoutApproval(id: String) async {
    guard var record = approvalRecords[id], record.state == .pending,
      let handle = pendingApprovalHandles[id], let connection
    else {
      return
    }
    do {
      try await resolve(
        handle: handle,
        timedOut: true,
        connection: connection
      )
      record.state = .timedOut
      record.resolvedAt = Date()
      record.decision = .string("cancel")
      record.scope = "once"
      record.resolutionReason = "Approval deadline expired."
      try persistApproval(record)
      pendingApprovalHandles.removeValue(forKey: id)
      approvalTimeoutTasks.removeValue(forKey: id)?.cancel()
      await eventBuffer.append(kind: "approval_timed_out", payload: record.json)
    } catch {
      record.state = .failed
      record.resolvedAt = Date()
      record.decision = .string("cancel")
      record.scope = "once"
      record.resolutionReason =
        "Approval deadline expired, but the App Server response could not be delivered: "
        + Self.errorDescription(error)
      try? persistApproval(record)
      pendingApprovalHandles.removeValue(forKey: id)
      approvalTimeoutTasks.removeValue(forKey: id)?.cancel()
      await eventBuffer.append(kind: "approval_timeout_response_failed", payload: record.json)
      await recordConsumerFailure(
        kind: "approval_timeout_response_failed",
        message: error.localizedDescription
      )
    }
  }

  private func reconcileApprovalRecords() async throws {
    if let database {
      for record in try database.codexApprovals(limit: 5_000)
      where Self.isApprovalVisible(record, to: owner) {
        approvalRecords[record.id] = record
      }
    }
    let now = Date()
    for id in approvalRecords.keys.sorted() {
      guard var record = approvalRecords[id], record.state == .pending else { continue }
      if let task = approvalTimeoutTasks[id], !task.isCancelled {
        continue
      }
      if record.runtimeID == runtimeID, pendingApprovalHandles[id] != nil {
        if record.expiresAt <= now {
          await timeoutApproval(id: id)
        }
        continue
      }
      if Self.isApprovalOwnerGone(record, database: database) {
        record.state = .interrupted
        record.resolvedAt = now
        record.resolutionReason = "The owning runtime is no longer active."
        try persistApproval(record)
      }
    }
  }

  private func interruptPendingApprovals(
    connection: CodexAppServerConnection,
    reason: String
  ) async {
    for id in pendingApprovalHandles.keys.sorted() {
      guard var record = approvalRecords[id], let handle = pendingApprovalHandles[id] else {
        continue
      }
      try? await resolve(
        handle: handle,
        timedOut: false,
        connection: connection
      )
      record.state = .interrupted
      record.resolvedAt = Date()
      record.decision = .string("cancel")
      record.resolutionReason = reason
      try? persistApproval(record)
      approvalTimeoutTasks.removeValue(forKey: id)?.cancel()
    }
    pendingApprovalHandles.removeAll()
  }

  private func persistApproval(_ record: CodexApprovalRecord) throws {
    try database?.saveCodexApproval(record)
    approvalRecords[record.id] = record
  }

  private nonisolated static func isApprovalVisible(
    _ record: CodexApprovalRecord,
    to owner: CodexRuntimeOwner?
  ) -> Bool {
    record.workspaceID == owner?.workspaceID
      && record.owner?.principalID == owner?.principalID
      && (record.owner == nil || record.owner?.profileID == owner?.profileID)
  }

  private func resolveOwnedServerRequest<Response: Encodable & Sendable>(
    _ handle: CodexAppServerRawServerRequest, connection: CodexAppServerConnection,
    with response: Response
  ) async throws {
    let id = ServerRequestWorkKey(
      connection: ObjectIdentifier(connection), requestID: Self.requestIDString(handle.id))
    let work = serverRequestWork[id]
    do {
      try await connection.resolveServerRequest(handle, with: response)
      finishServerRequestWork(id: id, work: work, confirmed: true)
    } catch {
      finishServerRequestWork(id: id, work: work, confirmed: false)
      throw error
    }
  }

  private func rejectOwnedServerRequest(
    _ handle: CodexAppServerRawServerRequest, connection: CodexAppServerConnection,
    code: Int64, message: String
  ) async throws {
    let id = ServerRequestWorkKey(
      connection: ObjectIdentifier(connection), requestID: Self.requestIDString(handle.id))
    let work = serverRequestWork[id]
    do {
      try await connection.rejectServerRequest(handle, code: code, message: message)
      finishServerRequestWork(id: id, work: work, confirmed: true)
    } catch {
      finishServerRequestWork(id: id, work: work, confirmed: false)
      throw error
    }
  }

  private func finishServerRequestWork(
    id: ServerRequestWorkKey, work: ServerRequestWork?, confirmed: Bool
  ) {
    guard let work, serverRequestWork[id]?.binding.id == work.binding.id else { return }
    if confirmed {
      serverRequestWork[id]?.nativeSettled = true
    } else {
      serverRequestWork[id]?.state = .uncertain
    }
    releaseSettledServerRequest(id: id)
  }

  private func finishServerRequestHandler(id: ServerRequestWorkKey, workID: String?) {
    guard let workID, serverRequestWork[id]?.binding.id == workID else { return }
    serverRequestWork[id]?.handlerActive = false
    releaseSettledServerRequest(id: id)
  }

  private func releaseSettledServerRequest(id: ServerRequestWorkKey) {
    if let work = serverRequestWork[id], work.nativeSettled && !work.handlerActive {
      serverRequestWork.removeValue(forKey: id)
    }
    pruneWorkBindings()
    unregisterIfDrained()
  }

  private func unregisterIfDrained() {
    if isShutdown, unconfirmedTransport == nil, serverRequestWork.isEmpty {
      CodexRuntimeDirectory.shared.unregister(id: runtimeID)
    }
  }

  private func rejectServerRequest(
    _ handle: CodexAppServerRawServerRequest,
    method: String,
    connection: CodexAppServerConnection
  ) async {
    let id = Self.requestIDString(handle.id)
    let payload = CodexApprovalRedactor.redact(
      Self.serverRequestPayload(method: method, params: handle.params)
    )
    do {
      try await rejectOwnedServerRequest(
        handle, connection: connection,
        code: -32_001,
        message:
          "This App Server request is not part of the supported coding contract."
      )
      await eventBuffer.append(
        kind: "server_request_denied",
        payload: .object(["request_id": .string(id), "request": payload])
      )
    } catch {
      await recordConsumerFailure(
        kind: "server_request_rejection_failed",
        message: error.localizedDescription
      )
    }
  }

  private func rejectApprovalHandle(
    _ handle: PendingApprovalHandle,
    connection: CodexAppServerConnection,
    message: String
  ) async {
    do {
      try await rejectOwnedServerRequest(
        handle, connection: connection, code: -32_001, message: message)
    } catch {
      await recordConsumerFailure(
        kind: "approval_policy_rejection_failed",
        message: error.localizedDescription
      )
    }
  }

  private static func approvalRisk(
    kind: CodexApprovalKind,
    details: JSONValue
  ) -> CodexOperationRisk {
    let object = details.objectValue ?? [:]
    if object["networkApprovalContext"] != nil
      || !(object["proposedNetworkPolicyAmendments"]?.arrayValue ?? []).isEmpty
      || object["permissions"]?.objectValue?["network"]?.objectValue?["enabled"]?.boolValue == true
    {
      return .externalWrite
    }
    return kind == .permissions ? .destructive : .workspaceWrite
  }

  private static func validateNativeApprovalRequest(method: String, params: JSONValue) throws {
    switch method {
    case "item/commandExecution/requestApproval":
      _ = try decodeStableParams(Stable.CommandExecutionRequestApprovalParams.self, from: params)
    case "item/fileChange/requestApproval":
      _ = try decodeStableParams(Stable.FileChangeRequestApprovalParams.self, from: params)
    case "item/permissions/requestApproval":
      _ = try decodeStableParams(Stable.PermissionsRequestApprovalParams.self, from: params)
    case "applyPatchApproval":
      _ = try decodeStableParams(Stable.ApplyPatchApprovalParams.self, from: params)
    case "execCommandApproval":
      _ = try decodeStableParams(Stable.ExecCommandApprovalParams.self, from: params)
    default: throw CodexToolError.invalidArguments("Unsupported native approval method.")
    }
  }

  private static func validateNativeApprovalResponse(method: String, response: JSONValue) throws {
    switch method {
    case "item/commandExecution/requestApproval":
      _ = try decodeStableParams(
        Stable.CommandExecutionRequestApprovalResponse.self, from: response)
    case "item/fileChange/requestApproval":
      _ = try decodeStableParams(Stable.FileChangeRequestApprovalResponse.self, from: response)
    case "item/permissions/requestApproval":
      _ = try decodeStableParams(Stable.PermissionsRequestApprovalResponse.self, from: response)
    case "applyPatchApproval":
      _ = try decodeStableParams(Stable.ApplyPatchApprovalResponse.self, from: response)
    case "execCommandApproval":
      _ = try decodeStableParams(Stable.ExecCommandApprovalResponse.self, from: response)
    default: throw CodexToolError.invalidArguments("Unsupported native approval method.")
    }
  }

  private static func approvalState(_ response: JSONValue) -> CodexApprovalState {
    let object = response.objectValue ?? [:]
    if let permissions = object["permissions"]?.objectValue {
      return permissions.isEmpty ? .denied : .approved
    }
    if let decision = object["decision"]?.stringValue {
      if ["cancel", "abort", "timed_out"].contains(decision) { return .cancelled }
      if ["decline", "denied"].contains(decision) { return .denied }
    }
    if object["decision"]?.objectValue?["denied"] != nil { return .denied }
    if object["decision"]?.objectValue?["applyNetworkPolicyAmendment"]?.objectValue?[
      "network_policy_amendment"]?.objectValue?["action"] == .string("deny")
    {
      return .denied
    }
    return .approved
  }

  private func resolve(
    handle: PendingApprovalHandle, timedOut: Bool,
    connection: CodexAppServerConnection
  ) async throws {
    let response: JSONValue
    switch handle.method {
    case "item/permissions/requestApproval":
      response = .object(["permissions": .object([:]), "scope": .string("turn")])
    case "applyPatchApproval", "execCommandApproval":
      response = .object(["decision": .string(timedOut ? "timed_out" : "abort")])
    default:
      response = .object(["decision": .string("cancel")])
    }
    try await resolveOwnedServerRequest(handle, connection: connection, with: response)
  }

  private static func dynamicToolResponse(
    success: Bool,
    value: JSONValue
  ) -> Stable.DynamicToolCallResponse {
    let text: String
    if let data = try? CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys]).encode(value) {
      text = String(decoding: data.prefix(1_048_576), as: UTF8.self)
    } else {
      text = "{\"error\":\"Computer MCP could not encode the tool result.\"}"
    }
    return Stable.DynamicToolCallResponse(
      contentItems: [
        .inputtext(.init(text: text, type: .inputtext))
      ],
      success: success
    )
  }

  private func connectionEnded(
    _ endedConnection: CodexAppServerConnection,
    message: String?
  ) async {
    // Explicit shutdown owns cleanup after cancelling the notification consumer.
    guard !isShutdown else { return }
    guard connection === endedConnection else {
      await endedConnection.close()
      return
    }
    let endedTransport = processTransport
    let endedGeneration = connectionGeneration
    connection = nil
    connectionID = nil
    processTransport = nil
    connectionState = message == nil ? "stopped" : "failed"
    shutdownReason = nil
    let redactedMessage = message.map(Self.redactedMessage)
    lastError = redactedMessage
    recordRequestFailure(
      kind: message == nil ? "peer_closed" : "consumer_failure",
      message: redactedMessage ?? "App Server connection ended.")
    let retirement = RequestGenerationRetirement(
      id: UUID(), work: .init(origin: .init(invocation: CodexWorkInvocation.current)),
      generation: endedGeneration,
      transport: endedTransport,
      task: Task {
        await self.interruptPendingApprovals(
          connection: endedConnection,
          reason: message == nil ? "App Server connection ended." : "App Server connection failed.")
        await endedConnection.close()
        await endedTransport?.close()
        return await endedTransport?.snapshot()
      })
    requestGenerationRetirement = retirement
    pendingUserInputRequests.removeAll()
    await eventBuffer.append(
      kind: "connection_ended",
      payload: .object(["message": redactedMessage.map(JSONValue.string) ?? .null]))
    await finishRequestGenerationRetirement(retirement)
  }

  private func retireCurrentRequestGeneration(method: String? = nil) async {
    if let requestGenerationRetirement {
      await finishRequestGenerationRetirement(requestGenerationRetirement)
      return
    }
    if let connection {
      let transport = processTransport
      self.connection = nil
      connectionID = nil
      processTransport = nil
      notificationTask?.cancel()
      notificationTask = nil
      requestTask?.cancel()
      requestTask = nil
      pendingUserInputRequests.removeAll()
      connectionState = "failed"
      shutdownReason = nil
      lastError = "App Server request deadline exceeded."
      recordRequestFailure(
        kind: "request_timeout",
        message: method.map { "App Server request '\($0)' exceeded its deadline." }
          ?? "App Server request deadline exceeded."
      )
      let retirement = RequestGenerationRetirement(
        id: UUID(), work: .init(origin: .init(invocation: CodexWorkInvocation.current)),
        generation: connectionGeneration,
        transport: transport,
        task: Task {
          await self.interruptPendingApprovals(
            connection: connection, reason: "App Server request deadline exceeded.")
          await connection.close()
          await transport?.close()
          return await transport?.snapshot()
        }
      )
      requestGenerationRetirement = retirement
      await eventBuffer.append(
        kind: "connection_ended",
        payload: .object(["message": .string("App Server request deadline exceeded.")])
      )
      await finishRequestGenerationRetirement(retirement)
      return
    }
    guard let startup = connectionStartup else {
      return
    }
    if connectionStartup?.id == startup.id {
      connectionStartup = nil
    }
    timedOutConnectionStartupIDs.insert(startup.id)
    startup.task.cancel()
    connectionState = "failed"
    shutdownReason = nil
    lastError = "App Server request deadline exceeded during connection startup."
    recordRequestFailure(
      kind: "request_timeout",
      message: method.map { "App Server request '\($0)' timed out during connection startup." }
        ?? "App Server request timed out during connection startup."
    )
    await eventBuffer.append(
      kind: "connection_failed",
      payload: .object([
        "message": .string("App Server request deadline exceeded during connection startup.")
      ])
    )
    let retirement = RequestGenerationRetirement(
      id: UUID(), work: startup.work,
      generation: connectionGeneration,
      transport: startup.transport,
      task: Task {
        await startup.transport.close()
        return await startup.transport.snapshot()
      }
    )
    requestGenerationRetirement = retirement
    await finishRequestGenerationRetirement(retirement)
  }

  private func finishRequestGenerationRetirement(
    _ retirement: RequestGenerationRetirement
  ) async {
    let processSnapshot = await retirement.task.value
    guard requestGenerationRetirement?.id == retirement.id else { return }
    requestGenerationRetirement = nil
    if let processSnapshot {
      lastProcessSnapshot = processSnapshot
      if processSnapshot.cleanupConfirmed == true {
        releaseConfirmedGeneration(retirement.generation)
      } else if let transport = retirement.transport {
        unconfirmedTransport = (retirement.generation, transport)
        cleanupWork = retirement.work
      }
    }
    persistRuntimeLease(
      state: "failed",
      process: lastProcessSnapshot,
      reason: nil
    )
  }

  private func recheckProcessCleanup() async {
    guard let pending = unconfirmedTransport else { return }
    let snapshot = await pending.transport.snapshot()
    guard unconfirmedTransport?.generation == pending.generation else { return }
    lastProcessSnapshot = snapshot
    if snapshot.cleanupConfirmed == true {
      releaseConfirmedGeneration(pending.generation)
      unconfirmedTransport = nil
      unregisterIfDrained()
    }
  }

  private func releaseConfirmedGeneration(_ generation: Int) {
    nativeResources.retired(generation: generation)
    for id in serverRequestWork.keys where serverRequestWork[id]?.generation == generation {
      serverRequestWork[id]?.nativeSettled = true
      if serverRequestWork[id]?.handlerActive == false { serverRequestWork.removeValue(forKey: id) }
    }
    guard generation == connectionGeneration else { return }
    cleanupWork = nil
    threadWork.removeAll()
    turnWork.removeAll()
    goalWork.removeAll()
    uncertainGoalWork.removeAll()
    workspaceScopedThreadIDs.removeAll()
    loadedThreadIDs.removeAll()
    subscribedThreadIDs.removeAll()
    activeTurnIDs.removeAll()
    threadStates.removeAll()
  }

  private func recordRequestFailure(kind: String, message: String) {
    lastRequestFailure = CodexRuntimeRequestFailure(
      kind: kind,
      message: Self.redactedMessage(message),
      occurredAt: Date(),
      connectionGeneration: connectionGeneration,
      recoverable: !isShutdown
    )
  }

  static func boundedRequest<Value: Sendable>(
    timeoutSeconds: Int,
    onTimeout: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let completion = CodexTimedRequestCompletion<Value>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard completion.install(continuation) else {
          continuation.resume(throwing: CancellationError())
          return
        }
        let operationTask = Task {
          do {
            completion.resumeOperation(with: .success(try await operation()))
          } catch {
            completion.resumeOperation(with: .failure(error))
          }
        }
        let timeoutTask = Task {
          do {
            try await Task.sleep(for: .seconds(timeoutSeconds))
          } catch {
            return
          }
          guard let continuation = completion.claim(.timeout) else {
            return
          }
          await onTimeout()
          continuation.resume(throwing: RequestTimeoutError(seconds: timeoutSeconds))
        }
        completion.installTasks(operation: operationTask, timeout: timeoutTask)
      }
    } onCancel: {
      completion.cancel()
    }
  }

  private func recordConsumerFailure(kind: String, message: String) async {
    await eventBuffer.append(
      kind: kind,
      payload: .object(["message": .string(Self.redactedMessage(message))])
    )
  }

  private func persistRuntimeLease(
    state: String,
    process: CodexAppServerProcessSnapshot? = nil,
    reason: String? = nil
  ) {
    guard let database else { return }
    let now = Date()
    let previous = try? database.codexRuntimeLeases(limit: 5_000)
      .first(where: { $0.id == runtimeID })
    let record = CodexRuntimeLeaseRecord(
      id: runtimeID,
      owner: owner,
      workspacePath: workspaceURL.path,
      state: state,
      process: process ?? lastProcessSnapshot ?? previous?.process,
      createdAt: previous?.createdAt ?? createdAt,
      updatedAt: now,
      shutdownReason: state == "stopped" || state == "cleaned"
        ? (reason ?? previous?.shutdownReason) : nil,
      cleanedAt: previous?.cleanedAt,
      runtimeState: isShutdown ? "stopped" : "running",
      connectionState: connectionState,
      processState: (process ?? lastProcessSnapshot ?? previous?.process)?.state.rawValue,
      currentRequestState: currentRequestState,
      lastRequestFailure: lastRequestFailure ?? previous?.lastRequestFailure
    )
    try? database.saveCodexRuntimeLease(record)
  }

  func normalize(
    params: JSONValue?,
    for method: CodexAppServerMethod
  ) throws -> JSONValue? {
    guard method.takesParams else {
      guard params == nil || params == .null || params == .object([:]) else {
        throw CodexToolError.invalidArguments("This App Server method does not accept params.")
      }
      return nil
    }
    var object = params?.objectValue ?? [:]
    guard params == nil || params == .null || params?.objectValue != nil else {
      throw CodexToolError.invalidArguments("App Server params must be an object.")
    }
    switch method.method {
    case "thread/start":
      if object["cwd"] == nil { object["cwd"] = .string(workspaceURL.path) }
      fallthrough
    case "thread/resume", "thread/fork":
      if object["approvalPolicy"] == nil, let approval = configuration.approvalPolicy {
        object["approvalPolicy"] = .string(approval.rawValue)
      }
      if object["sandbox"] == nil, let sandbox = configuration.sandbox {
        object["sandbox"] = .string(sandbox.rawValue)
      }
    case "turn/start":
      if object["approvalPolicy"] == nil, let approval = configuration.approvalPolicy {
        object["approvalPolicy"] = .string(approval.rawValue)
      }
      if object["sandboxPolicy"] == nil, let sandbox = configuration.sandbox {
        object["sandboxPolicy"] = Self.sandboxPolicy(sandbox)
      }
    default:
      break
    }
    return .object(object)
  }

  private func validateWorkspaceScope(
    method: String,
    params: JSONValue?,
    connection: CodexAppServerConnection
  ) async throws {
    guard let threadID = try Self.workspaceScopedThreadID(method: method, params: params) else {
      return
    }
    if let receipt = try database?.codexThreadOwnership(threadID: threadID) {
      try validatePersistedOwnership(receipt)
    }
    if workspaceScopedThreadIDs.contains(threadID) {
      return
    }

    if method == "thread/resume" {
      do {
        try await validatePersistedWorkspaceThread(
          threadID: threadID,
          connection: connection
        )
        workspaceScopedThreadIDs.insert(threadID)
        return
      } catch {
        throw CodexToolError.executionFailed(
          "codex.app.thread_scope_lookup_failed: \(Self.errorDescription(error))"
        )
      }
    }

    let response: JSONValue
    do {
      response = try Self.gatewayJSON(
        try await connection.threadRead(
          try Self.decodeStableParams(
            Stable.ThreadReadParams.self,
            from: .object([
              "threadId": .string(threadID),
              "includeTurns": .bool(false),
            ])
          )
        )
      )
    } catch  where Self.isThreadNotLoaded(error) {
      do {
        try await validatePersistedWorkspaceThread(
          threadID: threadID,
          connection: connection
        )
        workspaceScopedThreadIDs.insert(threadID)
        return
      } catch {
        throw CodexToolError.executionFailed(
          "codex.app.thread_scope_lookup_failed: \(Self.errorDescription(error))"
        )
      }
    } catch {
      throw CodexToolError.executionFailed(
        "codex.app.thread_scope_lookup_failed: \(Self.errorDescription(error))"
      )
    }
    try Self.validateThreadResponse(
      threadID: threadID,
      response: response
    )
    workspaceScopedThreadIDs.insert(threadID)
  }

  private func validatePersistedWorkspaceThread(
    threadID: String,
    connection: CodexAppServerConnection
  ) async throws {
    if let ownership = try database?.codexThreadOwnership(threadID: threadID) {
      try validatePersistedOwnership(ownership)
      return
    }

    let cwdFilters: [Stable.ThreadListCwdFilter?] = [nil]
    for cwdFilter in cwdFilters {
      for archived in [false, true] {
        var cursor: String?
        var visitedCursors: Set<String> = []
        for pageIndex in 0..<100 {
          let currentCursor = cursor
          let page: Stable.ThreadListResponse
          do {
            page = try await connection.threadList(
              Stable.ThreadListParams(
                archived: archived,
                cursor: currentCursor,
                cwd: cwdFilter,
                limit: 1_000,
                sourceKinds: Self.persistedThreadSourceKinds,
                useStateDbOnly: true
              )
            )
          } catch {
            throw CodexToolError.executionFailed(
              "codex.app.thread_scope_list_failed: \(Self.errorDescription(error))"
            )
          }
          if page.data.contains(where: { $0.id == threadID }) {
            return
          }
          guard let nextCursor = page.nextCursor, !nextCursor.isEmpty else {
            break
          }
          guard visitedCursors.insert(nextCursor).inserted else {
            throw CodexToolError.executionFailed(
              "codex.app.thread_scope_pagination_invalid: App Server repeated a thread-list cursor."
            )
          }
          guard pageIndex < 99 else {
            throw CodexToolError.executionFailed(
              "codex.app.thread_scope_pagination_limit: Thread ownership lookup exceeded 100 pages."
            )
          }
          cursor = nextCursor
        }
      }
    }
    throw CodexToolError.disabled(
      "codex.app.thread_outside_workspace_or_unknown: The thread is not available in the bound workspace."
    )
  }

  private func validatePersistedOwnership(_ ownership: CodexThreadOwnershipRecord) throws {
    guard ownership.owner?.principalID == owner?.principalID,
      ownership.owner == nil
        || ownership.owner?.profileID == owner?.profileID
    else {
      throw CodexToolError.disabled("The thread belongs to another authorization subject.")
    }
    if let workspaceID = owner?.workspaceID {
      guard ownership.workspaceID == workspaceID else {
        throw CodexToolError.disabled(
          "codex.app.thread_outside_workspace: The thread belongs to a different registered workspace."
        )
      }
    }
    let recordedWorkspace = URL(fileURLWithPath: ownership.workspacePath)
      .standardizedFileURL.resolvingSymlinksInPath()
    let currentWorkspace = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
    guard recordedWorkspace == currentWorkspace else {
      throw CodexToolError.disabled(
        "codex.app.thread_outside_workspace: The thread belongs to a different workspace root."
      )
    }
  }

  private func rememberWorkspaceScopedThreads(
    method: String,
    params: JSONValue?,
    response: JSONValue, creator: UUID?, previouslyOwnedThreads: Set<String>
  ) throws {
    if ["thread/start", "thread/resume", "thread/fork"].contains(method) {
      let threadID = try Self.createdThreadID(
        response: response
      )
      try persistThreadOwnership(threadID: threadID, state: .loaded)
      workspaceScopedThreadIDs.insert(threadID)
      loadedThreadIDs.insert(threadID)
      subscribedThreadIDs.insert(threadID)
      if !previouslyOwnedThreads.contains(threadID) {
        threadBinding(threadID).origin.bind(to: creator)
      }
    }

    if method == "thread/loaded/list" {
      let visible = response.objectValue?["data"]?.arrayValue?.compactMap(\.stringValue) ?? []
      let loaded = Set(try visible.filter { try threadOwnerIndex?.owns(threadID: $0) ?? true })
      let removed = loadedThreadIDs.union(subscribedThreadIDs).subtracting(loaded)
      for id in removed { threadWork.removeValue(forKey: id) }
      workspaceScopedThreadIDs.formUnion(loaded)
      loadedThreadIDs = loaded
      subscribedThreadIDs = loaded
      for threadID in loaded where threadOwnerIndex == nil {
        try persistThreadOwnership(threadID: threadID, state: .loaded)
      }
    }

    if ["thread/unsubscribe", "thread/delete"].contains(method),
      let threadID = params?.objectValue?["threadId"]?.stringValue
    {
      loadedThreadIDs.remove(threadID)
      subscribedThreadIDs.remove(threadID)
      activeTurnIDs.removeValue(forKey: threadID)
      threadWork.removeValue(forKey: threadID)
      threadStates[threadID] = .string(method == "thread/delete" ? "deleted" : "released")
      if method == "thread/delete" { workspaceScopedThreadIDs.remove(threadID) }
      try persistThreadOwnership(
        threadID: threadID, state: method == "thread/delete" ? .deleted : .released)
    }

    if method == "thread/archive",
      let threadID = params?.objectValue?["threadId"]?.stringValue
    {
      try persistThreadOwnership(threadID: threadID, state: .archived)
    }

    if method == "thread/unarchive",
      let threadID = params?.objectValue?["threadId"]?.stringValue
    {
      try persistThreadOwnership(threadID: threadID, state: .released)
    }

    if method == "review/start",
      let reviewThreadID = response.objectValue?["reviewThreadId"]?.stringValue,
      !reviewThreadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      workspaceScopedThreadIDs.insert(reviewThreadID)
    }
  }

  private func releaseAllThreads(connection: CodexAppServerConnection) async {
    for threadID in subscribedThreadIDs.sorted() {
      do {
        _ = try await Self.boundedRequest(
          timeoutSeconds: min(2, configuration.appServerRequestTimeoutSeconds),
          onTimeout: {},
          operation: {
            try await connection.threadUnsubscribe(
              try Self.decodeStableParams(
                Stable.ThreadUnsubscribeParams.self,
                from: .object(["threadId": .string(threadID)])
              )
            )
          }
        )
        loadedThreadIDs.remove(threadID)
        subscribedThreadIDs.remove(threadID)
        threadStates[threadID] = .string("released")
        threadWork.removeValue(forKey: threadID)
        try persistThreadOwnership(threadID: threadID, state: .released)
      } catch {
        await eventBuffer.append(
          kind: "thread_release_failed",
          payload: .object([
            "thread_id": .string(threadID),
            "message": .string(Self.errorDescription(error)),
          ])
        )
      }
    }
  }

  private func persistThreadOwnership(
    threadID: String,
    state: CodexThreadOwnershipState
  ) throws {
    try threadOwnerIndex?.claim(threadID: threadID)
    guard let database else { return }
    let now = Date()
    let previous = try database.codexThreadOwnership(threadID: threadID)
    if let previous {
      try validatePersistedOwnership(previous)
    }
    try database.saveCodexThreadOwnership(
      CodexThreadOwnershipRecord(
        threadID: threadID,
        workspaceID: owner?.workspaceID,
        workspacePath: workspaceURL.path,
        runtimeID: runtimeID,
        state: state,
        createdAt: previous?.createdAt ?? now,
        updatedAt: now,
        owner: owner
      )
    )
  }

  static func createdThreadID(response: JSONValue) throws -> String {
    guard let id = response.objectValue?["thread"]?.objectValue?["id"]?.stringValue else {
      throw CodexToolError.executionFailed("App Server did not return the created thread identity.")
    }
    return try validatedThreadID(id)
  }

  static func workspaceScopedThreadID(
    method: String,
    params: JSONValue?
  ) throws -> String? {
    guard
      let required = CodexAppServerMethodCatalog.method(named: method)?.threadParameters["threadId"]
    else {
      return nil
    }
    if !required,
      params?.objectValue?["threadId"] == nil || params?.objectValue?["threadId"] == .null
    {
      return nil
    }
    guard let rawThreadID = params?.objectValue?["threadId"]?.stringValue else {
      throw CodexToolError.invalidArguments(
        "codex.app.thread_id_required: method '\(method)' requires a non-empty threadId."
      )
    }
    return try validatedThreadID(rawThreadID)
  }

  static func validateThreadResponse(threadID: String, response: JSONValue) throws {
    guard response.objectValue?["thread"]?.objectValue?["id"] == .string(threadID) else {
      throw CodexToolError.executionFailed("App Server returned a different thread identity.")
    }
  }

  static func validatedThreadID(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 1_024,
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw CodexToolError.invalidArguments(
        "codex.app.thread_id_invalid: threadId must be a bounded opaque identifier."
      )
    }
    return trimmed
  }

  private static func safeStoredIdentifier(
    _ value: String?,
    maximumBytes: Int = 1_024
  ) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes,
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
      CodexApprovalRedactor.redactString(trimmed, maximumCharacters: 8_192) == trimmed
    else {
      return nil
    }
    return trimmed
  }

  static func isThreadNotLoaded(_ error: Error) -> Bool {
    guard let clientError = error as? CodexAppServerClientError,
      case .jsonRPCError(let code, let message, _) = clientError
    else {
      return false
    }
    return code == -32_600
      && message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        .hasPrefix("thread not loaded")
  }

  private static let persistedThreadSourceKinds: [Stable.ThreadSourceKind] = [
    .cli,
    .vscode,
    .exec,
    .appserver,
    .subagent,
    .subagentreview,
    .subagentcompact,
    .subagentthreadspawn,
    .subagentother,
    .unknown,
  ]

  static func contains(_ candidate: URL, in root: URL) -> Bool {
    let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
    let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    return resolvedCandidate == resolvedRoot
      || resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/")
  }

  private static func sandboxPolicy(_ mode: CodexSandboxMode) -> JSONValue {
    switch mode {
    case .readOnly:
      return .object([
        "type": .string("readOnly"),
        "networkAccess": .bool(false),
      ])
    case .workspaceWrite:
      return .object([
        "type": .string("workspaceWrite"),
        "networkAccess": .bool(false),
      ])
    case .dangerFullAccess:
      return .object(["type": .string("dangerFullAccess")])
    }
  }

  private static func stableJSON(
    _ value: JSONValue
  ) throws -> CodexAppServerProtocol.Stable.JSONValue {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(
      CodexAppServerProtocol.Stable.JSONValue.self,
      from: data
    )
  }

  private static func decodeUserInputResponse(
    _ value: JSONValue
  ) throws -> Stable.ToolRequestUserInputResponse {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Stable.ToolRequestUserInputResponse.self, from: data)
  }

  private static func decodeElicitationResponse(
    _ value: JSONValue
  ) throws -> Stable.McpServerElicitationRequestResponse {
    guard let action = value.objectValue?["action"]?.stringValue,
      ["accept", "decline", "cancel"].contains(action)
    else {
      throw CodexToolError.invalidArguments(
        "codex.app.elicitation_response_invalid: action must be accept, decline, or cancel."
      )
    }
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Stable.McpServerElicitationRequestResponse.self, from: data)
  }

  private static func serverRequestPayload<Params: Encodable>(
    method: String,
    params: Params
  ) -> JSONValue {
    .object([
      "method": .string(method),
      "params": (try? JSONValue.encoded(params)) ?? .null,
    ])
  }

  private static func serverRequestThreadID<Params: Encodable>(_ params: Params) -> String? {
    let object = (try? JSONValue.encoded(params))?.objectValue
    let raw = object?["threadId"]?.stringValue ?? object?["conversationId"]?.stringValue
    return raw.flatMap { try? validatedThreadID($0) }
  }

  private static func gatewayJSON<Value: Encodable>(_ value: Value) throws -> JSONValue {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  private static func decodeStableParams<Params: Decodable>(
    _ type: Params.Type,
    from value: JSONValue?
  ) throws -> Params {
    let data = try JSONEncoder().encode(value ?? .object([:]))
    return try JSONDecoder().decode(type, from: data)
  }

  private static func sendReviewedRequest(
    method: String,
    params: JSONValue?,
    connection: CodexAppServerConnection
  ) async throws -> JSONValue {
    if let params {
      return try gatewayJSON(
        try await connection.sendRawRequest(method: method, params: stableJSON(params)))
    }
    return try gatewayJSON(try await connection.sendRawRequest(method: method))
  }

  private func sendNativeRequest(
    method: String, params: JSONValue?, connection: CodexAppServerConnection
  ) async throws -> NativeReply {
    if let beforeThreadID = params?.objectValue?["beforeThreadId"]?.stringValue,
      CodexAppServerMethodCatalog.method(named: method)?.threadParameters["beforeThreadId"] != nil
    {
      try await validateWorkspaceScope(
        method: "thread/read",
        params: .object(["threadId": .string(beforeThreadID)]), connection: connection)
    }
    guard self.connection === connection else { throw CodexAppServerClientError.closed }
    let ticket = try nativeResources.prepare(
      method: method, params: params, generation: connectionGeneration)
    do {
      let result = try await Self.sendReviewedRequest(
        method: method, params: params, connection: connection)
      nativeResources.completed(ticket)
      return .init(connection: connection, value: result)
    } catch {
      if let nativeError = error as? CodexAppServerClientError, case .jsonRPCError = nativeError {
        nativeResources.completed(ticket, rejected: true)
      } else {
        nativeResources.uncertain(ticket)
      }
      // An uncertain send retains its handle; it cannot be replayed onto a new connection.
      throw error
    }
  }

  private static func requestIDString(
    _ id: CodexAppServerProtocol.Stable.RequestId
  ) -> String {
    switch id {
    case .requestidoption1(let value):
      return opaqueProtocolID(prefix: "s", value: value)
    case .requestidoption2(let value):
      return "n:\(value)"
    }
  }

  private static func opaqueProtocolID(prefix: String, value: String) -> String {
    if safeStoredIdentifier(value) != nil {
      return "\(prefix):\(value)"
    }
    let digest = SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "\(prefix):sha256:\(digest)"
  }

  private static func errorDescription(_ error: Error) -> String {
    redactedMessage(unredactedErrorDescription(error))
  }

  private static func unredactedErrorDescription(_ error: Error) -> String {
    guard let error = error as? CodexAppServerClientError else {
      return error.localizedDescription
    }
    switch error {
    case .foreignServerRequest:
      return "The App Server request belongs to another connection."
    case .closed:
      return "The App Server connection is closed."
    case .peerClosed:
      return "The App Server process closed its protocol stream."
    case .requestCancelled:
      return "The App Server request was cancelled."
    case .malformedInbound(let message):
      return "Malformed inbound App Server message: \(message)"
    case .malformedOutbound(let message):
      return "Malformed outbound App Server message: \(message)"
    case .invalidRawMethod(let method):
      return "Invalid raw App Server method: \(method)"
    case .rawMethodNotAllowed(let method):
      return "Raw App Server method is denied by swift-codex: \(method)"
    case .jsonRPCError(let code, let message, _):
      return "App Server JSON-RPC error \(code): \(message)"
    case .unmatchedResponse(let id):
      return "App Server returned an unmatched response id: \(id)"
    case .duplicateServerRequest(let id):
      return "App Server returned a duplicate server request id: \(id)"
    case .serverRequestAlreadyCompleted(let id):
      return "App Server request was already completed: \(id)"
    case .responseDecodeFailure(let message):
      return "App Server response decode failed: \(message)"
    }
  }

  private static func redactedMessage(_ message: String) -> String {
    CodexApprovalRedactor.redact(.string(message)).stringValue
      ?? "The App Server operation failed."
  }
}
