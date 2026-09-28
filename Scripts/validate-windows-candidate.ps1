param([Parameter(Mandatory = $true)][string]$SDKRevision)

$ErrorActionPreference = 'Stop'
if ($SDKRevision -cnotmatch '^[0-9a-f]{40}$') { throw 'SDK candidate must be an exact commit SHA' }
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repository
$root = Join-Path $repository '.build/windows-candidate'
if (Test-Path $root) { throw 'Windows source audit requires a fresh candidate directory' }
$evidence = Join-Path $root 'evidence'
New-Item -ItemType Directory -Path $evidence | Out-Null
$sdk = Join-Path $root 'swift-codex'
$mcp = Join-Path $root 'swift-sdk'
swift --version | Out-File (Join-Path $evidence 'toolchain.txt')
if ($LASTEXITCODE -ne 0) { throw 'Swift toolchain unavailable' }

git clone --no-checkout https://github.com/swift-library/swift-codex.git $sdk
if ($LASTEXITCODE -ne 0) { throw 'SDK candidate clone failed' }
git -C $sdk checkout --detach $SDKRevision
if ($LASTEXITCODE -ne 0) { throw 'SDK candidate checkout failed' }
$actualSDK = git -C $sdk rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actualSDK -ne $SDKRevision) { throw 'SDK candidate revision mismatch' }

$candidateDirectory = Join-Path $sdk 'Tests/DependencyCandidates/MCPHTTP'
$metadata = Get-Content (Join-Path $candidateDirectory 'upstream.json') -Raw | ConvertFrom-Json
$patch = Join-Path $candidateDirectory 'eventsource-availability.patch'
if ((Get-FileHash $patch -Algorithm SHA256).Hash.ToLowerInvariant() -ne $metadata.patchSHA256) {
    throw 'MCP candidate patch checksum mismatch'
}
git clone --no-checkout $metadata.repository $mcp
if ($LASTEXITCODE -ne 0) { throw 'MCP candidate clone failed' }
git -C $mcp checkout --detach $metadata.revision
if ($LASTEXITCODE -ne 0) { throw 'MCP candidate checkout failed' }
$actualMCP = git -C $mcp rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actualMCP -ne $metadata.revision) { throw 'MCP candidate revision mismatch' }
git -C $mcp apply --check $patch
if ($LASTEXITCODE -ne 0) { throw 'MCP patch does not apply' }
git -C $mcp apply $patch
if ($LASTEXITCODE -ne 0) { throw 'MCP patch application failed' }
$adapterRevision = git rev-parse HEAD
[pscustomobject]@{
    adapterRevision = $adapterRevision
    sdkCandidateRevision = $actualSDK
    mcpCandidate = $metadata
    evidenceClass = 'native-source-build-with-explicit-editable-candidates'
    shippingDependenciesChanged = $false
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $evidence 'inputs.json')
Copy-Item Package.resolved (Join-Path $evidence 'shipping-Package.resolved')

swift package resolve *> (Join-Path $evidence 'resolve.log')
if ($LASTEXITCODE -ne 0) { throw 'Shipping dependency resolution failed' }
git diff --exit-code -- Package.resolved
if ($LASTEXITCODE -ne 0) { throw 'Shipping dependency lock changed' }
swift package edit swift-codex --path $sdk *> (Join-Path $evidence 'edit-sdk.log')
if ($LASTEXITCODE -ne 0) { throw 'SDK editable candidate admission failed' }
swift package edit swift-sdk --path $mcp *> (Join-Path $evidence 'edit-mcp.log')
if ($LASTEXITCODE -ne 0) { throw 'MCP editable candidate admission failed' }

$sqlite = & (Join-Path $PSScriptRoot 'build-windows-sqlite.ps1') -OutputDirectory (Join-Path $evidence 'sqlite')
$buildArguments = @('-Xcc', "-I$($sqlite.includeDirectory)", '-Xlinker', "/LIBPATH:$($sqlite.libraryDirectory)")
$results = @()
foreach ($target in @('GRDB', 'Subprocess', 'ArgumentParser', 'MCP', 'CodexAppServerClient', 'CodexExec', 'CodexAdapter', 'CodexMCPAdapter')) {
    $log = Join-Path $evidence "$target.log"
    swift build --target $target @buildArguments *> $log
    $code = $LASTEXITCODE
    Get-Content $log -Tail 50
    $results += [pscustomobject]@{ target = $target; exitCode = $code }
    $results | ConvertTo-Json | Set-Content (Join-Path $evidence 'results.json')
}
Copy-Item Package.resolved (Join-Path $evidence 'candidate-Package.resolved')
if ($results.Where({ $_.exitCode -ne 0 }).Count -gt 0) { exit 1 }
