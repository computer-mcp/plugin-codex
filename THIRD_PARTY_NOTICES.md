# Third-party components

The adapter's original and extracted integration code is Computer MCP code
licensed under this repository's [LICENSE](LICENSE), FSL-1.1-ALv2.

| Component | Selected release | License |
| --- | --- | --- |
| swift-codex | 0.5.1 | Apache-2.0 WITH Swift-exception |
| MCP Swift SDK transport fork (`computer-mcp/swift-sdk`) | 0.13.2-computer-mcp.1 | Apache-2.0 and retained MIT contributions, with CC-BY-4.0 documentation, under the upstream licensing transition |

Swift Subprocess and other Swift dependencies retain their own upstream licenses. The packaging
script copies license and notice files from each pinned SwiftPM checkout into
`ThirdPartyNotices/`, together with the unchanged `Package.resolved`. This is a
resolved-dependency inventory, not a claim that every resolved product is linked.

Version-specific Codex App Server schema inputs are exported from OpenAI Codex.
Their provenance and digests live in `Sources/CodexAdapter/Resources/Protocol/receipt.json`.
The upstream Apache 2.0 license and applicable schema notice are included in
`ThirdPartyNotices/codex-protocol/`. No vendor Codex executable, credentials, or
user configuration is bundled.

An ad-hoc signature and checksum support local integrity checks. They do not
establish official publisher provenance, Developer ID signing, notarization, or
permission to publish this package.
