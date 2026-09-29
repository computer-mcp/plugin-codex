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
$shippingPath = Join-Path $repository 'Package.resolved'
$shippingHash = (Get-FileHash $shippingPath -Algorithm SHA256).Hash
$shippingLock = Get-Content $shippingPath -Raw | ConvertFrom-Json
$sdkPin = @($shippingLock.pins | Where-Object { $_.identity -eq 'swift-codex' })
$mcpPin = @($shippingLock.pins | Where-Object { $_.identity -eq 'swift-sdk' })
if ($sdkPin.Count -ne 1 -or $sdkPin[0].state.revision -ne $sdkRevision -or
    $mcpPin.Count -ne 1 -or $mcpPin[0].location -ne 'https://github.com/computer-mcp/swift-sdk.git' -or
    $mcpPin[0].state.version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') {
    throw 'Host MCP checks require the shipping dependency identities'
}
if (Test-Path $OutputDirectory) { throw 'Host MCP tests require a fresh output directory' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$root = (Resolve-Path $OutputDirectory).Path
$evidence = Join-Path $root 'evidence'
$consumer = Join-Path $root 'consumer'
$sources = Join-Path $consumer 'Sources/HostPipe'
$tests = Join-Path $consumer 'Tests/HostPipeTests'
$childSources = Join-Path $consumer 'Sources/HostPipeFixture'
New-Item -ItemType Directory -Path $evidence, $sources, $tests, $childSources | Out-Null
$fixture = Join-Path $repository 'Tests/WindowsHostMCP'
$manifest = (Get-Content (Join-Path $fixture 'Package.swift.template') -Raw).Replace(
    '__MCP_URL__', $mcpPin[0].location).Replace('__MCP_VERSION__', $mcpPin[0].state.version)
$manifest | Set-Content (Join-Path $consumer 'Package.swift')
Copy-Item $shippingPath (Join-Path $consumer 'Package.resolved')
Copy-Item $shippingPath (Join-Path $evidence 'shipping-Package.resolved')
swift package --package-path $consumer resolve *> (Join-Path $evidence 'resolve.log')
if ($LASTEXITCODE -ne 0) { throw 'Host MCP consumer resolution failed' }
$consumerLock = Get-Content (Join-Path $consumer 'Package.resolved') -Raw | ConvertFrom-Json
foreach ($pin in $consumerLock.pins) {
    $expected = @($shippingLock.pins | Where-Object { $_.identity -eq $pin.identity })
    if ($expected.Count -ne 1 -or $pin.location -ne $expected[0].location -or
        $pin.state.revision -ne $expected[0].state.revision -or $pin.state.version -ne $expected[0].state.version) {
        throw "Host MCP consumer differs from shipping dependency: $($pin.identity)"
    }
}
if (@($consumerLock.pins | Where-Object { $_.identity -eq 'swift-sdk' }).Count -ne 1) {
    throw 'Host MCP consumer did not resolve the shipping MCP dependency'
}
Copy-Item (Join-Path $fixture 'HostPipeTests.swift') $tests
Copy-Item (Join-Path $fixture 'HostPipeFixture.swift') $childSources
Copy-Item (Join-Path $fixture 'HostProcess') (Join-Path $consumer 'Sources/HostProcess') -Recurse
Copy-Item (Join-Path $consumer 'Package.swift') $evidence
$source = Join-Path $repository 'Sources/CodexAdapter/MCPInheritedPipeTransport.swift'
$copy = Join-Path $sources 'MCPInheritedPipeTransport.swift'
Copy-Item $source $copy
Copy-Item $source $childSources
$sourceHash = (Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant()
if ((Get-FileHash $copy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash -or
    (Get-FileHash (Join-Path $childSources 'MCPInheritedPipeTransport.swift') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash) {
    throw 'Host transport source copy changed'
}
[pscustomobject]@{
    adapterRevision = $adapterRevision
    sdkRevision = $sdkRevision
    mcpDependency = $mcpPin[0]
    shippingLockSHA256 = $shippingHash.ToLowerInvariant()
    source = 'Sources/CodexAdapter/MCPInheritedPipeTransport.swift'
    sourceSHA256 = $sourceHash
    evidenceClass = 'native-inherited-host-mcp-transport'
    independentChild = $true
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
$originalFixture = $env:HOST_PIPE_FIXTURE_PATH
$results = @()
try {
    $env:PATH = "$testing;$xctest;$originalPath"
    foreach ($configuration in @('debug', 'release')) {
        $buildLog = Join-Path $evidence "$configuration-fixture.log"
        swift build --package-path $consumer --product HostPipeFixture -c $configuration --disable-automatic-resolution *> $buildLog
        $fixtureCode = $LASTEXITCODE
        if ($fixtureCode -ne 0) {
            Get-Content $buildLog -Tail 60
            $results += [pscustomobject]@{ configuration = $configuration; fixtureExitCode = $fixtureCode; testExitCode = $fixtureCode }
            $results | ConvertTo-Json | Set-Content (Join-Path $evidence 'results.json')
            continue
        }
        $binaryPath = swift build --package-path $consumer --show-bin-path -c $configuration
        if ($LASTEXITCODE -ne 0) { throw 'Cannot locate native child executable' }
        $env:HOST_PIPE_FIXTURE_PATH = Join-Path ($binaryPath | Select-Object -Last 1) 'HostPipeFixture.exe'
        if (!(Test-Path $env:HOST_PIPE_FIXTURE_PATH -PathType Leaf)) { throw 'Native child executable is missing' }
        $log = Join-Path $evidence "$configuration-tests.log"
        swift test --package-path $consumer --no-parallel -c $configuration --disable-automatic-resolution -Xswiftc -enable-testing *> $log
        $code = $LASTEXITCODE
        Get-Content $log -Tail 60
        $results += [pscustomobject]@{ configuration = $configuration; fixtureExitCode = $fixtureCode; testExitCode = $code }
        $results | ConvertTo-Json | Set-Content (Join-Path $evidence 'results.json')
    }
} finally {
    $env:PATH = $originalPath
    $env:HOST_PIPE_FIXTURE_PATH = $originalFixture
    $lock = Join-Path $consumer 'Package.resolved'
    if (Test-Path $lock) { Copy-Item $lock $evidence }
}
if ($results.Where({ $_.testExitCode -ne 0 }).Count -gt 0) { exit 1 }
if ((Get-FileHash $shippingPath -Algorithm SHA256).Hash -ne $shippingHash) {
    throw 'Shipping dependency lock changed during host MCP acceptance'
}
