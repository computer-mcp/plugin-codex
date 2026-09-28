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
if ($LASTEXITCODE -ne 0) { throw 'Native process tests require an unchanged committed SDK candidate' }
$adapterRevision = git -C $repository rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify adapter source' }
if (Test-Path $OutputDirectory) { throw 'Native process tests require a fresh output directory' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$root = (Resolve-Path $OutputDirectory).Path
$evidence = Join-Path $root 'evidence'
$consumer = Join-Path $root 'consumer'
$sources = Join-Path $consumer 'Sources/ManagedProcess'
$tests = Join-Path $consumer 'Tests/ManagedProcessTests'
New-Item -ItemType Directory -Path $evidence, $sources, $tests | Out-Null
$fixture = Join-Path $repository 'Tests/WindowsProcess'
$manifest = (Get-Content (Join-Path $fixture 'Package.swift.template') -Raw).Replace(
    '__SDK_PATH__', $sdk.Replace('\', '/').Replace('"', '\"'))
$manifest | Set-Content (Join-Path $consumer 'Package.swift')
Copy-Item (Join-Path $fixture 'ManagedProcessTests.swift') $tests
Copy-Item (Join-Path $fixture 'CommandRunnerTests.swift') $tests
Copy-Item (Join-Path $fixture 'PrivateDirectoryTests.swift') $tests
Copy-Item (Join-Path $fixture 'WorktreeFileSystemTests.swift') $tests
Copy-Item (Join-Path $consumer 'Package.swift') $evidence
$sourceRecords = @()
foreach ($name in @(
    'ManagedLineProcess.swift', 'ManagedLineProcess+Windows.swift',
    'CommandRunner.swift', 'CommandRunner+Windows.swift', 'WindowsCommandProcess.swift',
    'WindowsProcessJob.swift', 'WindowsFilePath.swift', 'WindowsExecutable.swift',
    'WindowsProcessEnvironment.swift', 'CodexConfig.swift', 'JSONValue.swift',
    'WindowsPrivateDirectory.swift', 'CodexWorktreeFileSystem.swift'
)) {
    $source = Join-Path $repository "Sources/CodexAdapter/$name"
    Copy-Item $source $sources
    $sourceRecords += [pscustomobject]@{
        source = "Sources/CodexAdapter/$name"
        sha256 = (Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
[pscustomobject]@{
    sdkRevision = $sdkRevision
    adapterRevision = $adapterRevision
    sourceFiles = $sourceRecords
    evidenceClass = 'native-adapter-lifecycle-using-complete-sdk-source'
    authenticatedModel = $false
    completeAdapter = $false
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
$originalFixture = $env:CODEX_WINDOWS_FIXTURE
$results = @()
try {
    $env:PATH = "$testing;$xctest;$originalPath"
    foreach ($configuration in @('debug', 'release')) {
        $fixturePackage = Join-Path $sdk 'Tests/WindowsIntegration'
        swift build --package-path $fixturePackage --product CodexProcessFixture -c $configuration *> (Join-Path $evidence "$configuration-fixture.log")
        $fixtureExit = $LASTEXITCODE
        $testExit = $null
        if ($fixtureExit -eq 0) {
            $binaryDirectory = swift build --package-path $fixturePackage -c $configuration --show-bin-path
            if ($LASTEXITCODE -ne 0) { throw 'Cannot locate native fixture' }
            $env:CODEX_WINDOWS_FIXTURE = Join-Path $binaryDirectory 'CodexProcessFixture.exe'
            if (!(Test-Path $env:CODEX_WINDOWS_FIXTURE)) { throw 'Native fixture missing' }
            swift test --package-path $consumer --no-parallel -c $configuration *> (Join-Path $evidence "$configuration-tests.log")
            $testExit = $LASTEXITCODE
            Get-Content (Join-Path $evidence "$configuration-tests.log") -Tail 55
        } else {
            Get-Content (Join-Path $evidence "$configuration-fixture.log") -Tail 55
        }
        $results += [pscustomobject]@{
            configuration = $configuration
            fixtureExitCode = $fixtureExit
            testExitCode = $testExit
        }
        $results | ConvertTo-Json | Set-Content (Join-Path $evidence 'results.json')
    }
} finally {
    $env:PATH = $originalPath
    $env:CODEX_WINDOWS_FIXTURE = $originalFixture
}
if ($results.Where({ $_.fixtureExitCode -ne 0 -or $null -eq $_.testExitCode -or $_.testExitCode -ne 0 }).Count -gt 0) {
    exit 1
}
