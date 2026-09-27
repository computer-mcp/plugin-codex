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
| Exec | `codex.exec.start` / `resume`; inspect `list` / `events` / `result`; `cancel` while running; `release` after cleanup |

## Native coding configuration

Exec start accepts `prompt` and optional `model` and `options`; resume accepts
`upstream_session_id` and optional `prompt`, `model` and `options`.
Exec events/result/cancel/release use `session_id`.

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

Use `codex.app.native.<method>` for each adopted stable request, replacing `/`
with `.` in the native method name. Pass native arguments under `params`;
parameterless methods take an empty tool-argument object. The tool schema
includes every native parameter and its referenced definitions. SDK request
types validate required fields and known value shapes; original extension
fields pass through. Responses retain the usual `structuredContent.result`
envelope and notifications appear in `codex.app.events.read`. Signed 64-bit
JSON integers remain exact through MCP and App Server transport; integers
outside that range fail explicitly.

`codex.app.methods.describe` returns a request's full parameter schema, risk
and stability channel. Experimental requests use `codex.app.methods.call`
with `experimental: true` and require the runtime's `experimental_api` setting.
SDK-excluded lifecycle/internal methods are not executable through this path.
Native account-token refresh and device-attestation callbacks require an
external credential or attestation owner; the adapter rejects those callbacks
explicitly instead of inventing credentials or proof.

Native turn starts and other thread execution paths check existing worktree
leases. Use the higher-level leased-turn workflow when a lease is active.
Interactive command/process, filesystem-watch and event-stream handles belong
to the connection that created them. A replacement connection cannot operate
an old handle. A failed stop or uncertain request is not proof of cleanup.
Runtime status reports `cleanup-pending` when owned process-group cleanup is
unconfirmed; new connection admission remains closed until a later check
confirms that group is gone.

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

## Reading long threads

`codex.app.thread.read` returns metadata without turns by default. Use
`codex.app.thread.turns.list` with `thread_id` to read turn metadata (default
20 turns, newest first, without items), then `codex.app.thread.items.list`
to read items (default 50, newest first). Both accept `limit` from 1 to 100,
`cursor` and `sort_direction`. Item pages optionally accept `turn_id`; turn
pages accept the native `items_view` values `notLoaded`, `summary` or `full`.

For example, read one turn's items with
`{"thread_id":"<thread>","turn_id":"<turn>","limit":10}`. The result's
`data` holds the page and `nextCursor` is the native continuation. Pass that
cursor unchanged on the next request with the same thread, turn filter and
sort direction. A cursor is not authorization: every request still checks
thread ownership. Cursors follow the installed vendor's history semantics;
they do not freeze an actively changing thread.

Successful pages retain their complete fields and continuation. If a page
exceeds the adapter output budget, `codex.app.history_page_too_large` reports
an error instead of returning a truncated page. Keep the input cursor and
retry with a smaller limit. For turns, use `items_view: "notLoaded"` and load
items separately. A single oversized item can still exceed the budget;
`codex.app.thread.recent` offers a bounded persisted summary with visible
read/output limits and a snapshot-bound `next_before_cursor`.

Explicit `include_turns: true` on `thread.read` retains full-history behavior,
including its timeout, transport and output limits. Inspection does not require
`thread.reclaim`: reclaim acquires a writer and remains a separate operation.
`thread.reclaim` and `thread.fork` also omit turns from their response by
default, using native `excludeTurns: true`; their `include_turns: true` option
requests full history. Writer conflicts retain their native ownership meaning
and are not repaired by reconnecting or force-stopping another client.
Native tools also expose `thread/read`, `thread/turns/list` and
`thread/items/list` with the SDK's complete schemas and parameter names.

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

Completed Exec results remain readable until explicit `codex.exec.release` or
capacity eviction. Release requires both a settled result and confirmed native
cleanup; it rejects running, still-settling and uncertain-cleanup sessions.
Releasing removes the adapter session, its result and buffered events. It does
not delete native conversation history or its workspace ownership record.
Result and event reads are non-destructive. Capacity eviction removes only
settled results with confirmed cleanup; uncertain work continues to occupy a slot.

Exec shutdown also covers native requests still starting. It refuses new
start/resume calls before claiming thread ownership and waits for admitted
startup and owned process cleanup outcomes.
If a cancelled startup supplies a late process handle, the adapter cleans that
handle before returning. Cancellation of a start request after it has returned
does not replace the explicit session cancel operation.

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
