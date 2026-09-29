# Swift Windows runtime notices

This directory preserves original notices for the open-source components in the
Swift Windows runtime used by the native adapter build. `sources.json` binds each
file to its source repository, release tag, exact commit, original path, length
and SHA256. The runtime files selected for an archive have their own native
import and byte inventory; the notice source list is not a binary inventory.

The notice set covers Swift, libdispatch, Foundation, FoundationICU and the Swift
string-processing library. Swift's Windows build also links curl and zlib into
FoundationNetworking. Their original notices are included alongside the
Foundation third-party NOTICE and ICU's original third-party notices.

FoundationICU identifies ICU74.1 in its vendored version header and describes
extraction from Apple OSS ICU. The supplemental Apple ICU notice records its own
source tag; it does not identify an exact Apple extraction revision for the
FoundationICU sources. Preserve these original texts together with the Foundation
wrapper license.

These files cover the listed open-source components. Microsoft Visual C++ runtime
files have separate Microsoft license and redistribution terms. Their presence
in a Swift toolchain does not make them subject to Swift's license.

Source references:

- [Swift Windows build](https://github.com/swiftlang/swift/blob/swift-6.2.3-RELEASE/utils/build.ps1)
- [FoundationICU source and version](https://github.com/swiftlang/swift-foundation-icu/tree/swift-6.2.3-RELEASE)
- [Microsoft runtime redistribution](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files?view=msvc-170)
