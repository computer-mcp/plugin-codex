param(
    [Parameter(Mandatory = $true)][string]$SDKRevision,
    [switch]$DatabaseOnly
)

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

$candidateDirectory = Join-Path $sdk 'Tests/DependencyCandidates/MCPTransport'
$metadata = Get-Content (Join-Path $candidateDirectory 'upstream.json') -Raw | ConvertFrom-Json
$patch = Join-Path $candidateDirectory 'windows-transports.patch'
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
    evidenceClass = if ($DatabaseOnly) { 'native-database-lifetime' } else { 'native-source-build-with-explicit-editable-candidates' }
    completeAdapter = -not $DatabaseOnly.IsPresent
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
$targets = if ($DatabaseOnly) { @('GRDB') } else {
    @('GRDB', 'Subprocess', 'ArgumentParser', 'MCP', 'CodexAppServerClient', 'CodexExec', 'CodexAdapter', 'CodexMCPAdapter')
}
foreach ($target in $targets) {
    $log = Join-Path $evidence "$target.log"
    swift build --target $target @buildArguments *> $log
    $code = $LASTEXITCODE
    Get-Content $log -Tail 50
    $results += [pscustomobject]@{ target = $target; exitCode = $code }
    $results | ConvertTo-Json | Set-Content (Join-Path $evidence 'results.json')
}
Copy-Item Package.resolved (Join-Path $evidence 'candidate-Package.resolved')

$runtimeExit = $null
if (!$DatabaseOnly -and $results.Where({ $_.target -eq 'CodexMCPAdapter' -and $_.exitCode -eq 0 }).Count -eq 1) {
    # Target compilation does not link an executable or prove resource lookup.
    swift build --product codex-mcp-adapter @buildArguments *> (Join-Path $evidence 'adapter-link.log')
    $linkExit = $LASTEXITCODE
    $runtimeExit = $linkExit
    [pscustomobject]@{ configuration = 'debug'; linkExitCode = $linkExit } |
        ConvertTo-Json | Set-Content (Join-Path $evidence 'linked-product-results.json')
    Get-Content (Join-Path $evidence 'adapter-link.log') -Tail 50
    if ($linkExit -eq 0) {
        $built = swift build --show-bin-path
        if ($LASTEXITCODE -ne 0) { throw 'Cannot locate linked adapter' }
        $product = Join-Path $evidence 'linked-product'
        New-Item -ItemType Directory -Path $product | Out-Null
        $binary = Join-Path $product 'codex-mcp-adapter.exe'
        Copy-Item (Join-Path $built 'codex-mcp-adapter.exe') $binary
        $resources = @(Get-ChildItem $built -Directory | Where-Object { $_.Name -match '\.(resources|bundle)$' })
        if ($resources.Count -eq 0) { throw 'Missing SwiftPM resource directory' }
        foreach ($resource in $resources) { Copy-Item $resource.FullName $product -Recurse }
        $inventory = @(Get-ChildItem $product -File -Recurse | ForEach-Object {
            [pscustomobject]@{
                path = [System.IO.Path]::GetRelativePath($product, $_.FullName)
                bytes = $_.Length
                sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
        $inventory | ConvertTo-Json | Set-Content (Join-Path $evidence 'linked-product-files.json')
        $inspector = Get-Command llvm-readobj -ErrorAction SilentlyContinue
        if ($inspector) {
            & $inspector.Source --coff-imports $binary *> (Join-Path $evidence 'adapter-imports.txt')
            if ($LASTEXITCODE -ne 0) { throw 'Native import inspection failed' }
        }
        & $binary --help *> (Join-Path $evidence 'adapter-help.txt')
        if ($LASTEXITCODE -ne 0) { throw 'Relocated native adapter help failed' }
        & $binary --version *> (Join-Path $evidence 'adapter-version.txt')
        if ($LASTEXITCODE -ne 0) { throw 'Relocated native adapter version failed' }

        $fixture = Join-Path $repository 'Tests/WindowsAdapter'
        $codexMetadata = Get-Content (Join-Path $fixture 'codex-binary.json') -Raw | ConvertFrom-Json
        Copy-Item (Join-Path $fixture 'codex-binary.json') $evidence
        $codexDirectory = Join-Path $root 'codex-binary'
        New-Item -ItemType Directory -Path $codexDirectory | Out-Null
        $codexArchive = Join-Path $codexDirectory 'codex.zip'
        Invoke-WebRequest -Uri $codexMetadata.archiveURL -OutFile $codexArchive -TimeoutSec 120 -MaximumRetryCount 2
        if ((Get-FileHash $codexArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $codexMetadata.archiveSHA256) {
            throw 'Native Codex archive checksum mismatch'
        }
        Expand-Archive -Path $codexArchive -DestinationPath $codexDirectory
        $codexBinary = Join-Path $codexDirectory $codexMetadata.executable
        if ((Get-FileHash $codexBinary -Algorithm SHA256).Hash.ToLowerInvariant() -ne $codexMetadata.executableSHA256) {
            throw 'Native Codex executable checksum mismatch'
        }
        $codexVersion = & $codexBinary --version
        if ($LASTEXITCODE -ne 0 -or $codexVersion -ne "codex-cli $($codexMetadata.version)") {
            throw 'Unexpected native Codex version'
        }
        [pscustomobject]@{
            version = $codexVersion
            executableSHA256 = (Get-FileHash $codexBinary -Algorithm SHA256).Hash.ToLowerInvariant()
            installed = $false
            bundled = $false
        } | ConvertTo-Json | Set-Content (Join-Path $evidence 'codex-binary-receipt.json')
        python (Join-Path $fixture 'ProtocolCheck.py') --adapter $binary --codex $codexBinary `
            --evidence-directory (Join-Path $evidence 'adapter-protocol') `
            *> (Join-Path $evidence 'adapter-protocol.log')
        $runtimeExit = $LASTEXITCODE
        Get-Content (Join-Path $evidence 'adapter-protocol.log') -Tail 60
        [pscustomobject]@{
            configuration = 'debug'
            linkExitCode = $linkExit
            protocolExitCode = $runtimeExit
            runtimeEnvironment = 'selected-toolchain'
            authenticatedModel = $false
            cleanMachineRelocation = $false
        } | ConvertTo-Json | Set-Content (Join-Path $evidence 'linked-product-results.json')
    }
}

$databaseExit = $null
if ($results.Where({ $_.target -eq 'GRDB' -and $_.exitCode -eq 0 }).Count -eq 1) {
    $consumer = Join-Path $root 'database-consumer'
    $tests = Join-Path $consumer 'Tests/DatabaseTests'
    New-Item -ItemType Directory -Path $tests | Out-Null
    $grdb = (Resolve-Path '.build/checkouts/GRDB.swift').Path
    $grdbRevision = git -C $grdb rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify resolved GRDB source' }
    $lock = Get-Content Package.resolved -Raw | ConvertFrom-Json
    $grdbPin = @($lock.pins | Where-Object { $_.identity -eq 'grdb.swift' })
    if ($grdbPin.Count -ne 1 -or $grdbPin[0].state.revision -ne $grdbRevision) {
        throw 'GRDB consumer source differs from the resolved lock'
    }
    $fixture = Join-Path $repository 'Tests/WindowsSQLite'
    $manifest = (Get-Content (Join-Path $fixture 'Package.swift.template') -Raw).Replace(
        '__GRDB_PATH__', $grdb.Replace('\', '/'))
    $manifest | Set-Content (Join-Path $consumer 'Package.swift')
    Copy-Item (Join-Path $fixture 'GRDBTests.swift') $tests
    Copy-Item (Join-Path $fixture 'DirectoryLifetimeTests.swift') $tests
    $directorySources = @()
    foreach ($name in @('WindowsPrivateDirectory.swift', 'WindowsFilePath.swift')) {
        $source = Join-Path $repository "Sources/CodexAdapter/$name"
        Copy-Item $source $tests
        $directorySources += [pscustomobject]@{
            source = "Sources/CodexAdapter/$name"
            sha256 = (Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $directorySources | ConvertTo-Json | Set-Content (Join-Path $evidence 'database-directory-sources.json')
    $grdbRevision | Set-Content (Join-Path $evidence 'grdb-revision.txt')
    Copy-Item (Join-Path $consumer 'Package.swift') (Join-Path $evidence 'database-Package.swift')

    $version = ((Get-Content (Join-Path $evidence 'toolchain.txt') -Raw) -split 'Swift version ')[1].Split(' ')[0].Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Cannot identify Swift testing runtime version' }
    $developer = Split-Path (Split-Path $env:SDKROOT.TrimEnd([char[]]'\/'))
    $testing = Join-Path $developer "Library/Testing-$version/usr/bin64"
    $xctest = Join-Path $developer "Library/XCTest-$version/usr/bin64"
    if (!(Test-Path (Join-Path $testing 'Testing.dll')) -or !(Test-Path (Join-Path $xctest 'XCTest.dll'))) {
        throw 'Missing selected SDK testing runtimes'
    }
    $originalPath = $env:PATH
    try {
        $env:PATH = "$testing;$xctest;$originalPath"
        swift test --package-path $consumer --no-parallel @buildArguments *> (Join-Path $evidence 'grdb-tests.log')
        $databaseExit = $LASTEXITCODE
        Get-Content (Join-Path $evidence 'grdb-tests.log') -Tail 50
    } finally {
        $env:PATH = $originalPath
    }
}
[pscustomobject]@{ grdbTestExitCode = $databaseExit } | ConvertTo-Json | Set-Content (Join-Path $evidence 'database-results.json')
if ($results.Where({ $_.exitCode -ne 0 }).Count -gt 0 -or $databaseExit -ne 0 -or
    (!$DatabaseOnly -and ($null -eq $runtimeExit -or $runtimeExit -ne 0))) { exit 1 }
