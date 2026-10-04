# Release

This guide covers publishing an accepted release and notifying the official
plugin catalog. [Versioning and Release](../Architecture/VersioningAndRelease.md)
owns the version, acceptance and immutability rules.

## Publish

1. Confirm that `version` in `computer-mcp-plugin.toml` has not been released
   and that the reviewed `master` commit has a successful CI run.
2. Accept that run's `codex-plugin-macos-arm64-<commit>` and
   `codex-plugin-windows-x86_64-<commit>` artifacts as described in
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

Each receipt records the archive digest, file inventory and build architecture;
the Windows receipt also records the required Microsoft runtime versions.

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
