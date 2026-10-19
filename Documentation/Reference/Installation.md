# Installation and recovery

The macOS package owns `bin/codex-mcp-adapter` and its adjacent
`codex-plugin_CodexAdapter.bundle`. Codex itself remains an external dependency.

Installing this package never installs, updates or removes Codex, changes global
PATH, or grants a profile access to tools.

## Produce a local artifact

From this independent repository, with Python 3.11 or newer and its Swift
dependencies already resolved:

```sh
python3 Scripts/package.py --output /absolute/new/artifact-directory
```

The default build is release; `--configuration debug` is available for development.
The destination must not exist. The script builds using the pinned dependency
resolution, copies the executable and resources, collects upstream license and
notice files, and emits the native archive and `receipt.json`. The executable
receives an ad-hoc signature. The receipt records
each file and archive SHA-256, platform, architecture and build configuration.
It is not an official-source or publisher signature.
No artifact is uploaded or installed automatically.

The repository manifest declares `codex-plugin-macos-arm64.zip`. Packaging
requires the built adapter to match the declared platform and architecture.
The archive carries the repository's exact manifest bytes; its `platform_paths`
selects the executable. The manifest's `minimum_host` declares the required
Computer MCP version. Official GitHub installation verifies the archive
manifest against its release tag.
See [third-party components](../../THIRD_PARTY_NOTICES.md) for distribution terms.

Package inputs must be regular files and directories. Symbolic links and special
files are rejected before signing or running the staged adapter. The output is
published atomically without replacing any existing destination, including an
empty directory created while the build is running. Failure removes only the
packager's temporary staging directory; existing outputs remain unchanged.

The repository's CI workflow (`ci.yml`) runs on pull requests, `master` pushes
and manual dispatch. It checks formatting, tests and the dependency lock, then
retains the macOS ZIP and receipt as a downloadable workflow artifact. CI verifies
and relocates the exact archive with `Scripts/check-package.py`. These outputs
are validation builds, not published or verified official releases.
Check the receipt's architecture before installation. Public distribution needs
separate publisher authorization and its signing/provenance review.

## Install and configure

Use the App's plugin install action or the owner-only management CLI. Obtain
the current revision from `computer-mcp plugins list`, then supply the digest
from the artifact receipt:

```sh
computer-mcp plugins install /absolute/path/ARCHIVE.zip --id codex --version VERSION --sha256 DIGEST --expected-revision REVISION
```

The new package is disabled and exposes no tools. In its settings, choose the
MCP contribution `app-server`, select the intended tool whitelist or all tools,
and set startup arguments to individual values:

```json
{
  "enabled": true,
  "mcp": {
    "app-server": {
      "exposure": "reexport",
      "prefix": "codex-adapter",
      "allowAnyTool": true,
      "hostServices": true,
      "args": [
        "--config", "/absolute/path/to/codex.json",
        "--state-directory", "/absolute/path/to/adapter-state"
      ]
    }
  }
}
```

This is an explicit local all-tools choice, including future additions; choose
`allowedTools` instead when that is not intended. Profile and workspace grants
remain separate host decisions. `hostServices` delegates the current connection's
scope over a private inherited MCP endpoint, not local-admin authority; leave it
false for an adapter that does not require callbacks. See
[host integration](HostIntegration.md). The configuration file contains the existing
Codex settings described in the root manual; `CODEX_HOME` selects vendor state
through the registered environment. Never put credentials in arguments.

For the CLI, save the settings JSON and use `plugins configure codex
--settings-file /absolute/path/settings.json --expected-revision REVISION`.
Start from the current saved settings when editing; configure replaces the
whole settings object. Setting `args` to null follows package defaults, while
an empty array starts the adapter in protocol-inspection mode. App changes and
CLI changes use the same host transaction and stale-revision protection.

Use `plugins doctor codex` for package/file checks. A successful report is not
a model-authentication or complete-workflow readiness claim. Discovery itself
does not launch Codex. Host launch metadata binds the workspace and read-only
boundary when serving through Computer MCP.

## Stop, update, roll back and remove

Configuration and installation changes publish a new runtime generation.
Existing work retains its creating runtime and package files until its owner
confirms completion; new work uses the current configuration. Current grants
and workspace access are checked on each invocation. Disabling a plugin closes
admission for new work while preserving the ownership needed to inspect or
cancel existing work. Explicitly cancel work when it should stop.

Install an updated artifact through the same command. Saved arguments, exposure
and profile grants are not reset. Select a retained installation with `plugins
select codex --installation-id ID --expected-revision REVISION` to roll back.
`plugins disable codex` retains settings and files; `plugins uninstall ID`
removes only that installation's owned files and contributions. Both take the
current `--expected-revision`. Inspect reported cleanup issues and use `plugins
recover` for recovery rather than repeating an uncertain installation.

Add `--control-socket /absolute/isolated/socket` to every management command
when operating a disposable test host. Without it these commands target the
normal App. Preserve the configured adapter state directory during an update
or rollback; uninstalling a package artifact does not authorize deleting
independently configured execution records or vendor state.
