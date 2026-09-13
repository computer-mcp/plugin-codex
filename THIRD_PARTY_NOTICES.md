# Third-party components

The adapter retains the Computer MCP source-visible license for extracted and
original integration code. Moving that code into this repository does not
change its ownership or grant additional distribution rights.

The official MCP Swift SDK and swift-codex are MIT-licensed. Swift Subprocess
and other Swift dependencies retain their own upstream licenses. The packaging
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
