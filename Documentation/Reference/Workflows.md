# Execution workflows

Enable providers through the local configuration described in the
[root manual](../../README.md). Session and call IDs are opaque handles returned
by the runtime; do not substitute upstream thread IDs for local handles.

| Provider | Workflow |
| --- | --- |
| App Server | `codex.app.thread.start` / `reclaim` → `turn.start` / `steer` / `interrupt` → `thread.release` |
| Native Goal | `codex.app.goal.get` / `set` / `clear`, always bound to `thread_id` |
| App Server approval | `codex.app.approvals.list` / `read` → `respond` with the exact approval ID |
| App Server input and events | `codex.app.requests.list` / `respond`; `codex.app.events.read` |
| Acceptance and writer ownership | `codex.run.*` and `codex.worktree.leases.*`, with durable revisions |
| Managed worktrees | `codex.worktree.provision.plan` / `perform`, `managed.list` / `read`, and `remove.plan` / `perform`; mutations require the host workspace service |
| Operational diagnostics | `codex.diagnostics.snapshot`, with optional bounded `limit` |
| Exec | `codex.exec.start` or `resume` → `list` / `events` / `result` → `cancel` when required |
| Codex MCP | `codex.mcp.status` / `tools.list` → `run` / `reply` → `calls.list` / `events` / `result` |
| Codex MCP approval | `codex.mcp.approvals.list` → `codex.mcp.approval.respond` for that call and approval ID |

Exec start accepts `prompt` and optional `model`; resume accepts
`upstream_session_id` and optional `prompt`. Exec events/result/cancel use
`session_id`. MCP run accepts `prompt` and optional `model`; reply accepts
`thread_id` and `prompt`. MCP events/result/approvals/cancel use `call_id`.
Approval replies additionally require `approval_id` and `decision`.

Both event tools accept `after_cursor` (default 0) and `max_results`
(default 100, range 1–1000). Bounded event history reports missed rows; clients
must not treat an evicted cursor as a complete history.

Successful results preserve the existing JSON text and
`structuredContent.result` envelope. Tool execution and argument errors return
`isError: true`; unknown tools are MCP protocol errors. Inspect actual catalog
schemas for the complete input contract.

A host read-only context rejects mutating operations before runtime dispatch.
MCP disconnection shuts down each owned provider. Finish or cancel active work
before changing the plugin registration. Transport/process teardown guarantees
are those of the corresponding existing runtime, not a claim of an OS sandbox.

App Server requires its configured state directory. Releasing a thread
preflights active turns and pending requests, verifies loaded state after
unsubscribe and records release without clearing its persisted Goal. Other
official clients' processes are not stopped. An uncoordinated live owner must
be addressed through its owning connection.

If Codex still reports the target loaded and the runtime also owns another
thread, graceful release returns an error and preserves the runtime. Explicit
`force-computer-mcp-owned-runtime-only` stops that entire owned runtime, so
review every affected thread first. When release reaps an empty runtime,
disconnect and start a new adapter connection before reclaiming a persisted
thread. Keep both the adapter state directory and vendor `CODEX_HOME` to retain
their respective records and Goals.

RPC execution metadata uses `codex.app.methods.*`; version-specific schema
inspection uses `codex.protocol.methods.*`. Inspecting a schema does not
enable that RPC or start a vendor process.

## Workspace and diagnostic availability

Managed-worktree plans are bound to the source workspace and a live parent
lease. A child lease must be released through its own workspace-bound connection.
Removal requires a fresh reviewed plan, a clean owned worktree, no active lease
or live runtime, and host authorization. Removal preserves the branch.

An explicitly enabled host-services connection supplies registration, removal
authorization and diagnostics. Without that connection, `provision.perform` and
`remove.perform` fail before Git mutation; planning and receipt inspection remain
available. See [host integration](HostIntegration.md) for exact scope and
metadata-only recovery after a partially completed removal.

Diagnostics read the adapter's persisted and live state without starting Codex.
`host_diagnostics_available: false` means host audit and grant information is
unavailable: `recent_tool_audits`, grant counts, grant records and effective-next-start
permission are null, not evidence of no audit history or no grant. The configured
sandbox is still reported. A host read failure is an error, not an empty snapshot.
