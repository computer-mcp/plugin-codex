# Release

This guide covers publishing an accepted release and notifying the official
plugin catalog. [Versioning and Release](../Architecture/VersioningAndRelease.md)
owns the version, acceptance and immutability rules.

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

1. Confirm that `version` in `computer-mcp-plugin.toml` has not been released
   and that the reviewed `master` commit has a successful CI run.
2. Accept that run's `codex-plugin-macos-arm64-<commit>` artifact as described in
   [Versioning and Release](../Architecture/VersioningAndRelease.md), including
   the host checks against the exact archive bytes.
3. Create a signed annotated tag `vX.Y.Z` on the accepted commit and push it.
4. Create a draft GitHub Release for the tag whose target is the full commit SHA.
5. Promote the CI artifacts into the draft:

   ```sh
   gh workflow run release.yml --repo computer-mcp/plugin-codex --ref master \
     -f source_run=RUN_ID -f release_tag=vX.Y.Z
   ```

   The workflow accepts only a successful `master` push run of `ci.yml` for the
   tagged commit. It checks every archive the manifest declares against the tag
   before uploading each archive and its `<archive>.receipt.json`. It never
   rebuilds and never publishes the draft.
6. Review the draft's assets and notes, then publish it.

The receipt records the archive digest, file inventory and build architecture.

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
release-event workflows. Automation that publishes that way calls the workflow
as a dependent of the job that makes the release public:

```yaml
notify-catalog:
  needs: publish
  uses: ./.github/workflows/notify-catalog.yml
  secrets:
    CATALOG_APP_PRIVATE_KEY: ${{ secrets.CATALOG_APP_PRIVATE_KEY }}
```

## Retry

For an operator-driven publication or a missed or failed notification, dispatch:

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
