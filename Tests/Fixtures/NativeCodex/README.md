# Native Codex model fixture

`ModelServer.py` serves a private loopback Responses endpoint and network token.
It never executes commands. `Scripts/check-host.py` owns its input recipes,
workspaces, network token, process and native Codex generations. Each recipe
issues at most one native `exec_command` call using a non-login shell. Exact
`function_call_output` receipts are correlated to the issued call ID and checked
against independent filesystem, Git and network observations. HTTP authentication
is rejected. The service exits on stdin EOF.

A held response leaves a native turn unfinished after its command result, so
acceptance can exercise cancellation and recovery without replaying a write.
The driver verifies process ancestry before failure injection and waits for all
receipted processes to exit. See [Release](../../../Documentation/Reference/Release.md#runtime-acceptance)
for full and fixture-only acceptance.

Fixture provenance: Computer MCP commit
`65921cd298783003895106b293fa6dd540e47313`,
`Tests/ComputerMCPTests/Fixtures/NativeCodex/ModelServer.py`.

`HostToolVendor.py` is a disposable protocol peer for native `item/tool/call`
forwarding. It reads queued requests from its private vendor home and records
exact replies and descriptor/environment isolation. It exercises the real
adapter and public host MCP; it does not impersonate an authenticated model.
The driver owns the Git repository and verifies tickets, side effects and
native callback results separately. This peer adapts the `vendorSource` in the
same source commit's `CodexPluginHostIntegrationTests.swift`.
