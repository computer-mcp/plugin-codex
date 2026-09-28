param(
    [Parameter(Mandatory = $true)][string]$SourceRun,
    [Parameter(Mandatory = $true)][string]$SDKRevision
)
$ErrorActionPreference = 'Stop'
if ($SourceRun -cnotmatch '^[0-9]+$' -or $SDKRevision -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Native artifact acceptance requires a run ID and exact SDK revision'
}
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repository
$root = Join-Path $repository '.build/windows-artifact'
if (Test-Path $root) { throw 'Artifact acceptance requires a new output directory' }
$evidence = Join-Path $root 'evidence'
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$runJSON = gh api "repos/$env:GITHUB_REPOSITORY/actions/runs/$SourceRun"
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect source run' }
$run = $runJSON | ConvertFrom-Json
if ($run.status -ne 'completed' -or $run.path -ne '.github/workflows/validate.yml' -or
    $run.head_repository.full_name -ne $env:GITHUB_REPOSITORY -or $run.head_sha -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Source must be a completed validation run from this repository'
}
$runJSON | Set-Content (Join-Path $evidence 'source-run.json')
$name = "codex-plugin-windows-source-$SourceRun-$($run.run_attempt)"
$download = Join-Path $root 'source-artifact'
gh run download $SourceRun --repo $env:GITHUB_REPOSITORY --name $name --dir $download
if ($LASTEXITCODE -ne 0) { throw 'Cannot download selected source artifact' }
$inputs = Get-Content (Join-Path $download 'inputs.json') -Raw | ConvertFrom-Json
$link = Get-Content (Join-Path $download 'linked-product-results.json') -Raw | ConvertFrom-Json
if ($inputs.adapterRevision -ne $run.head_sha -or $inputs.sdkCandidateRevision -ne $SDKRevision -or
    !$inputs.completeAdapter -or $link.linkExitCode -ne 0) {
    throw 'Artifact does not bind the requested complete linked adapter and SDK'
}
$product = (Resolve-Path (Join-Path $download 'linked-product')).Path
$files = @(Get-Content (Join-Path $download 'linked-product-files.json') -Raw | ConvertFrom-Json)
$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in $files) {
    if ([IO.Path]::IsPathRooted($file.path) -or $file.path.Contains(':') -or
        @($file.path -split '[/\\]' | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or
        !$seen.Add($file.path)) { throw 'Invalid artifact inventory path' }
    $path = Join-Path $product $file.path
    $item = Get-Item $path
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -ne $file.bytes -or
        (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) {
        throw 'Linked payload differs from its source inventory'
    }
}
if (@(Get-ChildItem $product -Recurse -File).Count -ne $files.Count -or
    @(Get-ChildItem $product -Recurse | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
    throw 'Linked payload contains undeclared or linked files'
}
Copy-Item (Join-Path $download 'inputs.json') $evidence
Copy-Item (Join-Path $download 'linked-product-files.json') $evidence
swift --version | Set-Content (Join-Path $evidence 'toolchain.txt')
if ($LASTEXITCODE -ne 0) { throw 'Swift runtime environment unavailable' }
$definitionRevision = git rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify check definition' }
[pscustomobject]@{
    sourceRun = $SourceRun
    sourceArtifact = $name
    adapterRevision = $inputs.adapterRevision
    sdkRevision = $SDKRevision
    checkRevision = $definitionRevision
    linkedFilesVerified = $files.Count
    sourceRebuilt = $false
    cleanMachineRelocation = $false
    authenticatedModel = $false
} | ConvertTo-Json | Set-Content (Join-Path $evidence 'acceptance-inputs.json')
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
python (Join-Path $fixture 'ProtocolCheck.py') --adapter (Join-Path $product 'codex-mcp-adapter.exe') `
    --codex $codexBinary --evidence-directory (Join-Path $evidence 'protocol') `
    *> (Join-Path $evidence 'protocol.log')
$code = $LASTEXITCODE
Get-Content (Join-Path $evidence 'protocol.log') -Tail 80
exit $code
