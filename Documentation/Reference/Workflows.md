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

## Native coding configuration

Exec start accepts `prompt` and optional `model` and `options`; resume accepts
`upstream_session_id` and optional `prompt`, `model` and `options`.
Exec events/result/cancel use `session_id`.

Exec uses existing Codex configuration and authentication, including provider,
MCP servers, Skills and hooks. Omitted sandbox and approval values inherit native
configuration, including Full Access. Host admission is a separate decision.
The `options` object supports native `cwd`, `sandbox`, `approval_policy`,
`profile`, `config`, `images`, `add_dirs`, `enable`, `disable`, `search`,
`oss`, `dangerously_bypass_approvals_and_sandbox`, `ephemeral`,
`ignore_user_config`, `skip_git_repo_check`, `stdin`, `output_schema` and
`output_last_message`. Relative paths use the explicit `cwd` or initial
directory. Unknown options and unsupported enum values fail before launch.
Native CLI semantics still apply: headless Exec does not become an interactive
App Server approval session.

App Server's `codex.app.methods.call` preserves native request and response
fields. Use `config/read`, `configRequirements/read` and `model/list` to
inspect vendor configuration and available models. Thread and turn parameters
may explicitly select native sandbox, approval policy and directory; unsupported
vendor inputs return a vendor error, never a silent downgrade.

The configured executable can be an absolute path, a path relative to the
workspace, or a name on the child process PATH. Resolution and launch share the
same environment. Missing programs fail explicitly without loading shell profiles.

Exec event reads acceptExec event reads accept `after_cursor` (default 0) and `max_results`
(default 100, range 1–1000). Bounded event history reports missed rows; clients
must not treat an evicted cursor as a complete history.

Successful results preserve the existing JSON text and
`structuredContent.result` envelope. Tool execution and argument errors return
`isError: true`; unknown tools are MCP protocol errors. Inspect actual catalog
schemas for the complete input contract.

Host permissions are checked on each invocation, including callbacks.
MCP disconnection shuts down each owned provider. Finish or cancel active work
before changing the plugin registration. Each runtime owns its transport and process teardown; the MCP transport itself
does not establish an OS sandbox.

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

Diagnostics read adapter state without starting Codex.
`host_diagnostics_available: false` means `recent_tool_audits` is unavailable,
not that no audit history exists. `codex_configuration` reports explicit adapter
overrides and inheritance, not a guessed effective permission. A host read
failure is an error, not an empty snapshot.

## Native approvals and cancellation

Read the pending approval's native method and details, then respond with its
official response object. For example, a command approval accepts:

```json
{"approval_id":"<returned-id>","response":{"decision":"acceptForSession"}}
```

Use the response schema for that method: permission approvals carry
`permissions` and `scope`; command and file approvals carry their native
`decision` union. Decline, cancel and supported policy amendments retain native
meaning. Invalid responses are rejected before consuming the request; resolved,
expired or disconnected requests cannot be reused.

Exec cancellation first reports `cancellation_requested`. Query the same session
until terminal and inspect `cleanup_confirmed`; delivery of cancellation alone
does not prove the process stopped. A late successful completion remains a
completion with cancellation history. Results expose `output_capture`, including
dropped stdout/stderr bytes. Capture-budget failure is explicit; preserved output
must not be treated as complete. Adapter text truncation and missed event cursors
are separate, visible limits.

## Subject-bound adapter storage

Host-launched adapter records are kept under `subjects/<scope-digest>/codex.sqlite`
inside the configured state directory. The digest binds the verified subject,
profile and workspace, so reconnecting with the same credential keeps the same
records. A shared thread-owner index prevents another subject from claiming or
reading a known adapter-bound native thread, including through history queries.
Claims occur atomically before dispatch; an uncertain result keeps its affinity.
This is adapter domain ownership, not a replacement for Codex's native sandbox.

An existing root `codex.sqlite` is unbound history. Diagnostics report
`state_storage.unbound_history_available` without assigning it to the current
subject. Keep the source intact. A local operator must review the source and
destination subject before using the offline migration workflow against the
chosen destination database; do not import live records or treat unknown
ownership as permission to resume execution. Native read-only history continues
to use Codex's configured home and does not create execution ownership.
