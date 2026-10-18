# Native host MCP transport validation

`Scripts/test-windows-host-mcp.ps1` copies the exact production inherited-pipe
transport, records its source hash, and resolves the versioned MCP dependency
from the shipping lock. Every selected dependency must match the shipping
location, version and revision. Swift 6.2.3 Windows debug/release tests
exercise actual anonymous pipes, standard MCP calls and exact integers,
endpoint ownership transfer, concurrent close/EOF, inherited-handle admission,
rejected environment/handle inputs and pre-cancelled receive cleanup.

An independent native child consumes the same production transport. The fixture
host launches it suspended, assigns an owned Job Object, and passes exactly the
paired callback handles plus separate standard streams through
`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`. Tests verify the native child PID, exact
integer callback, standard-stream isolation, exclusion of another inheritable
event, and peer EOF after terminating a child blocked in initialization. The
fixture host closes its child-side copies immediately after launch.

These tests exercise native launch and transport ownership. They do not claim
a complete adapter artifact, a Windows Computer MCP host application, or
authenticated model execution. The process suite independently checks that
callback metadata is stripped from vendor environments.

Run with an unchanged SDK checkout matching the shipping lock and a fresh output directory:

```powershell
./Scripts/test-windows-host-mcp.ps1 -SDKPath <sdk-checkout> -OutputDirectory <new-output>
```

The validation workflow accepts `windows_validation_scope: host-mcp` with an
exact locked SDK revision to run this gate independently. Its default `all`
scope retains the complete source, database, process and transport checks.
