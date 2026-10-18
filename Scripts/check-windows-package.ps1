param(
    [Parameter(Mandatory = $true)][string]$ArtifactDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$artifact = (Resolve-Path $ArtifactDirectory).Path
$root = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path $root) { throw 'Package acceptance requires a new output directory' }
$evidence = Join-Path $root 'evidence'
New-Item -ItemType Directory -Path $evidence | Out-Null
$receiptPath = Join-Path $artifact 'receipt.json'
$receipt = Get-Content $receiptPath -Raw | ConvertFrom-Json
if ($receipt.platform -ne 'windows' -or $receipt.configuration -ne 'release' -or
    $receipt.archive -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*\.zip$') {
    throw 'Expected a native Windows release package receipt'
}
$revision = git -C $repository rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify acceptance source' }
[pscustomobject]@{
    sourceRevision = $revision
    runnerImage = $env:ImageOS
    runnerImageVersion = $env:ImageVersion
    runnerOS = $env:RUNNER_OS
    runnerArchitecture = $env:RUNNER_ARCH
    existingSwiftCommands = @((Get-Command swift -All -ErrorAction SilentlyContinue).Source)
    swiftToolchainInstalledByThisJob = $false
    microsoftRuntime = 'system-installed prerequisite; native versions and module paths verified against the package receipt'
    pristineWindowsImage = $false
    sourceRebuilt = $false
    authenticatedModel = $false
} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidence 'inputs.json')
Copy-Item $receiptPath (Join-Path $evidence 'package-receipt.json')
$relocated = Join-Path $root 'relocated package 汉字'
python (Join-Path $PSScriptRoot 'check-package.py') --archive (Join-Path $artifact $receipt.archive) `
    --receipt $receiptPath --destination $relocated *> (Join-Path $evidence 'archive-check.json')
if ($LASTEXITCODE -ne 0) { throw 'Archive inventory, manifest or relocation verification failed' }

# This CLI is a private validation input and never becomes part of the plugin archive.
$fixture = Join-Path $repository 'Tests/WindowsAdapter'
$metadata = Get-Content (Join-Path $fixture 'codex-binary.json') -Raw | ConvertFrom-Json
Copy-Item (Join-Path $fixture 'codex-binary.json') $evidence
$codex = Join-Path $root 'codex'
New-Item -ItemType Directory -Path $codex | Out-Null
$archive = Join-Path $codex 'codex.zip'
Invoke-WebRequest -Uri $metadata.archiveURL -OutFile $archive -TimeoutSec 120 -MaximumRetryCount 2
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $metadata.archiveSHA256) {
    throw 'Native Codex archive checksum mismatch'
}
Expand-Archive -Path $archive -DestinationPath $codex
$codexBinary = Join-Path $codex $metadata.executable
if ((Get-FileHash $codexBinary -Algorithm SHA256).Hash.ToLowerInvariant() -ne $metadata.executableSHA256) {
    throw 'Native Codex executable checksum mismatch'
}
python (Join-Path $fixture 'ProtocolCheck.py') --adapter (Join-Path $relocated 'bin/codex-mcp-adapter.exe') `
    --codex $codexBinary --evidence-directory (Join-Path $evidence 'protocol') --app-local-runtime --package-receipt $receiptPath `
    *> (Join-Path $evidence 'protocol.log')
$code = $LASTEXITCODE
Get-Content (Join-Path $evidence 'protocol.log') -Tail 80
exit $code
