# Release publication and catalog notification

Publish only an accepted plugin package bound to its reviewed source/tag and exact archive digest.
Keep an existing public tag and archive immutable. A candidate, draft or notification receipt does
not establish authenticated vendor or installed-host acceptance.

The upload-release workflow promotes an accepted existing candidate into a matching draft; it does not make that draft public. After the accepted release becomes public,
`notify-catalog.yml` requests a complete catalog reconciliation. It also observes public edits,
channel promotion, unpublishing and deletion; those events never authorize catalog withdrawal by
themselves. The central publisher retains verified history and applies its reviewed withdrawal
policy. It verifies actual GitHub release sources rather than trusting an event payload.

## Notification authority

The workflow pins the website's central notification action to a reviewed full commit. Publish that
central commit before enabling a plugin workflow that references it. Review and update this pin
when adopting changes to the notification contract. The caller checks its immutable repository ID,
does not check out package code, and grants its own job token no repository permissions.

Supply `CATALOG_DISPATCH_TOKEN` using existing reviewed authority with Actions write access to
`computer-mcp/computer-mcp.github.io` only. Website Contents write access is unnecessary. The action
can also receive an existing temporary token directly from a publishing job. Neither workflow
creates or persists credentials. Missing or rejected authority fails visibly; the
publisher's independent schedule still reconciles missed notifications.

## Publication and retry

A manual public release emits the release event. Publication performed with a repository's
`GITHUB_TOKEN` does not trigger ordinary release-event workflows. After that publication succeeds,
its automation must explicitly call this reusable workflow as a dependent job:

```yaml
notify-catalog:
  needs: publish
  uses: ./.github/workflows/notify-catalog.yml
  secrets:
    CATALOG_DISPATCH_TOKEN: ${{ secrets.CATALOG_DISPATCH_TOKEN }}
```

Here `publish` is the job that actually makes the accepted release public, not the candidate-build
or draft-upload job. When using an existing short-lived token within that publishing job, invoke
the same pinned central action directly after publication instead. Keep token values out of command
arguments, printed output and release metadata.

For an operator-driven publication or a missed/failed notification, explicitly dispatch:

```sh
gh workflow run notify-catalog.yml --repo computer-mcp/plugin-codex --ref master
```

This schedules notification using its configured authority; it does not publish or rewrite a
release. Inspect the notification run and its returned central `run_url`. A successful dispatch
proves request acceptance only. Verify the central run completed successfully and the public index
contains the exact expected release identities and generation. If the release is already public and
notification fails, retry notification without changing or republishing the release. Complete
reconciliation is idempotent and repairs duplicate/missed events.

See the central [catalog publication and notification contract](https://github.com/computer-mcp/computer-mcp.github.io/blob/master/docs/plugin-catalog.md)
for provenance, credentials, retry bounds and deployment semantics.
