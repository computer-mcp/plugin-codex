# Changelog

## Unreleased

### Added

- Public-host runtime acceptance for the packaged adapter and installed Codex,
  including native permissions, lifecycle recovery, thread handoff, authenticated
  model execution and exact owned-process cleanup.
- Runtime operations, diagnostics, ownership and troubleshooting guidance in the
  plugin manual.

### Changed

- Adopt swift-codex 0.5.1 and MCP SDK fork 0.13.2-computer-mcp.1, preserving
  existing runtime behavior and refreshing the SDK-derived method inventory.
- Classify native plugin reconciliation as destructive, Bedrock discovery as
  read-only, and Bedrock setup as an external write.
- Ship swift-codex's Apache-2.0 WITH Swift-exception license and notices.
- Adapter databases initialize from one complete schema. Unknown migration
  histories fail explicitly and require a new state directory.

### Removed

- Windows support; the plugin ships only for macOS.
- Offline domain-state migration command and import workflow.

### Fixed

- Undecodable MCP tool arguments, including out-of-range integers, receive
  JSON-RPC invalid-params errors correlated with the request ID.
- Valid upstream Exec session identifiers are accepted by release builds.
