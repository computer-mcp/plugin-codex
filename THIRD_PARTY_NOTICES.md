# Third-party components

The adapter retains the Computer MCP source-visible license for extracted and
original integration code. Moving that code into this repository does not
change its ownership or grant additional distribution rights.

The MCP Swift SDK transport fork and swift-codex are MIT-licensed. Swift Subprocess
and other Swift dependencies retain their own upstream licenses. The packaging
script copies license and notice files from each pinned SwiftPM checkout into
`ThirdPartyNotices/`, together with the unchanged `Package.resolved`. This is a
resolved-dependency inventory, not a claim that every resolved product is linked.

Version-specific Codex App Server schema inputs are exported from OpenAI Codex.
Their provenance and digests live in `Sources/CodexAdapter/Resources/Protocol/receipt.json`.
The upstream Apache 2.0 license and applicable schema notice are included in
`ThirdPartyNotices/codex-protocol/`. No vendor Codex executable, credentials, or
user configuration is bundled.

Windows archives include the required Swift runtime DLLs alongside the adapter.
`ThirdPartyNotices/windows-runtime/` preserves the original Swift, Foundation,
libdispatch, ICU, string-processing, curl and zlib notices. Its `sources.json`
binds those texts to upstream commits and maps runtime libraries to notices.
`ThirdPartyNotices/sqlite/` retains the original SQLite header with its
public-domain statement and the pinned source identity. The package receipt
separately binds the selected runtime DLLs and compiled SQLite library.

Microsoft Visual C++ runtime files retain their separate Microsoft redistribution
terms. The applicable publisher license must permit redistribution; their
presence in the Swift toolchain does not establish that permission. See the
[Microsoft redistribution guidance](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files?view=msvc-170).

An ad-hoc signature and checksum support local integrity checks. They do not
establish official publisher provenance, Developer ID signing, notarization, or
permission to publish this package.
