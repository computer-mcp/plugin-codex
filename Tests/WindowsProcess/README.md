# Native adapter process tests

`Scripts/test-windows-process.ps1 -SDKPath SDK_CHECKOUT -OutputDirectory OUTPUT`
stages the exact production Windows process source and records its hashes. It
uses the complete swift-codex checkout and that SDK's native process fixture.
Run it on Windows with the selected Swift toolchain. The output directory must
be new; the script restores its temporary environment settings.

Debug and release test EOF completion, cancelled/concurrent shutdown callers,
blocked stdin, configured frame bounds, natural root exit with descendants,
external-owner death, and rejection of a terminated owner before child launch.
Observations retain exact native process handles and check sibling isolation.

Finite-command tests also exercise synchronous execution, argument quoting,
Unicode working directories, environment overrides, stdin EOF, bounded output
with continued drain, and descendant cleanup after cancellation, timeout and
natural exit. Codex discovery and finite commands use the same Windows path and
environment rules. Each test retains its own native process observations.

Private state tests inspect actual owner SIDs and protected DACLs, inherited
file permissions, directory replacement during retained ownership, and refusal
of reparses, foreign owners and existing broader permissions. The separate
GRDB audit verifies that connection configuration retains the production
directory guard through close and release.

These tests verify the adapter's lifecycle boundary. The complete adapter and
all dependency targets retain their separate source audit. Fixture results do
not establish standard-MCP packaging or authenticated model acceptance.
