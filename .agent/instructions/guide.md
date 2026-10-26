---
description: Keep the Codex App Server adapter's protocol state local, its schemas complete, and its test runs away from the user's App Server.
---
# plugin-codex Agent Guide

## Task Route

- Use `Documentation/Reference/Release.md` for packaged runtime acceptance
  through the installed host. When changing `scripts/check-host.py`, run it with
  `--help` and run its Python unit tests.
- Before handoff, run strict swift-format lint, `swift build`, `swift test`,
  the schema drift checks and an isolated standard MCP client.

## Adapter

- Keep Codex protocol parsing, adapter state and MCP projection in this
  repository. Never connect to, replace or stop an existing user App Server for
  testing.
- Preserve every schema field, including experimental and unknown fields. A
  schema entry proves declaration, not executable support or authorization.
  Use actual version-specific CLI exports, keep them distinct from the client
  SDK snapshot, and keep generated schema provenance.
- Use Swift Testing. Logs never write to the protocol stdout.
