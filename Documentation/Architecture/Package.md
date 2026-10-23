# Package

The package uses Swift tools 6.2 and supports macOS 14 or newer.
`CodexMCPAdapter` owns argument handling; `CodexAdapter` owns configuration,
MCP projection and Codex domain implementation. Runtime tests live in `CodexAdapterTests`; command parsing tests
live in `CodexMCPAdapterTests`. Computer MCP Core is not a
dependency.

## Dependencies

| Package | Responsibility |
| --- | --- |
| `computer-mcp/swift-sdk` transport fork | Standard northbound MCP transport, tools and results; stdio and complete POSIX frame writes |
| swift-codex | App Server client and Exec client, each with its own lifecycle |
| swift-subprocess | Child process launch and line I/O |
| swift-argument-parser | Named options, schema-comparison subcommand, validation and generated CLI help |
| GRDB | Codex approval, runtime/thread ownership, acceptance run, worktree lease and managed-worktree storage and transactions |

The [release reference](../Reference/Release.md#dependencies-and-verified-combinations)
records dependency requirements, selected revisions and compatibility checks.
swift-crypto and swift-nio are transitive dependencies, owned by their declaring
packages.

The managed line process uses swift-subprocess's explicit input writer,
file-descriptor stdout and stderr sequence. Its child-input owner installs a
no-op `SA_RESTART` SIGPIPE handler once only for the default disposition,
preserving existing handlers and ignored signals. A handler resets on exec,
whereas ignoring SIGPIPE would survive into children. Broken pipe errors from
the library propagate unchanged; a returned short write fails with the adapter's
closed-transport error. The child-input owner follows these ordering and
lifetime rules:

1. Whole frames enter a FIFO queue, with at most one library write outstanding.
   A caller-requested EOF follows earlier writes in that same order.
2. Cancellation before admission removes the caller promptly without writing,
   including cancellation racing with admission.
3. An admitted write runs in an owner task. Its caller awaits completion even
   if cancelled; only process I/O termination can interrupt that write.
4. A positive short count retires input before another caller can be admitted.
   Queued and later writes fail closed. A zero count fails that write without
   retiring input; thrown library errors propagate unchanged.
5. Shutdown rejects queued writes and proceeds with bounded process-group
   termination independently of the active write. Both explicit input finish
   and return from the subprocess body wait for that write to settle. Supervisor
   exit cancels process I/O even if a descendant retains the pipe. Close allows
   up to five seconds for startup, two termination-grace intervals, and one
   kill-grace interval before reporting a termination timeout; it never closes
   input under an outstanding write.

Shutdown preserves EOF delivery and frame/output limits.

Dependency notices ship with the
adapter artifact, independently of host dependencies.

Argument Parser keeps command structure and help in one declaration. Parsing
completes before serving or schema comparison starts, so parser errors never
start Codex.

Use the SDK's public clients, including App Server raw request, notification and server-request access, for
protocol initialization and request correlation. Domain ownership, input validation and MCP projection belong in this package.
Typed validation checks known native approval and interaction contracts; the
SDK sends the original JSON response, preserving unknown fields.

The SDK's adoption resource determines the native request inventory. The
plugin derives complete MCP input schemas and validates requests with the
SDK's generated stable or experimental `ClientRequest` type before sending
the original JSON through the SDK connection. `CodexAppServerMethodCatalog`
owns operation-risk classification; an adopted request without a policy fails
catalog construction and CI. Stable native tools use `codex.app.native.*`;
experimental requests require the explicit experimental call path. Protocol
inspection remains separate from execution admission.

Interactive commands, processes, filesystem watches and MCP event streams
retain handles bound to the exact connection generation. Follow-up calls
cannot use another generation's handles. Uncertain sends retain reservations;
only successful terminal responses, matching process-exit events or confirmed
process-group cleanup release them. A supervisor's exit alone is not cleanup
evidence. Late notifications and server requests from retired connections do
not modify the active connection's state. Each reservation captures its creating
work-invocation UUID; follow-up requests retain that origin. Its reservation token
identifies the ownership lifetime separately from the reusable native handle.
Late replies cannot release or change a replacement reservation's state.
Confirmed process-group cleanup also clears that generation's loaded,
subscribed and active-thread claims and connection-local thread cache. Unknown
cleanup retains these claims until confirmation; native history and persistent
thread-ownership records are separate from a live connection's claims.

Thread and turn work capture their creating invocation separately. Native IDs
can arrive through notifications before the creating RPC returns; pending
inputs and approvals share the same once-bound origin. An ordinary client's
unbound work cannot later be claimed by a metadata-bearing reader or resume.
Goal-created turns and callbacks retain the Goal's origin. Interleaved Goal
notifications invalidate older observations before ownership can be released.
The SDK's ordered raw inbound stream lets the adapter register a server request
before applying subsequent completion notifications. Registered handlers run
separately, so a slow host callback cannot hide later requests from the work
ledger. Admission rejects requests beyond the pending-handler capacity while
retaining active and uncertain owners.
Server-request work belongs to its exact connection and remains live until both
the SDK request lifecycle and any host callback have settled. Native process
cleanup alone does not finish a host callback, and a new connection can reuse
native request IDs without replacing callbacks from the previous connection.

Inline and detached reviews and explicitly started queued submissions bind
their returned turn identities to the creating invocation. Early input shares
that binding, and a completion observed before the reply prevents resurrection.
Unsubscribe acknowledgements remove subscriptions without declaring native work
finished. Missing entries in a complete loaded-thread listing retain uncertain
ownership until closure; partial pages never replace the complete known set.
Native archive, delete and revert may report closure after a shutdown timeout,
so those operations retain their previous thread owner until process cleanup.
Graceful handoff cannot reap a runtime that still owns unrelated native handles,
login attempts, callbacks or other thread activity.

Account and MCP OAuth login attempts outlive their initiating RPCs. Account
completion matches the exact login ID, including completion before the reply;
cancel or replacement acknowledgements do not release unfinished attempts.
MCP login completion matches both server name and optional thread identity.
Because that notification carries no attempt ID, overlapping attempts for the
same scope are rejected until completion. Confirmed process cleanup releases
only the affected generation's login work.

Realtime sessions use the same admission and completion ownership boundary.
A stop acknowledgement does not replace the matching closed notification.
Remote-control initialization is retained until its initial status is known.
Persisted native remote control belongs to the process creator; an explicit
enable keeps its own invocation. Native disabled status only changes desired
connectivity, so an enabled lifetime remains uncertain until process cleanup.
These states prevent idle handoff from terminating unrelated background work.

## Execution and authority

`CodexAppServerProvider` maps the App Server and persisted-domain tools to
the App Server runtime, acceptance engine, worktree operations and diagnostics.
`CodexExecutionProvider` maps Exec tools to `LiveCodexExecRuntime`, which owns
session records, event buffers, cancellation and shutdown. Cancellation requests
and confirmed process cleanup are distinct states. The SDK bounds process output
and drains pipes through termination; the adapter exposes capture loss separately
from its bounded event history. MCP discovery does
not eagerly connect any provider. The server invokes all shutdown paths
when its northbound transport completes or fails.

Every advertised tool declares the ordinary MCP work resource at
`computer-mcp://runtime/work/v1`. Reads combine Exec and App Server owners into
one bounded snapshot with a per-server instance UUID and a monotonically
increasing revision. Unchanged resources keep the same revision. Missing origins,
invalid identities, duplicate resources, unavailable providers and capacity
overflow fail the whole observation; no partial or truncated work set is
published. One read runs at a time. An overlapping reader receives a retryable
error instead of a snapshot begun before its call. Shutdown joins the owned
observation before shutting down providers. Discovery and reads start no native
provider process.

Work rows may expose bounded `handles` containing the native identifiers needed
for continuation. The primary `id` identifies an acquired lifetime, so reuse of
a native handle produces a different primary ID. App Server rows include
`runtime_id`; thread, turn, queue, login, request and approval aliases come from
their existing lifecycle records. Late acknowledgements can add identifiers
without changing the acquisition. Commands, processes, filesystem watches and
event subscriptions expose `native_id`; Exec sessions use their primary ID.
Aliases preserve string versus exact integer identity, remain through uncertain
cleanup and confer no permission. Whole-report resource and byte bounds also
apply to aliases.

Existing-handle tools declare ordinary MCP continuation selectors. Native tool
selectors use the SDK-derived thread parameter schema and the adapter's owned
command/process/watch/subscription lifetimes. `methods.call` declares exact method
conditions for the same associations; a handle-creation operation does not select
an older lifetime merely because the caller reused its native ID. Optional native
thread scopes support an explicit null. New tasks, including forks and Exec
resume processes, use their creation context. Unscoped status, listing, events
and whole-runtime operations have no implicit existing-owner selector. Runtime
inspect/stop tools can locate a specific `runtime_id` while it owns work.
Declarations preserve publisher risk metadata and native schemas. Host generation
selection and current authorization remain host responsibilities.

Exec reserves a session identity before native startup. Its owner retains the
startup task until registration settles, counts that pending identity once
against capacity, and cancels and joins it during shutdown. A handle returned
after cancellation is still registered and cleaned through the normal process
waiter. Shutdown closes new admission; cancellation never substitutes for
observed process cleanup.

Each Exec owner captures its optional work-invocation UUID before startup. The
pending launch and registered session share that immutable acquisition; later
reads or cancellation calls cannot replace it. A missing binding is distinct
from an empty work set. Result retention remains owned after process termination.
`codex.exec.release` drops a settled result only after confirmed process cleanup,
without changing native conversation storage or the thread-owner index.

`CodexLaunchContext` records the initial workspace and verified host subject.
The host authorizes every invocation against its current policy; launch metadata
does not freeze permissions or grant control-plane access. Native Codex
configuration owns sandbox, approval, provider, MCP, Skills, hooks and
authentication. Omitted overrides inherit it; explicit native parameters pass
through unchanged. An initial directory or Git worktree is not OS isolation.

`CodexProcessEnvironment` preserves vendor state configuration and proxy
behavior while removing parent Codex session and Computer MCP launch metadata.
External Codex installation and user credentials remain user-owned.
Environment names are case-sensitive. Proxy settings mirror a single inherited
uppercase or lowercase value while preserving explicitly configured distinct values.

App Server and Exec resolve the configured executable using the same
launch environment and workspace: absolute paths are direct, relative paths
are workspace-relative, and bare names use PATH. Resolution happens when the
provider starts, so a missing program does not prevent catalog discovery.
Each child receives the complete filtered environment, not an overlay that
could reintroduce parent-session authority. Exec loads personal Codex config,
including provider, MCP, Skills and hooks; only explicit native overrides
change those settings.

## App Server domain

`LiveCodexAppServerRuntime` uses the swift-codex App Server client and the
owned line-process transport. It owns thread/turn and Goal requests, bounded
events, native approvals, user input, connection generations, cancellation,
shutdown and handoff. Lease-based reconciliation checks the exact receipted
processes before declaring an uncoordinated owner gone.

`CodexDatabase` stores approvals, runtime leases, thread ownership,
reconciliation receipts, acceptance runs, worktree leases and managed-worktree receipts using their
existing row and JSON representations.
It uses one initial domain schema and GRDB transactions; it does
not store host profiles, credentials, workspace registrations or audit.
Unknown migration identifiers fail before either the domain or shared-lease
store is initialized. Use a fresh adapter state directory for an incompatible
schema. The separate shared-lease database initializes only its lease table and
index.
Host-launched storage is partitioned by verified subject, profile and registered
workspace, not a transient connection or channel. Reconnection retains this
identity. Worktree lease facts use one transactional store per subject and
profile, so a registered child workspace and its source observe the same lease
revision. Tool access remains workspace-bound; cross-workspace lineage requires
a managed-worktree receipt created by the source's verified host registration.
Other domain records remain workspace-partitioned.
Existing unbound storage is preserved and reported for local review;
it is never silently assigned to a new subject. A shared, transactional native
thread-owner index prevents concurrent claims or reads by another subject.
Read-only history lookup does not claim a thread.

`CodexHostTools` requires host preflight plus per-execution authorization and
audit. Native Codex approvals retain official decisions and scopes; host-tool
approvals remain under the host's own authority.
`CodexHostMCPClient` uses the explicitly delegated standard MCP connection.
Its verified subject is fixed, while the host checks current grants for each
call. Tool arguments cannot select authority or an administrator socket.

`CodexManagedWorktreeManager` owns Git planning, creation, ownership checks and
removal, preserving the stored revision and source-workspace scope.
`CodexManagedWorkspaceHost` owns derived-workspace registration and grants,
registration rollback, and destructive-operation authorization. Removal requires
that authorization before changing either Git or the lifecycle receipt.

`CodexOperationalDiagnostics` correlates adapter-owned state with a bounded,
scope-matched `CodexHostDiagnostics` snapshot. Host audit data stays host-owned;
missing host data produces explicit unknown values. Audit projection
retains identifiers and digests, redacts strings, and excludes command bodies.
The executable's launch factory supplies these interfaces when the host provides
its inherited MCP descriptor. Without it, managed-worktree mutations remain
unavailable and host diagnostic fields remain unknown. Vendor subprocesses do
not receive the host descriptor or reserved context. The host chooses the
managed root separately from adapter-domain persistence.

Removal preserves a `removing` receipt when Git succeeded but host cleanup did
not. A new reviewed operation validates path absence and Git state before
retrying metadata only. Provision rollback preserves Git content when host
cleanup is unconfirmed; it never represents that case as a complete rollback.
See [Host integration](../Reference/HostIntegration.md) for the operator contract.

## Runtime generations and teardown

Each workspace connection owns a lazy App Server runtime with a stable
`runtime_id`. Its current connection has a separate generation, process group,
App Server PID, supervisor PID, parent PID, timestamps, exit status, signal and
termination escalation. Concurrent first calls share startup. Notifications
and server requests belong to their exact generation; reconnecting does not
transfer ownership of earlier work.

Shutdown joins notification/request consumers, performs bounded unsubscription,
marks pending approval records interrupted, and closes the transport. Teardown
rejects queued input and delivers EOF once any admitted write settles. It waits
for graceful exit, sends TERM to the exact owned process group if necessary,
then KILL after another bounded interval and records reaping.
A private supervisor watches the owner's death and applies the same cleanup.
No process is selected by executable name or a machine-wide search.

The normal request timeout covers startup, workspace validation, the native
RPC and at most one fresh-generation read-only retry. `app/list` has a dedicated
budget for its potentially large directory snapshot and never restarts to retry
that snapshot. A timed-out generation must be retired and reaped before retry.
Concurrent closes share retirement, including back-pressured stdin. Runtime
lifecycle, connection state, process state, active-request count, last request
failure and terminal shutdown reason are independent; a request timeout does
not itself mean the runtime stopped.

Recent-thread supervision reads native state read-only, validates the canonical
workspace and rollout root, and scans a bounded tail. Snapshot-bound cursors,
page and Goal-scan bytes, record count, output bytes and elapsed scan budget are
reported. Native thread/Goal persistence remains separate from adapter ownership.

A native Goal, an adapter acceptance run and a completed turn have distinct
lifetimes. Official Desktop, IDE, CLI and Remote connections own their own
processes and authority. The adapter cannot unsubscribe or stop those clients.
Native approvals preserve correlation, deadlines and terminal states; a lost
connection never becomes consent or permission to replay. Account/configuration,
marketplace and remote-pairing operations require the appropriate local control
scope. Retained diagnostic data is bounded and credential-redacted; native
payload preservation does not make raw output safe to publish.

## API and verification scope

The Exec and App Server runtime tests execute in this package.
App Server tests use isolated protocol processes and adapter-owned databases,
including independent database connections and exact process-ownership checks.
Standard-MCP dispatch tests use controlled execution doubles and an isolated
protocol process with a durable database. These fixtures
do not prove native model authentication or host-to-adapter integration.

Managed-worktree tests also use private Git repositories and two workspace-bound
MCP connections. They verify lease scope, active/dirty worktree protection,
host denial without mutation, durable removal and branch preservation.
The workspace and diagnostic host implementations in these tests are test
doubles, not evidence of a connected Computer MCP control plane.

The exposed execution surface includes App Server and Exec.
Version-specific schemas remain separate inspection tools. The package exports an executable, not a
public Swift library API; [Documentation](Documentation.md) defines its manual
and API documentation scope.

## Distribution

The repository validation workflow resolves and verifies the checked-in dependency
lock, lints and tests the Swift package, verifies package input ownership and
exclusive output publication, then invokes `scripts/package.py` for a
relocatable release-configuration archive. It retains the ZIP and file/digest
receipt with read-only repository permissions. The version-controlled manifest
owns archive compatibility; packaging verifies the built adapter's slices against
it and preserves its exact bytes for GitHub provenance verification. The packager
uses Python 3.11's standard TOML parser. One runner's output does not establish
Universal 2 support.
The package job neither installs vendor executables nor exercises real accounts.
An authorized publisher must separately review provenance, signing and runtime
acceptance before promoting an artifact to a public release.

## Inherited host channel

The host binds callbacks to its own immutable caller/workspace scope over an
inherited connected Unix socket. `COMPUTER_MCP_HOST_FD` selects a canonical
descriptor from 3 through 9 alongside the host context. The transport requires
a connected stream socket, sets close-on-exec and nonblocking mode, and bounds
message sizes, queued data and write deadlines. Disconnect closes the owned
descriptor and joins active I/O. Callback metadata is removed from vendor
environments.
