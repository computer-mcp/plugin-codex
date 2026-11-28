import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlugins
import ComputerMCPTransport
import Darwin
import Foundation
import MCP

@main
struct RegisteredHost {
  private enum FixtureError: Error {
    case invalidArguments, invalidRegistration, missingEpoch, invalidPeerMessage
  }

  static func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "--version":
      print(ComputerMCPCLI.version)
    case "app-server":
      try runPeer()
    case "register", "serve":
      guard arguments.count == 2 || (arguments.count == 4 && arguments[0] == "serve")
      else { throw FixtureError.invalidArguments }
      let root = URL(fileURLWithPath: arguments[1], isDirectory: true).resolvingSymlinksInPath()
      let observer: StdioTransport?
      if arguments.count == 4 {
        guard let input = Int32(arguments[2]), let output = Int32(arguments[3]),
          input > STDERR_FILENO, output > STDERR_FILENO, input != output,
          fcntl(input, F_SETFD, FD_CLOEXEC) == 0, fcntl(output, F_SETFD, FD_CLOEXEC) == 0
        else { throw FixtureError.invalidArguments }
        observer = StdioTransport(input: .init(rawValue: input), output: .init(rawValue: output))
      } else {
        observer = nil
      }
      try await run(root: root, register: arguments[0] == "register", observer: observer)
    default:
      throw FixtureError.invalidArguments
    }
  }

  private static func run(root: URL, register: Bool, observer: StdioTransport?) async throws {
    let database = try GatewayDatabase(path: root.appendingPathComponent("host.sqlite").path)
    _ = database.permissionStore(
      counter: FixtureEpochCounter(file: root.appendingPathComponent("fixture-epoch.json")))
    var services = MacOSPlatform.services
    services.permissionPolicyReader = FixturePolicySources()
    let platform = services
    let store = PluginStore(database: database, platform: platform)
    let configuration = try GatewayConfiguration.load(
      path: root.appendingPathComponent("host.toml").path,
      knownPluginMCPServerIDs: database.pluginStoreSnapshot().knownMCPRegistrationIDs)
    try database.bootstrapPermissionProfiles(
      configuration.profiles.map(\.grant), declarations: configuration.profiles.map(\.grant))
    try database.registerManifestProjectsForStartup(configuration.manifestProjects)
    let permissionRuntime = try database.permissionRuntime(platform: platform)
    try await permissionRuntime.ready()
    if register {
      try await registerPlugin(
        root: root, database: database, store: store, permissionRuntime: permissionRuntime,
        configuration: configuration)
      return
    }
    let primary = try await makeGateway(
      database: database, platform: platform, configuration: configuration)
    if let observer {
      let secondaryGateway = try await makeGateway(
        database: database, platform: platform, configuration: configuration, role: "observer")
      async let secondary: Void = serve(
        secondaryGateway, root: root, configuration: configuration,
        permissionRuntime: permissionRuntime, role: "observer", transport: observer)
      try await serve(
        primary, root: root, configuration: configuration,
        permissionRuntime: permissionRuntime, role: "acceptance")
      try await secondary
    } else {
      try await serve(
        primary, root: root, configuration: configuration, permissionRuntime: permissionRuntime)
    }
  }

  private static func makeGateway(
    database: GatewayDatabase, platform: PlatformServices, configuration: GatewayConfiguration,
    role: String? = nil
  ) async throws -> GatewayRuntime {
    let profile = role.flatMap { GatewayProfileID(rawValue: $0) } ?? configuration.runtime.profileID
    let context = ExecutionContext(
      caller: configuration.runtime.caller, profileID: profile,
      projectID: configuration.runtime.defaultProjectID,
      transportTrace: .init(transport: "stdio", socketConnectionID: UUID().uuidString),
      trustedPrincipalID: role == "observer"
        ? "registered-codex-observer" : "registered-codex-fixture")
    return try await GatewayRuntime.make(
      configuration: configuration, context: context, database: database, platform: platform,
      bundledPlugins: .init(packages: [], issues: []))
  }

  private static func serve(
    _ gateway: GatewayRuntime, root: URL, configuration: GatewayConfiguration,
    permissionRuntime: GatewayPermissionRuntime, role: String? = nil,
    transport: StdioTransport? = nil
  ) async throws {
    let control = role.map { role in
      Task {
        do {
          guard let profile = GatewayProfileID(rawValue: role)
          else { throw FixtureError.invalidArguments }
          try await waitForRevocation(
            root: root, role: role, profile: profile, permissionRuntime: permissionRuntime)
        } catch is CancellationError {
        } catch {
          let receipt = root.appendingPathComponent("revoke-\(role).json")
          let details = try JSONSerialization.data(withJSONObject: [
            "error": String(describing: error)
          ])
          try details.write(to: receipt, options: .atomic)
        }
      }
    }
    defer { control?.cancel() }
    if let transport {
      let server = await MCPRuntimeAdapter.makeGatewayServer(
        configuration: configuration, registry: gateway)
      do {
        try await server.start(transport: MCPInitializeNormalizationTransport(wrapping: transport))
        await server.waitUntilCompleted()
      } catch {
        await gateway.shutdown()
        throw error
      }
      await gateway.shutdown()
    } else {
      try await MCPRuntimeAdapter.runStdioGateway(configuration: configuration, registry: gateway)
    }
  }

  private static func owner() throws -> GatewayPermissionOwner {
    try GatewayPermissionOwner(
      context: .init(
        caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "fixture-owner"),
      validate: {})
  }

  private static func waitForRevocation(
    root: URL, role: String, profile: GatewayProfileID, permissionRuntime: GatewayPermissionRuntime
  ) async throws {
    let trigger = root.appendingPathComponent("revoke-\(role)")
    while !FileManager.default.fileExists(atPath: trigger.path) {
      try await Task.sleep(for: .milliseconds(50))
    }
    try Task.checkCancellation()
    let owner = try owner()
    let service = permissionRuntime.service
    let before = try service.view(owner: owner)
    let revoked: RevocationResult
    if role == "acceptance" {
      revoked = try service.revokePermission(
        .plugin("codex"), profileID: profile, owner: owner, expectedRevision: before.revision)
    } else {
      let identity = PluginIdentity.package("codex")
      guard let approval = before.providers.first(where: { $0.identity == identity })
      else { throw FixtureError.invalidRegistration }
      revoked = try service.revokeProvider(
        identity, owner: owner, expectedProviderRevision: approval.revision,
        expectedRevision: before.revision)
    }
    try await permissionRuntime.coordinator.reconcile()
    let after = try service.view(owner: owner)
    let disabled =
      role == "acceptance"
      ? after.profiles.first(where: { $0.id == profile })?.permissions.entries[.plugin("codex")]
        == .denied
      : after.providers.first(where: { $0.identity == .package("codex") })?.enabled == false
    guard disabled else { throw FixtureError.invalidRegistration }
    try JSONSerialization.data(withJSONObject: [
      "epoch": after.epoch?.uuidString ?? "", "before_revision": before.revision,
      "after_revision": after.revision,
      "executions": revoked.executionsToTerminate.map(\.uuidString).sorted(),
    ]).write(to: trigger.appendingPathExtension("json"), options: .atomic)
  }

  private static func registerPlugin(
    root: URL, database: GatewayDatabase, store: PluginStore,
    permissionRuntime: GatewayPermissionRuntime, configuration: GatewayConfiguration
  ) async throws {
    let source = root.appendingPathComponent("plugin", isDirectory: true)
    let package = try PluginPackage.load(at: source)
    let registered = try await store.registerDevelopment(
      at: source, expectedRevision: store.snapshot().revision)
    guard package.manifest.id == "codex", var settings = registered.settings["codex"],
      !settings.enabled
    else { throw FixtureError.invalidRegistration }

    let identity = PluginIdentity.package("codex")
    let container = try database.prepareProviderContainer(identity).sandbox
    let configFile = URL(fileURLWithPath: container.home.value, isDirectory: true)
      .appendingPathComponent("adapter.json")
    let contribution = try JSONDecoder().decode(
      PluginMCPSettings.self,
      from: Data(contentsOf: root.appendingPathComponent("contribution.json")))
    settings.mcp["app-server"] = contribution
    settings.mcp["app-server"]?.args = ["--config", configFile.path]
    _ = try await store.setSettings(settings, for: "codex", expectedRevision: registered.revision)

    let owner = try owner()
    let view = try permissionRuntime.service.view(owner: owner)
    guard let epoch = view.epoch else { throw FixtureError.missingEpoch }
    let review = try GatewayProviderReview(
      package: package, configuration: database.configurationState())
    var permissions = Permissions()
    let reviewedProjects = configuration.profileGrant(for: configuration.runtime.profileID)
      .permissions
    for id in ["primary", "other"] {
      let project = Permission.project(id)
      guard let level = reviewedProjects.entries[project] else {
        throw FixtureError.invalidRegistration
      }
      try permissions.set(level, for: project)
    }
    let approval = try permissionRuntime.service.approveProvider(
      review, permissions: permissions, fullAccess: false, owner: owner,
      expectedProviderRevision: nil, expectedRevision: view.revision, expectedEpoch: epoch)
    guard approval.enabled, approval.sourceDigest == review.sourceDigest else {
      throw FixtureError.invalidRegistration
    }
    let receipt = [
      "home": container.home.value, "cache": container.cache.value, "state": container.state.value,
      "config": configFile.path, "manifest_digest": review.sourceDigest,
      "provider_revision": String(approval.revision), "authorization_epoch": epoch.uuidString,
    ]
    print(String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self))
  }

  private static func runPeer() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["CODEX_HOME"] else { throw FixtureError.invalidPeerMessage }
    let home = URL(fileURLWithPath: path, isDirectory: true)
    let marker = home.appendingPathComponent("peer-count")
    let count =
      FileManager.default.fileExists(atPath: marker.path)
      ? Int(try String(contentsOf: marker, encoding: .utf8)) : 0
    guard let count else { throw FixtureError.invalidPeerMessage }
    try String(count + 1).write(to: marker, atomically: true, encoding: .utf8)

    func save(_ value: [String: Any], to name: String) throws {
      try JSONSerialization.data(withJSONObject: value).write(
        to: home.appendingPathComponent(name), options: .atomic)
    }
    func emit(_ value: [String: Any]) throws {
      let data = try JSONSerialization.data(withJSONObject: value)
      try FileHandle.standardOutput.write(contentsOf: data + Data([0x0A]))
    }
    let inherited = [
      "COMPUTER_MCP_HOST_CONTEXT", "COMPUTER_MCP_HOST_FD",
      "COMPUTER_MCP_HOST_READ_HANDLE", "COMPUTER_MCP_HOST_WRITE_HANDLE", "CODEX_THREAD_ID",
    ].contains { environment[$0] != nil }
    let sockets = (3..<32).contains { fd in
      var info = stat()
      return fstat(Int32(fd), &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
    }
    try save(
      [
        "pid": ProcessInfo.processInfo.processIdentifier, "count": count + 1,
        "home": environment["HOME"] ?? "", "cache": environment["XDG_CACHE_HOME"] ?? "",
        "state": environment["XDG_STATE_HOME"] ?? "", "codex_home": path,
        "inherited_host_env": inherited, "inherited_host_socket": sockets,
      ], to: "vendor.json")

    var awaiting: (callbackID: Int, requestID: Any)?
    let loaded: [String: Any] = ["data": [], "nextCursor": NSNull()]
    while let line = readLine() {
      guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      else { throw FixtureError.invalidPeerMessage }
      guard let id = request["id"] else { continue }
      switch request["method"] as? String {
      case "initialize":
        try emit([
          "id": id,
          "result": [
            "codexHome": path, "platformFamily": "unix", "platformOs": "macos",
            "userAgent": "registered-codex-fixture",
          ],
        ])
      case "thread/loaded/list":
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let edit = directory.appendingPathComponent("fixture-edit-request")
        if FileManager.default.fileExists(atPath: edit.path) {
          try "edited by the registered peer\n".write(
            to: directory.appendingPathComponent("fixture-edit.txt"), atomically: true,
            encoding: .utf8)
        }
        let queued = home.appendingPathComponent("queued.json")
        if FileManager.default.fileExists(atPath: queued.path),
          let callback = try JSONSerialization.jsonObject(with: Data(contentsOf: queued))
            as? [String: Any], let callbackID = callback["id"] as? Int
        {
          try FileManager.default.removeItem(at: queued)
          awaiting = (callbackID, id)
          try emit(callback)
        } else {
          try emit(["id": id, "result": loaded])
        }
      case nil:
        guard let pending = awaiting, id as? Int == pending.callbackID else {
          throw FixtureError.invalidPeerMessage
        }
        try save(request, to: "callback-\(pending.callbackID).json")
        awaiting = nil
        try emit(["id": pending.requestID, "result": loaded])
      default:
        try emit(["id": id, "error": ["code": -32601, "message": "Unsupported fixture method"]])
      }
    }
  }
}

private struct FixtureEpochCounter: AuthorizationEpochCounter {
  private let access: Access

  init(file: URL) { access = Access(file: file) }

  func withExclusiveAccess<Result>(
    _ body: (any AuthorizationEpochCounterAccess) throws -> Result
  ) throws -> Result {
    let fd = open(access.file.path + ".lock", O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_RDWR, 0o600)
    guard fd >= 0 else { throw AuthorizationEpochCounterError.unavailable }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw AuthorizationEpochCounterError.unavailable }
    return try body(access)
  }

  private struct Access: AuthorizationEpochCounterAccess {
    let file: URL

    func read() throws -> AuthorizationEpochWatermark? {
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      return try JSONDecoder().decode(
        AuthorizationEpochWatermark.self, from: Data(contentsOf: file))
    }

    func advance(to watermark: AuthorizationEpochWatermark) throws {
      if let previous = try read(),
        previous.databaseID != watermark.databaseID || previous.revision >= watermark.revision
      {
        throw AuthorizationEpochCounterError.nonMonotonicWrite
      }
      try JSONEncoder().encode(watermark).write(to: file, options: .atomic)
    }
  }
}

private struct FixturePolicySources: ManagedPolicyReading {
  func canonicalPolicyPath(_ path: String) throws -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  func readSources() -> [ManagedPolicySourceSnapshot] {
    ManagedPolicySourceID.allCases.map {
      .init(source: $0, location: "fixture/" + $0.rawValue, status: .absent)
    }
  }
}
