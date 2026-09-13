# Codex Plugin

This independent Swift package projects Codex execution through standard MCP.
It reuses Computer MCP's existing execution implementations and swift-codex.
The host owns registration, caller grants, workspace authorization and audit.
The plugin does not link Computer MCP Core or install the vendor Codex binary.

## Current capabilities

The configured server exposes the existing six `codex.exec.*` tools and ten
`codex.mcp.*` tools, preserving their names, parameters, session identifiers,
bounded events, result envelopes and independent lifecycles.

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
  "exec_enabled": true,
  "mcp_enabled": true,
  "sandbox": "workspace-write",
  "approval_policy": "never"
}
```

Launch with `codex-mcp-adapter --config /absolute/path/codex.json`.
For App Server execution, set `app_server_enabled` to `true` and supply
`--state-directory /absolute/path/adapter-state`. This directory holds the
adapter's `codex.sqlite` records; it is separate from the vendor's `CODEX_HOME`
and the Computer MCP host database. Keep it across restarts and updates.
All existing configuration defaults and validation limits remain in
`CodexConfig`; the configuration file is bounded to 64 KiB. No executable
is started for catalog discovery. Choose a policy appropriate to the intended
workspace before executing tools.

Computer MCP supplies immutable workspace/read-only launch metadata. A
standalone MCP client uses its process working directory and the local
configuration. Tool arguments cannot override those launch settings.
`CODEX_HOME` remains the vendor's environment setting; do not put credentials
in arguments. Host metadata and parent session identity are not propagated to
the vendor process. Neither launch mode grants host administration.

A host that explicitly enables `hostServices` supplies the scoped MCP callback
connection for dynamic tools, existing grant consumption, managed-workspace
registration and diagnostics. See [host integration](Documentation/Reference/HostIntegration.md)
for approval ownership, recovery and availability boundaries.

See [workflows](Documentation/Reference/Workflows.md),
[package architecture](Documentation/Architecture/Package.md), and
[installation](Documentation/Reference/Installation.md).
The [documentation index](Documentation/README.md) and
[contributor guide](CONTRIBUTING.md) cover the repository's supporting material.

## Protocol inputs

The bundled inventory was exported by Codex 0.153.4. Reproduce it using that
version's `app-server generate-json-schema --out EXPORT_ROOT/stable` and
`app-server generate-json-schema --experimental --out EXPORT_ROOT/experimental`.
Run `node Scripts/import-schema.mjs EXPORT_ROOT 0.153.4`, or add `--check`
to verify byte-for-byte drift. Do not edit generated JSON by hand.
Schema receipt integrity is not publisher signature verification.

`codex-mcp-adapter compare-schema BASELINE_JSON_DIRECTORY CURRENT_JSON_DIRECTORY`
reports all four message directions, source digests, method and schema changes,
JSON Pointers, and required-parameter differences. It does not run Codex.

The installed schema and swift-codex's pinned schema are separate version
authorities. Declaration coverage does not establish runtime support.

### Offline domain-state migration

`codex-mcp-adapter migrate-state` previews a bounded, read-only source snapshot
and applies only its reviewed Codex domain records to adapter-owned persistence.
It preserves host authorization ownership and never launches a model. See
[State migration](Documentation/Reference/StateMigration.md) for snapshot,
conflict, atomicity and cutover boundaries.
