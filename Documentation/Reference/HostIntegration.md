# Host integration

Set `hostServices: true` in the Computer MCP host's local settings for this
plugin's `app-server` MCP contribution. The App exposes the same choice as
**Allow scoped host services**. It is separate from enabling the plugin,
selecting its tools and granting a profile access to the workspace. A plugin
manifest cannot turn it on. A direct stdio registration uses `host_services`.

The host starts the adapter with a connected Unix descriptor and immutable
scope. `CodexHostMCPClient` uses standard MCP to call the host; it does not
open the control socket, read the host database or start another service.
Standalone launches without that descriptor retain ordinary configured Codex
execution but cannot perform host-owned registration or grant operations.

`codex.app.ownership.reconcile.perform` is a local-control operation. A
remote-bound adapter omits it from its MCP tool catalog and rejects attempts
to invoke it directly. The host-established caller scope determines visibility.

## Approval and execution

Dynamic vendor tools are preflighted against the current host scope, then
executed with a fresh check. Destructive operations retain host-issued
prepare/commit tickets. A changed classification requires a new approval rather
than converting an earlier read-only decision into a mutation.

Temporary full access consumes only a matching, already locally approved host
grant. The host supplies time and identity and matches the active outer start
request. Claims cannot be replayed by another runtime or later invocation.
Pending, expired or revoked grants do not confer full access. Next-turn grants
are single-use. Disconnect invalidates this connection's owned claims/grants;
failed cleanup is not treated as confirmed retirement. The adapter cannot issue
local approval, mint grants, or use a dynamic `host.*` tool to bypass the boundary.

## Managed workspaces

The host supplies the managed root beside its file-backed state. The plugin
plans and executes Git operations; the host validates exact repository/path
identity before transactionally adding its registration and profile grant.
The plugin's database holds the plan, lease and lifecycle receipt, not host
workspace authority. A new child connection must resolve the newly registered
workspace before releasing its child lease.

Use the existing `provision.plan` / `provision.perform` and `remove.plan` /
`remove.perform` workflows. Removal requires a released lease, no live owner,
a reviewed clean worktree and an executing host ticket. Independent registration
edits or another profile's grants are not silently deleted. Branches survive
ordinary removal.

When Git has already removed the directory but registration cleanup fails,
`managed.read` reports `removing` with the error. Run `remove.plan` again,
review the current receipt, and obtain a new host prepare/commit ticket for
`remove.perform` with its new revision. Both sides verify absence of the path
and Git registration before metadata-only cleanup. It never repeats the Git
delete, and it refuses a new path that appeared at the old location.

When a failed provision cannot confirm host rollback, its failed receipt reports
incomplete recovery and preserves remaining worktree/branch content. Inspect
both domain and host records before manual reconciliation. An uncertain result,
plugin uninstall, or failed test does not authorize deleting independently
changed content.

## Diagnostics

`codex.diagnostics.snapshot` combines adapter state with host records only when
this callback service is available. The host filters records by workspace,
profile, caller and exact connection before limiting the result. It exposes
receipt IDs and digests rather than command bodies or secrets. In-flight
activation handles are redacted. The configured sandbox and actual availability
remain distinct: unknown host data is never reported as an empty grant set.

The host permits 1–1000 requested records and bounds the complete service result.
Reduce `limit` when the response would exceed the byte limit. Inspection does not
start Codex or a model. Real vendor/model authentication and GUI permissions are
separate checks from the host callback protocol.
