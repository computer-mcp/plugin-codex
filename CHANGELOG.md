# Changelog

## 0.3.0 — 2026-09-29

- Projects the stable Codex App Server methods from swift-codex 0.4.1 with
  typed parameter schemas; experimental methods keep their metadata.
- Thread reads default to metadata; history uses bounded turn and item pages
  with native cursors.
- Runtime ownership covers active invocations, detached native work and writer
  handoff; cancellation and release report confirmed and uncertain cleanup
  separately.
- Adds scoped host services and native Windows x86_64 packages. Windows needs
  Microsoft's Visual C++ v14 x64 runtime. macOS arm64 remains supported.

## 0.2.1 — 2026-09-22

- Cancelling an in-flight App Server request retires its owned generation, so
  the next request starts a fresh one.
- Shutdown uses an independent grace-period timer, so cleanup waits stay
  bounded.

## 0.2.0 — 2026-09-21

- Preserves native Codex configuration, sandbox and Full Access choices,
  approvals and experimental protocol fields across App Server and Exec.
- Binds persisted state, thread ownership and managed worktree leases to the
  verified caller.
- Uses swift-codex 0.2.2 and the Codex 0.154.0 App Server schema baseline.

## 0.1.1 — 2026-09-13

- Release archives keep the plugin manifest byte for byte, which fixes
  installation from GitHub.
- Packaging checks the built adapter against the architectures the manifest
  declares.

## 0.1.0 — 2026-09-13

- First release: App Server, Exec and Codex MCP capabilities through swift-codex
  as standard MCP, for macOS arm64.
