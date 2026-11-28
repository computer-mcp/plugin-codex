# Host integration

Set `hostServices: true` in the Computer MCP host's local settings for this
plugin's `app-server` MCP contribution. The App exposes the same choice as
**Allow scoped host services**. It is separate from enabling the plugin,
selecting its tools and granting a profile access to the project. A plugin
manifest cannot turn it on. A direct stdio registration uses `host_services`.

The host starts the adapter with a connected Unix descriptor and immutable
scope. `CodexHostMCPClient` uses standard MCP to call the host; it does not
open the control socket, read the host database or start another service.
Standalone launches without that descriptor retain ordinary configured Codex
execution but cannot perform host-owned worktree operations.

`codex.app.ownership.reconcile.perform` is a local-control operation. A
remote-bound adapter omits it from its MCP tool catalog and rejects attempts
to invoke it directly. The host-established caller scope determines visibility.

## Approval and execution

Dynamic vendor tools are preflighted against the current host scope, then
executed with a fresh check. Host callbacks carry the selected `project_id`.
A changed classification requires a fresh approval.

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

The package contribution and both MCP initialization responses identify the
`projects-v1` contract. The adapter also checks the host launch context before
sending lifecycle requests. A missing or mismatched contract produces
`host.unsupported_contract`. Update Computer MCP and the Codex plugin together
and restart the provider.

Tool metadata declares `io.github.computer-mcp/host-action` for diagnostics
(`diagnostics.snapshot`) and the worktree effects (`projects.provision`,
`projects.list`, `projects.remove`). The host binds each effect to the admitted
invocation and supplies the operation ID for a mutation. Narrow project
mutations declare `project-write`. Native Codex sandbox values keep their vendor
meaning.

Metadata/history/event inspection declares `read-only`. Narrow filesystem and
metadata mutations retain their effect classification. Exec cancellation and
native process termination declare `destructive`; they retire owned work rather
than submit new model input. Native turn interruption differs because Codex can
run an Interrupt command hook. A host emergency-revocation action is a separate
host-owned control, not a promise that a vendor cancellation RPC has no hooks.

Native approval responses bind to the original SDK server request and can be
consumed once. The host applies its own authorization and confirmation to
callbacks.

### Codex network access

The package requests outbound access to `api.openai.com` and `chatgpt.com` for
the default Codex model endpoints and `auth.openai.com` for OpenAI sign-in.
The custom list uses exact hostnames and excludes the Host's trusted-host list.
Host Full access is off by default.

The list is the maximum the package requests for sandboxed execution. At
enablement the owner reviews the declaration and can select less access within
the Host's policy limits. An update that adds network access requires fresh
owner approval before the added access applies. For an enterprise deployment
with a different provider or issuer, verify its endpoints against that
deployment's configuration and review any declaration change through the same
Host flow.

## Host worktrees

Codex stores reviewed selections and writer leases. Computer MCP owns creation,
repository topology, verified project registration, Git recovery and removal.
The source and child adapters share only their associated worktree and its
operations within the verified principal and profile. Other Codex records stay
in the selected project's state directory.

Plan and provision in the source project. Copy the returned `perform_arguments`,
including any explicit nulls. Omitted or null `branch` selects
`worktree/<name>`. Omitted or null `base` selects the source main checkout's
current branch when the host reserves the perform call. Supply an explicit base
branch for a detached source. The resolved result includes the child project,
worktree ID, checkout path, branch, base and warnings. Lease disposition is
reported separately. If the child has a conflicting writer lease, settle that
lease before acquiring one explicitly in the child.

Select the returned child project to release its Codex writer lease and plan
removal. The review binds `force`, which defaults to false. The host drains
writers, retains recoverable Git roots, publishes the committed result, then
removes the checkout and unregisters the child. Force authorizes discarding
uncommitted changes. The branch remains available in the source.

The adapter records the invocation and operation IDs before requesting an
effect. If a reply is lost, or removal terminates the child adapter, read the
record with `codex.worktree.managed.read` from the source project. The same
operation ID is inspected under current host authorization. A pending or
recovery-required outcome stays attached to that operation until the host
resolves it. A terminal refusal needs a fresh plan and invocation. A subsequent
owner permission answer does not resume the original call.

`codex.worktree.managed.list` includes host inventory, Codex records and
unmanaged history. Foreign inventory is visible without a Codex association.
Existing plugin-created records remain unmanaged across upgrade and expiry.
Lease expiry changes metadata only.

## Diagnostics

`codex.diagnostics.snapshot` combines adapter state with host records only when
this callback service is available. The host filters records by project,
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
Use the registered project ID and returned native thread ID.

```sh
computer-mcp tools call codex.app.handoff.diagnose --arguments-json \
  '{"project_id":"<project-id>","thread_id":"<thread-id>","observed_error":"<message from the other client>"}'
computer-mcp tools call codex.diagnostics.snapshot --arguments-json \
  '{"project_id":"<project-id>","limit":100}'
computer-mcp tools call codex.app.thread.release --arguments-json \
  '{"project_id":"<project-id>","thread_id":"<thread-id>"}'
computer-mcp tools call codex.app.thread.recent --arguments-json \
  '{"project_id":"<project-id>","thread_id":"<thread-id>"}'
```

When calling indirectly with `mcp.tools.call`, put `project_id` beside
`server`, `tool` and `arguments`. Put plugin arguments inside `arguments`. Native names and exported host names need not be identical.

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
mode. Full Access cannot grant host callbacks extra capabilities, project
access or macOS privacy permissions.

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
