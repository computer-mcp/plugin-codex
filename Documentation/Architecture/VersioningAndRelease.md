# Versioning and Release

The root `computer-mcp-plugin.toml` owns the adapter's version.
`Scripts/version.py generate` derives `BuildInfo`; `check` is read-only and
rejects drift. `update --kind … --reason …` changes the manifest and
refreshes the constant. `check --base COMMIT` rejects version regression;
`check --tag vVERSION` verifies both the manifest version and the tag's commit.
CI checks the pull request base or previous main commit without changing files.
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
The `Validate and package` workflow runs the same source checks and publishes an
immutable CI candidate artifact. Check the relocated candidate with a standard
MCP client and `Scripts/check-workflow.py --adapter … --codex …`. The latter
uses an isolated home and fixed loopback model for native approvals, turns,
cancellation, reconnection and owned-process cleanup. It does not prove real
model authentication. Host integration uses the Computer MCP repository's fixed
installed-gateway checks against the exact adapter bytes.

Accept the complete host/plugin/SDK combination before delivery. Create a formal
signed tag only for the accepted commit; `upload-release.yml` promotes the
already-built artifact from its verified source run into the matching draft.
The upload also verifies the archive's manifest against the formal tag.
Candidate retries keep the intended product version and use a new run identity.
A public tag and archive remain immutable. Only changed components are released.
See [Installation](../Reference/Installation.md) for packaging, installation,
upgrade and rollback commands.

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
