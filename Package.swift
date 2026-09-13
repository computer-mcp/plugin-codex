// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "codex-plugin",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "codex-mcp-adapter", targets: ["CodexMCPAdapter"])],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    .package(url: "https://github.com/swift-library/swift-codex.git", exact: "0.1.2"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "0.4.0"),
  ],
  targets: [
    .target(
      name: "CodexAdapter",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "CodexAppServerClient", package: "swift-codex"),
        .product(name: "CodexAppServerProtocol", package: "swift-codex"),
        .product(name: "CodexAppServerRuntime", package: "swift-codex"),
        .product(name: "CodexExec", package: "swift-codex"),
        .product(name: "CodexMCP", package: "swift-codex"),
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      resources: [.copy("Resources/Protocol")]),
    .executableTarget(
      name: "CodexMCPAdapter",
      dependencies: [
        "CodexAdapter", .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(name: "CodexAdapterTests", dependencies: ["CodexAdapter"]),
    .testTarget(name: "CodexMCPAdapterTests", dependencies: ["CodexMCPAdapter"]),
  ])
