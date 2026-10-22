# Release

Release status: publication and catalog notification are implemented by
[release.yml](https://github.com/computer-mcp/plugin-codex/blob/master/.github/workflows/release.yml)
and [notify-catalog.yml](https://github.com/computer-mcp/plugin-codex/blob/master/.github/workflows/notify-catalog.yml).
Candidate runtime acceptance and Release notes require an operator.

Version rules are in this repository's
[VERSIONING.md](https://github.com/computer-mcp/plugin-codex/blob/master/VERSIONING.md),
which adopts the organization's rules and records the native artifact promotion
exception. This reference records release facts, procedures and checks.

## Components and Version Sources

| Shipped component | Version meaning | Version source | Mirrors and derived fields | Update and read-only check |
| --- | --- | --- | --- | --- |
| Codex plugin and `codex-mcp-adapter` | Package release identity | Top-level `version` in [computer-mcp-plugin.toml](../../computer-mcp-plugin.toml) | `CodexAdapterBuildInfo.version`, executable `--version`, packaged manifest | [Metadata entry points](#derived-metadata-and-drift-checks) |

The packaged manifest preserves the source manifest's exact bytes. Candidate
identity comes from that manifest and the extracted executable, rather than an
installed adapter or a different worktree.

## Compatibility Surface

Consumers depend on the MCP tool names, input schemas, results and errors; stdio
transport; CLI commands, options, output and exit codes; configuration fields;
adapter state and protocol resource formats; and the package's platform and
Swift toolchain floors. The [manual](../../README.md),
[workflows](Workflows.md), [host integration](HostIntegration.md),
[installation](Installation.md) and [package architecture](../Architecture/Package.md)
describe those interfaces. `Package.swift` declares the deployment and Swift
tools floors.

The manifest declares `plugin_api = 1` and owns host-version bounds, archive
names, platforms and architectures. The SDK's schema declarations and adoption
inventory are separate from executable support and host authorization.
Compatibility review and behavior tests establish what a candidate supports;
version arithmetic alone does not establish compatibility.

## Dependencies and Verified Combinations

`Package.swift` declares dependency compatibility requirements;
`Package.resolved` records the selected versions and revisions. Current direct
requirements are:

| Dependency | Requirement |
| --- | --- |
| MCP Swift SDK organization fork (`computer-mcp/swift-sdk`) | `exact: "0.13.1-computer-mcp.1"` |
| swift-codex | `exact: "0.4.1"` |
| swift-subprocess | `.upToNextMinor(from: "1.0.2")` |
| swift-argument-parser | `from: "1.8.2"` |
| GRDB | `from: "7.11.1"` |

The [package dependency overview](../Architecture/Package.md#dependencies)
records their architectural responsibilities. CI resolves the committed lock
and rejects drift. `Scripts/verify-swift-codex-release-gate.sh` checks the
declared exact swift-codex version and resolved revision against its public Git
tag, accepting the tag's peeled commit when it is annotated. The SDK's public
tag owns its release identity.

Protocol import provenance records the vendor schema baseline from the locked
SDK. Integration receipts separately record the real Codex executable version;
these versions need not match. Accept the complete host, plugin, SDK and vendor
combination before delivery. The runtime report identifies the tested binaries
and results; a source test or schema inventory does not establish that
combination's runtime acceptance.

## Derived Metadata and Drift Checks

`python3 Scripts/version.py update --kind <fix|feature|breaking> --reason <reason>`
updates the manifest and generated constant. After an explicit manifest edit,
`python3 Scripts/version.py generate` regenerates
`Sources/CodexAdapter/CodexAdapterBuildInfo.swift`.

`python3 Scripts/version.py check` is read-only and rejects generated metadata
drift. Its `--binary <adapter>` option checks the actual executable's `--version`.
`check --base <commit>` rejects version regression when HEAD has parents and the
base is an available ancestor; otherwise it checks the current version and
reports why comparison was skipped. CI supplies the pull request base or
previous `master` commit. `check --tag <tag>` verifies the manifest version and
the tag's commit.

`node Scripts/import-schema.mjs --check` verifies bundled protocol resources
against the locked SDK commit; [Protocol inputs](../../README.md#protocol-inputs)
owns regeneration instructions. Packaging checks the manifest, generated
version and dependency lock, validates the built executable's version and
architecture, and emits the archive's file/digest receipt. Archive verification
checks the relocated bytes before runtime acceptance.

## Candidate, Acceptance and Publication

CI runs source checks and `Scripts/package.py`, then verifies and relocates the
archive with `Scripts/check-package.py`. It uploads the ZIP and native build
receipt as the commit-named candidate artifact. `release.yml` promotes those
accepted CI bytes and receipts without rebuilding. Verification, publication
and catalog notification are separate jobs.

### Runtime acceptance

Use macOS with the selected installed `computer-mcp` CLI, a separately installed
vendor Codex, Python 3.11 or newer, Git and the verified release archive. The
adapter must be the executable extracted from that archive. Record the host,
plugin and vendor combination; a package doctor proves configuration and files,
not model execution. Run the ordinary checks in [Contributing](../../CONTRIBUTING.md)
first.

```sh
python3 Scripts/check-package.py --archive <archive.zip> --receipt <receipt.json> \
  --destination .build/accepted-package
python3 Scripts/check-workflow.py \
  --adapter "$PWD/.build/accepted-package/bin/codex-mcp-adapter" \
  --codex /absolute/path/to/codex
python3 Scripts/check-host.py \
  --host /absolute/path/to/computer-mcp \
  --adapter "$PWD/.build/accepted-package/bin/codex-mcp-adapter" \
  --codex /absolute/path/to/codex \
  --output-directory "$PWD/.build/host-acceptance" \
  --mode full --auth-file /absolute/path/to/vendor/auth.json --model <model-id>
```

`check-workflow.py` exercises the relocated adapter through standard MCP with
an isolated home and fixed loopback model, covering native approvals, turns,
cancellation, reconnection and owned-process cleanup. It does not establish
real model authentication.

`check-host.py` uses only the host's public `serve stdio` command and standard
MCP. It starts private host instances with explicit workspace selection, host
configuration and databases. It does not contact the normal App control socket
or an existing App Server. The model fixture and all native generations are
owned by the run. The selected output directory must be new; after inspecting
its receipt and confirming cleanup, remove its disposable state before reusing
that location.

Full mode needs a vendor file-store login authorized for the selected model.
The supplied `auth.json` is copied with mode `0600` into the private vendor home
and deleted on exit; the original is never changed. Keychain-only credentials
are not imported. The real-model checks make bounded text-only App Server and
Exec requests, including Exec resume, using a read-only native sandbox.
Model use may incur the account's ordinary usage charges. Keep the output
private because native histories and diagnostic evidence can include account
metadata. Never publish the authentication file or raw runtime state.

For a deterministic native check without credentials, use `--mode fixture` and
omit `--auth-file` and `--model`. This still needs the installed host and real
vendor executable. It tests catalog/diagnostic laziness, explicit Skills
directories and app-list deadlines, inherited and explicit Full Access, a native
read-only override, Git hooks, loopback and outside-workspace access, workspace
process isolation, three-connection thread/Goal handoff, vendor/adapter crash
recovery without replay, native approval, fork/review/steer/interruption, Exec
options/events/results/resume/cancellation/release, and exact thread archiving.
A separate disposable App Server protocol peer exercises native host callbacks:
workspace/recursion denial, Git dry-run index preservation, prepare without
mutation, exact single-use host tickets, a complete hooked file/Git commit, and
rejection of a pending local-approval ticket. The standalone host's configured
policy authorizes the successful ticket path; local App approval resolution is
verified by the host's generic tests, not simulated as an App UI check here.
It cannot prove real authentication or model availability.

The driver writes `report.json` with step results, binary versions/digests,
fixture digest, authentication status and cleanup errors. It separately records
bounded protocol evidence. A nonzero exit, upstream directory failure, missing
step, changed binary digest or unconfirmed cleanup fails acceptance; no network
challenge is treated as an expected success. Failure injection verifies ancestry
before signalling an exact owned PID. Unknown write outcomes are never retried.
Thread archival accepts only success or an exact missing-rollout error for the
owned thread; unrelated errors remain failures.

The release candidate requires the full report to pass for its exact executable
bytes, in addition to source tests and archive verification. Host plugin
installation, grants, local approval and uninstall remain the host's generic
acceptance responsibility; this driver validates the native runtime through a
public host registration. Keep those host checks with the accepted combination.

Pure driver logic and argument validation run without a host or vendor:

```sh
python3 -m unittest discover -s Tests -p 'test_host_acceptance.py' -v
```

### Publish

1. Select the reviewed `master` commit with successful `push` CI from
   `.github/workflows/ci.yml`.
   Each declared archive selects the exact CI artifact
   `<archive-stem>-<full-commit-sha>` from that run's latest successful attempt.
2. Assemble and check the candidate without Release writes:

   ```sh
   gh workflow run release.yml --repo computer-mcp/plugin-codex --ref master \
     -f source_run=RUN_ID -F publish=false
   ```

   The dry run checks the source manifest, positive integer `plugin_api`,
   declared archive set, CI attempt and artifact digests, native inventories,
   byte-identical manifests and repository release immutability. It omits tag
   and signature checks and reads no catalog secret. Inspect the `assets/`
   directory in the `plugin-release-<run-id>-<attempt>` Actions artifact.
3. Accept those exact archive bytes through the runtime checks above and record
   the results and limits in the draft Release notes. Prepare the release tag
   under VERSIONING. An operator-created draft must target its full commit SHA;
   otherwise publication creates a draft.
4. Publish with:

   ```sh
   gh workflow run release.yml --repo computer-mcp/plugin-codex --ref master \
     -f source_run=RUN_ID -f release_tag=vX.Y.Z -F publish=true
   ```

   Verification checks GitHub's tag signature result, the tag's commit and the
   manifest version, and refuses if repository release immutability is disabled
   or cannot be verified. The verification job has only `contents: read` and
   `actions: read`, receives no secrets, executes the release workflow's
   revision, and treats the accepted source and CI files as data. Only the
   publishing job has `contents: write`; it downloads the verified bundle by its
   exact artifact ID, checks the helper and file digests, and runs no builds.

The Release assets are exactly the manifest's `compatibility.artifacts` ZIPs,
their `<archive-stem>.receipt.json` native build receipts, `release-receipt.json`
and `SHA256SUMS`. The native receipts remain inputs to `check-package.py`.
`Scripts/plugin_release.py` assembles the schema 1 receipt and checksums under
the organization's
[release content contract](https://github.com/computer-mcp/.github/blob/master/VERSIONING.md#plugin-release-contents)
and [Codex promotion contract](https://github.com/computer-mcp/.github/blob/master/VERSIONING.md#codex-promotion-exception).

Publication uploads the unified receipt first to freeze provenance, then the
archives and native receipts, then checksums. Every asset's API size and SHA-256
must match before the draft becomes public. The publication response must report
`immutable: true`. Release notes remain operator-owned.

### Catalog notification

`notify-catalog.yml` runs when a release is published, edited, released,
unpublished or deleted, and on manual dispatch. It asks the website to reconcile
the complete catalog. The website verifies the actual GitHub releases rather
than the event payload, keeps verified history, and applies its own withdrawal
policy; an event never withdraws a release by itself.

The workflow authenticates as the receiver-scoped catalog GitHub App through
the `CATALOG_APP_CLIENT_ID` variable and the `CATALOG_APP_PRIVATE_KEY` secret.
The App needs Actions write access to `computer-mcp/computer-mcp.github.io` only.
The job checks this repository's immutable ID, does not check out package code,
and grants its own token no repository permissions. Missing or rejected
authority fails the run visibly.

The website's notification action is pinned to a reviewed full commit. Publish
that website commit first, then update the pin here when adopting a change to
the notification contract.

A release published with a repository `GITHUB_TOKEN` does not trigger
release-event workflows. `release.yml` calls `notify-catalog.yml` as a separate
dependent job only after confirmed publication. Only that job receives
`CATALOG_APP_PRIVATE_KEY`; dry runs never notify the catalog.

### Retry

Use **Re-run failed jobs** after a failed publication. A publish-only retry uses
the original bundle artifact ID and digest outputs, including after a workflow
run attempt changes. If verification reruns, a complete uploaded draft receipt
wins over `source_run`: recovery validates its recorded successful historical CI
attempt, fetches each artifact by its recorded ID and digest, and reproduces the
same receipt and checksums. It never selects a newer CI attempt or changes the
recorded workflow identity.

Expected `starter` assets can be deleted and uploaded again only while the
Release is a draft. Matching completed assets are retained. Unexpected names,
conflicting digests or sizes, or an invalid historical attempt fail without
replacement. If a recorded artifact expired or disappeared, delete the
unpublished draft, obtain fresh successful CI artifacts, and dispatch publication
again to start a new assembly. For an existing public Release, a rerun checks
the exact asset set against the frozen receipt, requires `immutable: true`,
and reports it already published without writes or reliance on CI retention.

For a missed or failed catalog notification, rerun only the notifier or dispatch:

```sh
gh workflow run notify-catalog.yml --repo computer-mcp/plugin-codex --ref master
```

A successful dispatch only proves the request was accepted. Follow the run's
`run_url` output to the website run, confirm it succeeded, and confirm the public
index lists the expected release. Retrying never requires changing or
republishing the release: reconciliation is idempotent, and the website's
hourly schedule also repairs missed notifications.

The website's
[catalog publication and notification contract](https://github.com/computer-mcp/computer-mcp.github.io/blob/master/docs/plugin-catalog.md)
covers provenance, credentials, retry bounds and deployment.

## Evidence Reuse and Invalidation

Successful evidence is reusable when its source, dependency lock, check
definition, toolchain, environment, target configuration and artifact digest
match, with verified provenance. The release helper verifies CI run and attempt
identity and artifact digests; an operator reviews native receipts, runtime
reports and the accepted host combination. Missing or changed inputs require
the affected checks and their dependent stages again.

Changes to compiled source, dependencies or packaging inputs require a new
archive, including changes to the shipped manual. Local rechecks after
checker-only changes can use unchanged archive bytes with the new checker
revision recorded separately.
Publication still uses source CI artifacts for the exact accepted commit and
the provenance frozen in the draft receipt. A new CI identity can be selected
before provenance freezes or after deleting an unpublished draft, as described
in [Retry](#retry).

Source tests do not replace installed-package or authenticated runtime evidence.
Preserve failed results and distinguish fixture, product and external failures.
Routine checks and result judgments are scripted; release approval remains an
operator decision.

## Entry Points and Artifact Retention

| Operation | Existing command or manual procedure | Required access |
| --- | --- | --- |
| Version update and drift checks | [Metadata entry points](#derived-metadata-and-drift-checks) | Local source write for updates; read-only checks |
| Source validation | [Contributing checks](../../CONTRIBUTING.md#validation) | Local toolchain; dependency resolution and public SDK tag lookup |
| Release workflow validation | `python3 Scripts/check-workflow.py --check-release-workflow` and `python3 -m unittest discover -s Tests -p 'test_*.py'` | Local files; no host, vendor or credentials |
| Candidate build | `python3 Scripts/package.py --output dist --configuration release` | Local build tools and resolved dependencies; new output directory |
| Archive and runtime acceptance | [Runtime acceptance](#runtime-acceptance) | Verified archive, installed host and vendor; authorized file-store login for full mode |
| Dry run and publication | [Publish](#publish) | Actions dispatch; verified immutable-release setting; publication job has contents write access |
| Interrupted-run recovery and catalog status | [Retry](#retry) | Actions access; catalog authority isolated to the notifier |
| Install, upgrade and rollback | [Installation](Installation.md) | Host owner authority |
| Cleanup | Manual inventory and removal after confirming inactivity and cleanup receipts | Ownership of each disposable output |

CI retains source candidate artifacts for 14 days. Keep the native build
receipts, runtime reports, host acceptance evidence and previous rollback
package needed for delivery. Frozen provenance recovery depends on the
recorded CI artifacts until publication; [Retry](#retry) covers unavailable
artifacts and verification of a complete public Release.

Fixture directories and package staging belong to their creating run. Remove
inactive, reconciled temporary outputs from `dist/`, `.build/` and private
fixture directories; preserve unique source changes, required failure or
delivery evidence and rollback artifacts. Runtime databases, credentials,
existing user App Servers and unrelated changes remain user-owned. Keep private
run paths and progress outside normative documentation.
