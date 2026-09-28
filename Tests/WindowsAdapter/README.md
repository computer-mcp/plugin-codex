# Linked native adapter acceptance

The complete Windows candidate audit links `codex-mcp-adapter.exe`, copies the
executable and actual SwiftPM resource directories to a new path, records their
hashes, and runs help, version and the standard MCP protocol check. The native
Codex release archive is pinned by checksum and used only in the disposable
candidate; it is neither installed nor included in the plugin payload.

`ProtocolCheck.py` uses the existing workflow's standard MCP client with two
successive adapter connections, isolated homes and no inherited credentials.
It verifies catalog/resource discovery, database availability, real App Server
thread creation, creator correlation, process ownership, idempotent runtime stop,
joined native exit, work retirement and MCP EOF. On Windows, a synchronization
handle retains each observed process identity through shutdown. It does not
start model turns or establish authenticated-model acceptance.

The selected Swift toolchain supplies runtime DLL lookup through PATH. This
check is independent of the release archive and clean-machine runtime contract;
it does not establish that an artifact contains all redistributable libraries.
The same protocol check can run on macOS against existing candidate executables
to validate its platform-neutral assertions.
