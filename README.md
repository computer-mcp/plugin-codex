# Codex Plugin

This independent Swift package projects Codex execution through standard MCP.
It reuses Computer MCP's existing execution implementations and swift-codex.
The host owns registration, caller grants, workspace authorization and audit.
The plugin does not link Computer MCP Core or install the vendor Codex binary.

## Current capabilities

The configured server exposes six `codex.exec.*` tools for sessions, bounded
events, results and cancellation, alongside the App Server tools below.

`codex.protocol.methods.list` and `codex.protocol.methods.describe` inspect bundled,
version-specific protocol declarations. Schema presence does not prove
execution support or authorization.

App Server exposes thread/turn and Goal operations, approvals, user input,
events, runtime ownership and release, recent-thread inspection, acceptance
runs, worktree leases and operational diagnostics. Managed-worktree planning
and receipts use the adapter's database; provisioning and removal require a
connected host workspace service. `codex.app.methods.list` and `describe` describe its
callable RPC surface; `codex.app.methods.call` uses the same runtime validation.

## Build and run

Building requires macOS 14 or newer and Swift 6.2 or newer.
Run `swift build` and `swift test`. Launch
`.build/debug/codex-mcp-adapter` through an MCP stdio client, never as an
unbounded unattended shell command. `--help` prints usage without serving.

Without arguments the server exposes only the two protocol inspection tools.
To enable the execution providers, save the existing Codex configuration fields
as a local JSON file:

```json
{
  "enabled": true,
  "executable": "/absolute/path/to/codex",
  "app_server_enabled": false,
  "exec_enabled": true
}
```

Launch with `codex-mcp-adapter --config /absolute/path/codex.json`.
For App Server execution, set `app_server_enabled` to `true` and supply
`--state-directory /absolute/path/adapter-state`. This directory holds the
adapter's `codex.sqlite` records; it is separate from the vendor's `CODEX_HOME`
and the Computer MCP host database. Host-bound Exec also requires this directory
for shared native thread ownership. Keep it across restarts and updates.
The configuration file is bounded to 64 KiB. No executable is started for
catalog discovery. Omitted sandbox and approval settings follow native Codex
configuration, including a user-selected Full Access default. Optional adapter
settings and explicit tool parameters are native overrides, not host grants.

Computer MCP supplies the initial directory and stable authorization subject.
The host admits each invocation using its current permissions; Codex controls
its own sandbox and approvals. Explicit native directories and Full Access
selections are preserved. The initial directory is task ownership metadata,
not an operating-system sandbox. Standalone clients use their process working
directory as the initial directory.
`CODEX_HOME` remains the vendor's environment setting; do not put credentials
in arguments. Host metadata and parent session identity are not propagated to
the vendor process. Neither launch mode grants host administration.

A host that explicitly enables `hostServices` supplies the scoped MCP callback
connection for dynamic tools, managed-workspace
registration and diagnostics. See [host integration](Documentation/Reference/HostIntegration.md)
for approval ownership, recovery and availability boundaries.

See [workflows](Documentation/Reference/Workflows.md),
[package architecture](Documentation/Architecture/Package.md), and
[installation](Documentation/Reference/Installation.md).
The [documentation index](Documentation/README.md) and
[contributor guide](CONTRIBUTING.md) cover the repository's supporting material.

## Protocol inputs

The bundled inventory was exported by Codex 0.154.0. Reproduce it using that
version's `app-server generate-json-schema --out EXPORT_ROOT/stable` and
`app-server generate-json-schema --experimental --out EXPORT_ROOT/experimental`.
Run `node Scripts/import-schema.mjs EXPORT_ROOT 0.154.0`, or add `--check`
to verify byte-for-byte drift. Do not edit generated JSON by hand.
Schema receipt integrity is not publisher signature verification.

`codex-mcp-adapter compare-schema BASELINE_JSON_DIRECTORY CURRENT_JSON_DIRECTORY`
reports all four message directions, source digests, method and schema changes,
JSON Pointers, and required-parameter differences. It does not run Codex.

The adapter and swift-codex use the same vendor schema baseline. The installed
Codex executable can differ; declaration coverage does not establish runtime
support. Unsupported vendor methods fail explicitly.

### Offline domain-state migration

`codex-mcp-adapter migrate-state` previews a bounded, read-only source snapshot
and applies only its reviewed Codex domain records to adapter-owned persistence.
It preserves host authorization ownership and never launches a model. See
[State migration](Documentation/Reference/StateMigration.md) for snapshot,
conflict, atomicity and cutover boundaries.
