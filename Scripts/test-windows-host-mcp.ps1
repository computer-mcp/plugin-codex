param(
    [Parameter(Mandatory = $true)][string]$SDKPath,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sdk = (Resolve-Path $SDKPath).Path
$sdkRevision = git -C $sdk rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $sdkRevision -cnotmatch '^[0-9a-f]{40}$') { throw 'Cannot identify SDK source' }
git -C $sdk diff --quiet HEAD
if ($LASTEXITCODE -ne 0) { throw 'Host MCP tests require an unchanged committed SDK candidate' }
$adapterRevision = git -C $repository rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify adapter source' }
if (Test-Path $OutputDirectory) { throw 'Host MCP tests require a fresh output directory' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$root = (Resolve-Path $OutputDirectory).Path
$evidence = Join-Path $root 'evidence'
$consumer = Join-Path $root 'consumer'
$sources = Join-Path $consumer 'Sources/HostPipe'
$tests = Join-Path $consumer 'Tests/HostPipeTests'
New-Item -ItemType Directory -Path $evidence, $sources, $tests | Out-Null
$candidateDirectory = Join-Path $sdk 'Tests/DependencyCandidates/MCPTransport'
$metadata = Get-Content (Join-Path $candidateDirectory 'upstream.json') -Raw | ConvertFrom-Json
$patch = Join-Path $candidateDirectory 'windows-transports.patch'
if ((Get-FileHash $patch -Algorithm SHA256).Hash.ToLowerInvariant() -ne $metadata.patchSHA256) {
    throw 'MCP candidate checksum mismatch'
}
$mcp = Join-Path $root 'swift-sdk'
git -c core.autocrlf=false clone --no-checkout $metadata.repository $mcp
if ($LASTEXITCODE -ne 0) { throw 'MCP source clone failed' }
git -C $mcp checkout --detach $metadata.revision
if ($LASTEXITCODE -ne 0) { throw 'MCP source checkout failed' }
$actualMCP = git -C $mcp rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actualMCP -ne $metadata.revision) { throw 'MCP source revision mismatch' }
git -C $mcp apply --check $patch
if ($LASTEXITCODE -ne 0) { throw 'MCP patch does not apply' }
git -C $mcp apply $patch
if ($LASTEXITCODE -ne 0) { throw 'MCP patch application failed' }
Copy-Item $patch $evidence

$fixture = Join-Path $repository 'Tests/WindowsHostMCP'
$manifest = (Get-Content (Join-Path $fixture 'Package.swift.template') -Raw).Replace(
    '__MCP_PATH__', $mcp.Replace('\', '/').Replace('"', '\"'))
$manifest | Set-Content (Join-Path $consumer 'Package.swift')
Copy-Item (Join-Path $fixture 'HostPipeTests.swift') $tests
Copy-Item (Join-Path $consumer 'Package.swift') $evidence
$source = Join-Path $repository 'Sources/CodexAdapter/MCPInheritedPipeTransport.swift'
$copy = Join-Path $sources 'MCPInheritedPipeTransport.swift'
Copy-Item $source $copy
$sourceHash = (Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant()
if ((Get-FileHash $copy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash) {
    throw 'Host transport source copy changed'
}
[pscustomobject]@{
    adapterRevision = $adapterRevision
    sdkRevision = $sdkRevision
    mcpCandidate = $metadata
    source = 'Sources/CodexAdapter/MCPInheritedPipeTransport.swift'
    sourceSHA256 = $sourceHash
    evidenceClass = 'native-inherited-host-mcp-transport'
    completeAdapter = $false
    authenticatedModel = $false
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $evidence 'inputs.json')

$versionOutput = swift --version
if ($LASTEXITCODE -ne 0) { throw 'Swift unavailable' }
$versionOutput | Set-Content (Join-Path $evidence 'toolchain.txt')
$version = (($versionOutput -join "`n") -split 'Swift version ')[1].Split(' ')[0].Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Cannot identify Swift testing runtime version' }
$developer = Split-Path (Split-Path $env:SDKROOT.TrimEnd([char[]]'\/'))
$testing = Join-Path $developer "Library/Testing-$version/usr/bin64"
$xctest = Join-Path $developer "Library/XCTest-$version/usr/bin64"
if (!(Test-Path (Join-Path $testing 'Testing.dll')) -or !(Test-Path (Join-Path $xctest 'XCTest.dll'))) {
    throw 'Missing selected SDK testing runtimes'
}
$originalPath = $env:PATH
$results = @()
try {
    $env:PATH = "$testing;$xctest;$originalPath"
    foreach ($configuration in @('debug', 'release')) {
        $log = Join-Path $evidence "$configuration-tests.log"
        swift test --package-path $consumer --no-parallel -c $configuration -Xswiftc -enable-testing *> $log
        $code = $LASTEXITCODE
        Get-Content $log -Tail 60
        $results += [pscustomobject]@{ configuration = $configuration; testExitCode = $code }
        $results | ConvertTo-Json | Set-Content (Join-Path $evidence 'results.json')
    }
} finally {
    $env:PATH = $originalPath
    $lock = Join-Path $consumer 'Package.resolved'
    if (Test-Path $lock) { Copy-Item $lock $evidence }
}
if ($results.Where({ $_.testExitCode -ne 0 }).Count -gt 0) { exit 1 }
