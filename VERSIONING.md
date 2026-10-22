# Versioning

This repository adopts the organization's
[VERSIONING.md](https://github.com/computer-mcp/.github/blob/master/VERSIONING.md)
with the following differences.

## Native artifact promotion

Codex's native archives cannot be reproduced byte for byte. This repository
uses its own release workflow to promote accepted CI archives and native build
receipts under the organization's Codex promotion contract, with
`reproduction: ci-artifact-promotion`, instead of the reusable rebuild workflow.

## Release notes

Breaking changes include migration guidance in the Release notes.

The [release reference](Documentation/Reference/Release.md) owns this
repository's release facts, mechanics and checks.
