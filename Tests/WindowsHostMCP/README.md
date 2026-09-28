# Native host MCP transport validation

`Scripts/test-windows-host-mcp.ps1` copies the exact production inherited-pipe
transport, records its source hash, and consumes the full checksummed MCP
candidate from the selected SDK commit. Swift 6.2.3 Windows debug/release tests
exercise actual anonymous pipes, standard MCP calls and exact integers,
endpoint ownership transfer, concurrent close/EOF, inherited-handle admission,
rejected environment/handle inputs and pre-cancelled receive cleanup.

The test process duplicates inheritable handles to exercise child-side admission.
Host process creation and its explicit inheritance list require separate launch
acceptance; this suite does not claim that launch, a complete adapter artifact,
or authenticated model execution. The process suite independently checks that
callback metadata is stripped from vendor environments.

Run with an unchanged SDK candidate checkout and a fresh output directory:

```powershell
./Scripts/test-windows-host-mcp.ps1 -SDKPath <sdk-checkout> -OutputDirectory <new-output>
```
