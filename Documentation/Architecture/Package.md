# Package

The package targets macOS 14 and Swift tools 6.2. `CodexMCPAdapter` owns argument
handling; `CodexAdapter` owns configuration, MCP projection and Codex domain
implementation. Runtime tests live in `CodexAdapterTests`; command parsing tests
live in `CodexMCPAdapterTests`. Computer MCP Core is not a
dependency.

## Dependencies

| Package | Responsibility |
| --- | --- |
| Official MCP Swift SDK 0.12.1 | Standard northbound MCP transport, tools and results |
| swift-codex 0.1.2 | App Server client, Exec client and Codex MCP client, each with its own lifecycle |
| swift-subprocess 0.4.0 | Existing process infrastructure dependency |
| swift-argument-parser 1.8.2 | Named options, schema-comparison subcommand, validation and generated CLI help |
| GRDB 7.11.1 | Codex approval, runtime/thread ownership, acceptance run, worktree lease and managed-worktree storage and transactions |

`Scripts/verify-swift-codex-release-gate.sh` verifies the exact remote SDK pin
and resolved revision for this package. Its dependency notices ship with the
adapter artifact, independently of host dependencies.

Argument Parser keeps command structure and help in one declaration instead of
fixed-position argument handling. Serving and schema comparison delegate to the
same use cases as before parameter parsing; parser errors do not start Codex.

Use the SDK's public clients, including App Server raw-request access, for
protocol initialization and request correlation. Domain state, policy-specific
validation and tool projection belong in this package.

## Execution and authority

`CodexAppServerProvider` maps the App Server and persisted-domain tools to
the App Server runtime, acceptance engine, worktree operations and diagnostics.
`CodexExecutionProvider` maps the existing Exec and MCP tools to
`LiveCodexExecRuntime` and `LiveCodexMCPRuntime`. Each retains its own session
or call records, event buffers, cancellation and shutdown. MCP discovery does
not eagerly connect any provider. The server invokes all shutdown paths
when its northbound transport completes or fails.

`CodexLaunchContext` consumes immutable workspace/read-only metadata from the
host environment. This metadata narrows the launched session, is not a
credential and permits no callback into the host's database or control socket.
Standalone clients use their configured working directory. Caller tool
arguments cannot select a different workspace, sandbox or approval policy.
The plugin's operation classification enforces read-only calls independently
of MCP annotations; the host still authorizes and audits every forwarded call.

`CodexProcessEnvironment` preserves vendor state configuration and proxy
behavior while removing parent Codex session and Computer MCP launch metadata.
External Codex installation and user credentials remain user-owned.

## App Server domain

`LiveCodexAppServerRuntime` uses the swift-codex App Server client and the
owned line-process transport. It owns thread/turn and Goal requests, bounded
events, native approvals, user input, connection generations, cancellation,
shutdown and handoff. Lease-based reconciliation checks the exact receipted
processes before declaring an uncoordinated owner gone.

`CodexDatabase` stores approvals, runtime leases, thread ownership,
reconciliation receipts, acceptance runs, worktree leases and managed-worktree receipts using their
existing row and JSON representations.
It reuses GRDB transactions and lease-state compatibility handling; it does
not store host profiles, credentials, workspace registrations or audit.

`CodexHostTools` and `CodexElevationAuthority` mark host-owned calls.
The former requires host preflight plus per-execution authorization and audit.
The latter consumes or invalidates a bound, locally approved grant; it cannot
issue approval. `CodexHostMCPClient` implements these interfaces over the host's
explicitly delegated, inherited standard MCP connection. The connection's
scope is fixed at launch, and the host validates the actual currently forwarded
operation; tool arguments cannot select authority or an administrator socket.

`CodexManagedWorktreeManager` owns Git planning, creation, ownership checks and
removal, preserving the stored revision and source-workspace scope.
`CodexManagedWorkspaceHost` owns derived-workspace registration and grants,
registration rollback, and destructive-operation authorization. Removal requires
that authorization before changing either Git or the lifecycle receipt.

`CodexOperationalDiagnostics` correlates adapter-owned state with a bounded,
scope-matched `CodexHostDiagnostics` snapshot. Host audit and elevation data stay
host-owned; missing host data produces explicit unknown values. Audit projection
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

## API and verification scope

The original Exec/MCP and App Server runtime tests execute in this package.
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

The exposed execution surface includes App Server, Exec and Codex MCP.
Version-specific schemas remain separate inspection tools. The package exports an executable, not a
public Swift library API; [Documentation](Documentation.md) defines its manual
and API documentation scope.

## Distribution

The repository validation workflow resolves and verifies the checked-in dependency
lock, lints and tests the Swift package, verifies package input ownership and
exclusive output publication, then invokes `Scripts/package.py` for a
relocatable release-configuration archive. It retains the ZIP and file/digest
receipt with read-only repository permissions. The version-controlled manifest
owns archive compatibility; packaging verifies the built adapter's slices against
it and preserves its exact bytes for GitHub provenance verification. The packager
uses Python 3.11's standard TOML parser. One runner's output does not establish
Universal 2 support.
The package job neither installs vendor executables nor exercises real accounts.
An authorized publisher must separately review provenance, signing and runtime
acceptance before promoting an artifact to a public release.
