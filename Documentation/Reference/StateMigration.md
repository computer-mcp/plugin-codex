# Offline state migration

`codex-mcp-adapter migrate-state` transfers adapter-owned records from an offline
Computer MCP SQLite snapshot to a separate adapter database. It is an explicit
local administration command, not an MCP tool. It does not launch Codex, call a
model, stop a host, switch providers, or change any authorization.

## Preconditions and scope

Finish or release owned execution through its normal lifecycle before taking the
source snapshot. Stop the destination adapter and keep both files unchanged for
preview and apply. Use SQLite's [backup API](https://sqlite.org/backup.html) or an
appropriate checkpointed offline copy; copying the main file of a live WAL
database alone is not a complete snapshot. The command rejects `-wal`, `-shm`
and `-journal` sidecars. Their absence is not proof that all processes have
stopped: the operator or a future host cutover transaction must establish that.

The source is opened read-only. Only these domain tables are transferred:

- `codexApprovals`, `codexRuntimeLeases`, `codexThreadOwnership`;
- `codexOwnershipReconciliationReceipts`, `codexOrchestrationRuns`;
- `codexWorktreeLeases`, `codexManagedWorktrees`.

Host grants (including elevation), credentials, profiles, workspace registration,
audit, plugin state and vendor `CODEX_HOME` data are not transferred. A file hash
binds the complete source snapshot, but reports do not include stored row values.
The source database is never migrated, reconciled, or deleted by this command.
Older snapshots may omit domain tables; unknown columns and malformed records are
rejected rather than silently dropping data. Indexed record identity and scope
must agree with the decoded payload. Unknown payload JSON fields are preserved.

The destination may be absent or already initialized by this adapter. An existing
destination must contain only current adapter tables and its own migration
history, without triggers. The command refuses a host database, a symbolic-link
file, or source and destination aliases referring to the same file.

## Preview and apply

```sh
codex-mcp-adapter migrate-state \
  --source-snapshot /absolute/offline/gateway.sqlite \
  --destination /absolute/adapter-state/codex.sqlite
```

Preview writes no destination database. Review the per-table insert, identical
and conflict counts and the `plan_digest`. Apply that exact plan:

```sh
codex-mcp-adapter migrate-state \
  --source-snapshot /absolute/offline/gateway.sqlite \
  --destination /absolute/adapter-state/codex.sqlite \
  --apply --expected-plan-digest DIGEST
```

`--apply` and `--expected-plan-digest` must be supplied together. Source changes,
destination record changes or a replaced destination invalidate the plan. A
conflicting identity never overwrites a destination record. The existing-database
import rechecks the plan and writes all tables in a single transaction, so even a
late uniqueness or I/O failure cannot leave a partially imported set of rows.
`can_apply` describes the preview's record-conflict result; apply still validates
current state, database constraints and filesystem availability.

A new destination is built in a private sibling staging directory and published
without replacing an existing file only after the complete import closes. Its
parent directory must already exist. The database is created with owner-only
permissions. Repeating a fresh preview/apply is idempotent: byte-identical rows
are counted but not rewritten. Reusing a pre-import digest after the destination
has changed is deliberately rejected. Text comparison uses UTF-8 bytes rather
than Swift canonical Unicode equivalence, and invalid UTF-8 is rejected.

The bounded operation supports a source file up to 256 MiB, 100,000 domain rows,
and 64 MiB of encoded domain values. Exceeding a bound fails explicitly; it never
copies a truncated prefix of the source.

## Recovery and cutover boundary

On a rejected plan or failed transaction, inspect the error and produce another
preview after resolving the cause. Do not delete conflicting destination records
or change a digest merely to force the operation through. Preserve the source
snapshot and the JSON result as migration evidence.

This operation copies records, not live authority. It neither resurrects pending
approval requests nor claims a live thread writer, renews a lease, registers a
workspace, or restores an elevation grant. The separate host-service integration
and provider cutover must preserve their own authorization and ownership checks.
No automatic production cutover is performed here.

Before the new adapter writes additional state, reverting to the unchanged
source remains a separate reviewed host operation. After new writes, reconcile
those records before rollback; blindly restoring the source snapshot would lose
new work. A process crash can leave a private `.codex-state-*` staging directory;
inspect and remove only that operation's owned directory, never the source or
independently configured adapter state.
