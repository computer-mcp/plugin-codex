# Changelog

## Unreleased

### Added

- Public-host runtime acceptance for the packaged adapter and installed Codex,
  including native permissions, lifecycle recovery, thread handoff, authenticated
  model execution and exact owned-process cleanup.
- Runtime operations, diagnostics, ownership and troubleshooting guidance in the
  plugin manual.

### Changed

- Adapter databases initialize from one complete schema. Unknown migration
  histories fail explicitly and require a new state directory.

### Removed

- Windows support; the plugin ships only for macOS.
- Offline domain-state migration command and import workflow.

### Fixed

- Valid upstream Exec session identifiers are accepted by release builds.
