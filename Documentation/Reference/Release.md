# Release

This guide covers publishing an accepted release and notifying the official
plugin catalog. [Versioning and Release](../Architecture/VersioningAndRelease.md)
owns the version, acceptance and immutability rules. The organization's
[VERSIONING.md](https://github.com/computer-mcp/.github/blob/master/VERSIONING.md)
owns shared plugin API, release content and recovery requirements.

Codex is the documented exception to the reusable organization release workflow:
its native builds are not byte reproducible. Its own `release.yml` promotes the
accepted CI artifacts and uses `reproduction: ci-artifact-promotion` under the
same release content and publication contract. Enable GitHub release immutability
in the repository settings before running publication or its dry run; the
workflow refuses when that setting is disabled or cannot be verified.

## Runtime acceptance

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

## Publish

1. Confirm the manifest's `version` has not been released and the reviewed
   `master` commit has successful `push` CI from `.github/workflows/ci.yml`.
   Each declared archive selects the exact CI artifact
   `<archive-stem>-<full-commit-sha>` from that run's latest successful attempt.
2. Assemble and check the candidate without Release writes:

   ```sh
   gh workflow run release.yml --repo computer-mcp/plugin-codex --ref master \
     -f source_run=RUN_ID -F publish=false
   ```

   The dry run checks the source manifest, positive integer `plugin_api`,
   declared archive set, CI attempt and artifact digests, native inventories
   and byte-identical manifests. It omits tag and signature checks and reads
   no catalog secret. Inspect the `assets/` directory in the
   `plugin-release-<run-id>-<attempt>` Actions artifact.
3. Accept those exact archive bytes through the runtime checks above and record
   the results and limits in the draft Release notes. Create and push a signed
   annotated `vX.Y.Z` tag directly on the accepted commit. An operator-created
   draft must target its full commit SHA; otherwise publication creates a draft.
4. Publish with:

   ```sh
   gh workflow run release.yml --repo computer-mcp/plugin-codex --ref master \
     -f source_run=RUN_ID -f release_tag=vX.Y.Z -F publish=true
   ```

   GitHub must verify the tag signature as valid; the tag's commit and manifest
   version must match. The verification job has only `contents: read` and
   `actions: read`, executes the release workflow's revision, and treats the
   accepted source and CI files as data. Only the publishing job has
   `contents: write`; it downloads the verified bundle by its exact artifact ID,
   checks the helper and file digests, and runs no builds.

The Release assets are exactly the manifest's `compatibility.artifacts` ZIPs,
their `<archive-stem>.receipt.json` native build receipts, `release-receipt.json`
and `SHA256SUMS`. The native receipts remain inputs to `check-package.py`.
The unified schema 1 receipt contains the plugin ID, version, `plugin_api`,
compatibility, tag and commit; sorted archive names, sizes and SHA-256 digests;
each archive's `native_receipt` name, size and SHA-256; the CI run ID, attempt
and artifact IDs/digests; the release workflow ref and commit; and reproduction
`ci-artifact-promotion`. It uses deterministic sorted-key JSON with no timestamps.
`SHA256SUMS` covers every ZIP and receipt, sorted by filename.

Publication uploads the unified receipt first to freeze provenance, then the
archives and native receipts, then checksums. Every asset's API size and SHA-256
must match before the draft becomes public. The publication response must report
`immutable: true`. Release notes remain operator-owned.

## Catalog notification

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

## Retry

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
again to start a new assembly. Published releases are never modified: a rerun
checks the exact asset set against the frozen receipt, requires `immutable: true`,
and reports it already published even after CI artifact retention expires.

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
