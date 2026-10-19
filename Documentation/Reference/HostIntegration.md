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
execution but cannot perform host-owned registration operations.

`codex.app.ownership.reconcile.perform` is a local-control operation. A
remote-bound adapter omits it from its MCP tool catalog and rejects attempts
to invoke it directly. The host-established caller scope determines visibility.

## Approval and execution

Dynamic vendor tools are preflighted against the current host scope, then
executed with a fresh check. Destructive operations retain host-issued
prepare/commit tickets. A changed classification requires a new approval rather
than converting an earlier read-only decision into a mutation.

Native Codex Full Access follows the user's Codex configuration or explicit
native request. The host decides whether the caller may invoke Codex; it does
not replace Codex's sandbox or approval policy. Codex callbacks into host tools
remain subject to current host authorization and confirmation.

Execution tool metadata declares `io.github.computer-mcp/risk`. Starting or
continuing a model task, answering approvals or interactive requests, and
native lifecycle operations that can invoke configured command hooks declare
`full-shell`. This includes thread startup/resume/fork, turn steering, manual
compaction, archive/delete and turn interruption. Setting an active Goal,
injecting model-visible history, releasing an elicitation hold, queued and
realtime inputs, and native execution-policy updates use the same floor because
they can start or steer continued work. Explicit native sandbox
settings do not lower the floor: the host does not enforce a vendor sandbox.
The generic `codex.app.methods.call` also declares `full-shell` because its
selected method can execute arbitrary commands. Hosts use these declarations as a
minimum risk, never to reduce a configured restriction or grant access.
`codex.app.methods.list` provides the same per-method classification for
configuration review. MCP annotations remain advisory.

The three private host-service consumers also declare
`io.github.computer-mcp/host-action`: diagnostics uses `diagnostics.snapshot`,
provisioning uses `workspaces.provision`, and removal uses `workspaces.remove`.
The host binds the recognized effect to the admitted invocation and operation
ticket together with the exact arguments. The declaration grants no authority;
the host enforces its minimum risk and rejects a changed effect before dispatch.
Released hosts that recognize the original Codex method names remain compatible.
Codex's persisted worktree IDs retain their existing identity on either host.

Metadata/history/event inspection declares `read-only`. Narrow filesystem and
metadata mutations retain their effect classification. Exec cancellation and
native process termination declare `destructive`; they retire owned work rather
than submit new model input. Native turn interruption differs because Codex can
run an Interrupt command hook. A host emergency-revocation action is a separate
host-owned control, not a promise that a vendor cancellation RPC has no hooks.

Native approval responses use official response objects, including session
scope, amendments, refusal and cancellation. Responses bind to their original
SDK server request and can be consumed only once. Host destructive operations
use explicit `operations.prepare`, local confirmation and `operations.commit`;
the adapter never manufactures approval by automatically consuming a ticket.

## Managed workspaces

The host supplies the managed root beside its file-backed state. The plugin
plans and executes Git operations; the host validates exact repository/path
identity before transactionally adding its registration and profile grant.
The plugin's database holds the plan, lease and lifecycle receipt, not host
workspace authority. Each receipt binds the verified principal, profile and
source workspace; channel names are audit metadata. Unbound historical receipts
remain inspectable but cannot authorize mutations. A new child connection must resolve the newly registered
workspace before releasing its child lease. Lease revisions are shared across
that subject's profile-bound workspace connections and survive adapter restart;
the source observes the child's release before approving removal. Lease tools
cannot read or mutate a different workspace's lease, and unrelated workspaces
cannot claim managed parent lineage.

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
verified subject and profile before limiting the result. Connection and channel
identifiers remain audit metadata, not new authorization subjects. It exposes
receipt IDs and digests rather than command bodies or secrets. Native configuration overrides and actual resolved configuration remain
distinct. Use `config/read` through `codex.app.methods.call` for the vendor
configuration; diagnostics do not infer effective Full Access from host grants.

The host permits 1–1000 requested records and bounds the complete service result.
Reduce `limit` when the response would exceed the byte limit. Inspection does not
start Codex or a model. Real vendor/model authentication and GUI permissions are
separate checks from the host callback protocol.

Use the host's generic tool command with the exported name. The examples assume
an empty MCP registration prefix; prepend the configured prefix when present.
IDs come from the registered workspace and returned native thread:

```sh
computer-mcp tools call codex.app.handoff.diagnose --arguments-json \
  '{"workspace_id":"<workspace-id>","thread_id":"<thread-id>","observed_error":"<message from the other client>"}'
computer-mcp tools call codex.diagnostics.snapshot --arguments-json \
  '{"workspace_id":"<workspace-id>","limit":100}'
computer-mcp tools call codex.app.thread.release --arguments-json \
  '{"workspace_id":"<workspace-id>","thread_id":"<thread-id>"}'
computer-mcp tools call codex.app.thread.recent --arguments-json \
  '{"workspace_id":"<workspace-id>","thread_id":"<thread-id>"}'
```

When calling indirectly with `mcp.tools.call`, put `workspace_id` beside
`server`, `tool` and `arguments`; only native plugin arguments go inside
`arguments`. Native names and exported host names need not be identical.

The handoff diagnosis distinguishes these classifications:

| Classification | Operator action |
| --- | --- |
| `computer_mcp_owned` | Inspect the exact reported runtime and resolve pending approval/input. Release the thread; stop the exact runtime only when all its work should end. |
| `released_persisted` | No live adapter writer is reported. Open the persisted thread in the intended client. |
| `persisted_or_external` | No live adapter owner is verified. Reclaim only when the adapter should deliberately become the writer. |
| `external_writer_or_unfinished_watchdog` | Review stale receipts and allow bounded owned-process shutdown to finish. An external owner is inferred, never signalled. |

A successful unsubscribe alone does not prove release. Require the final
`released_persisted` classification, `externally_claimable: true` and
`computer_mcp_writer_ownership_remaining: false`. If a loaded receipt remains
once its exact runtime and process are gone, preview ownership reconciliation
and apply the reviewed digest through local control. A writer conflict in
another client must be resolved through that client's controls. Never use
`killall` or delete session files to bypass ownership.

### Execution or permissions fail

Inspect App Server with `codex.app.status` and Exec with `codex.exec.list`
independently. The host's provider/package doctor checks availability; it does
not prove model authentication. Verify the selected executable and native
configuration, including personal provider, MCP, Skills and hooks settings.
A slow or broken personal integration can delay startup. Diagnose credentials
in Codex's own store rather than copying them into host configuration.
An unavailable custom program fails explicitly; it never falls back to a
different executable. For a non-Git initial directory, select Exec's native
`options.skip_git_repo_check` explicitly.

Thread and turn responses report applied native permissions. Omitted settings
inherit Codex configuration; an explicit override can change the sandbox or
approval policy. A host profile name is not evidence of effective Full Access.
A host denial prevents invocation; it never silently chooses a narrower native
mode. Full Access cannot grant host callbacks extra capabilities, workspace
access, tickets or macOS privacy permissions.

The installed vendor must support the requested stable or explicitly enabled
experimental API. Incompatible methods fail explicitly. App Server failure
does not silently switch execution to Exec.

### Slow history or directory requests

Use the bounded history pages in [Workflows](Workflows.md#reading-long-threads),
or `thread.recent` for a persisted tail. Its `bounds` report page and Goal-scan
I/O, output bytes, elapsed scan and cooperative budget exhaustion;
`full_history_loaded` is false. Follow `next_before_cursor` only for older
context and restart from the newest page if the rollout identity changed.

`app/list` has its own configured deadline and uses one connection generation;
other calls use the normal end-to-end request budget. A directory HTTP 403
reported by `codex.app.request_failed` is an upstream response, not evidence
that local workspace content or the host was classified as hostile. It remains
a failed acceptance check. Inspect network and account availability separately.

If Safari or interactive Codex works but the adapter's directory request fails,
check fixed macOS HTTP/HTTPS/SOCKS proxy settings and restart the owned adapter
connection. Explicit inherited proxy values are preserved; otherwise the adapter
maps fixed system proxies to conventional uppercase/lowercase child variables
with loopback bypass. Derived proxy values are not persisted or logged. PAC
scripts are not evaluated.
