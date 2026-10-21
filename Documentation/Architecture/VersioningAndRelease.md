# Versioning and Release

The organization's
[VERSIONING.md](https://github.com/computer-mcp/.github/blob/master/VERSIONING.md)
owns shared SemVer, plugin API, dependency requirements, release contents and
recovery rules. This repository owns native acceptance and its documented
CI artifact promotion exception.

The root `computer-mcp-plugin.toml` declares `plugin_api = 1` and owns the adapter's version.
`Scripts/version.py generate` derives `BuildInfo`; `check` is read-only and
rejects drift. `update --kind … --reason …` changes the manifest and
refreshes the constant. `check --base COMMIT` rejects version regression when
HEAD has parents and the base is an available ancestor. Otherwise it checks the
current version only and reports why the comparison was skipped.
`check --tag vVERSION` verifies both the manifest version and the tag's commit.
CI checks the pull request base or previous `master` commit without changing files.
An actual packaged executable's `--version` must match
the byte-identical packaged manifest. Never infer a candidate version from an
installed adapter or another worktree.

Compatible fixes increment the patch. While the adapter is `0.x`, new public
capabilities and incompatible changes increment the minor; describe breaking
changes and migration in the release notes. Version arithmetic does not prove
compatibility: review and behavior tests support each declared bump. Documents,
CI and cleanup alone do not require a plugin release.

`Package.swift` declares the SDK compatibility requirement; `Package.resolved`
records the selected commit. The SDK's public tag owns its release identity.
`Scripts/verify-swift-codex-release-gate.sh` verifies this relationship instead
of introducing another SDK version declaration. The protocol import provenance
records the schema baseline. Integration receipts separately record the real
Codex executable version; these versions need not be equal.

`Scripts/package.py --output …` checks the declared/generated versions and lock,
builds the archive, validates its executable and emits a file/digest receipt.
The CI workflow (`ci.yml`) runs the same source checks and publishes an
immutable CI candidate artifact. Check the relocated candidate with a standard
MCP client and `Scripts/check-workflow.py --adapter … --codex …`. The latter
uses an isolated home and fixed loopback model for native approvals, turns,
cancellation, reconnection and owned-process cleanup. It does not prove real
model authentication. Host integration uses this repository's `Scripts/check-host.py` against the
installed Computer MCP CLI, relocated adapter bytes and installed vendor. Full
acceptance includes authenticated model execution; fixture-only evidence cannot
replace it. [Release](../Reference/Release.md#runtime-acceptance) owns the commands
and prerequisites.

Accept the complete host/plugin/SDK combination before delivery. Codex's native
builds cannot be reproduced byte for byte, so `release.yml` is the organization's
documented exception to its reusable release workflow. It promotes the accepted
CI archives and native build receipts without rebuilding. A dry run checks source,
latest successful CI attempt, artifact digests, manifest, `plugin_api`, archive
names and native inventories, and assembles the same content without tag checks,
Release writes or catalog secrets. Publication additionally requires a signed
annotated tag verified by GitHub at the accepted commit and matching the manifest
version. Repository release immutability must be verified enabled.

The schema 1 `release-receipt.json` follows the organization contract with
`reproduction: ci-artifact-promotion`, every source CI artifact, and each archive's
`native_receipt` name, size and SHA-256. Native `<archive-stem>.receipt.json`
files remain Release assets. Deterministic `SHA256SUMS` covers the archives,
native receipts and unified receipt. The receipt has no timestamps or local paths.

Verification has read-only contents/actions access and no secrets. Publication
alone has contents write permission and executes no builds. It checks the exact
verified bundle artifact ID, helper digest and asset digests, creates or resumes
a commit-bound draft, uploads the receipt first, then the archives and native
receipts, then checksums. It publishes only after every expected asset's API
size and digest matches and requires an immutable public Release. Only a separate
dependent catalog job receives the catalog secret.

A complete draft receipt freezes the original CI run, historical attempt,
artifact IDs/digests and release workflow ref/commit. Recovery refetches those
artifacts and reproduces the same receipt and checksums even after CI reruns.
Expected incomplete `starter` assets may be replaced only in a draft; completed
conflicts and unexpected names fail. If frozen artifacts expire, delete the
unpublished draft, obtain fresh successful CI artifacts and dispatch again.
A public Release is verified against its complete frozen asset set without
writes or reliance on CI retention. Notification failures need only the notifier
rerun. Candidate retries keep the intended version and use a new CI identity
only before provenance freezes or after deleting the unpublished draft.
`CHANGELOG.md` records each public release. See
[Installation](../Reference/Installation.md) for packaging, installation,
upgrade and rollback commands, and [Release](../Reference/Release.md) for
publication commands and recovery.

Reusable successful evidence must match source, dependency lock, check definition,
toolchain, target configuration and artifact digest. Missing or changed inputs
require the affected checks again. A source test is not installed-package proof.
Preserve failed attempts and distinguish fixture, product and external failures.
Regular checks and result judgment are scripted; a model does not approve release.

Temporary fixture directories and package staging belong to their creating run.
Delete only inactive, reconciled outputs; preserve unique content, necessary
failure/delivery evidence and the previous rollback package. Runtime databases,
credentials, existing user App Servers and unrelated source changes remain owned
by the user. Private run paths and progress stay outside normative documentation.
