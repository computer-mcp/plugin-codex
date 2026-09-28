param([Parameter(Mandatory = $true)][string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'SQLite Windows input requires a native Windows toolchain' }
if (Test-Path $OutputDirectory) { throw 'SQLite build requires a fresh output directory' }
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$metadataPath = Join-Path $PSScriptRoot 'windows-sqlite.json'
$metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
Copy-Item $metadataPath (Join-Path $root 'source.json')
$archive = Join-Path $root 'source.zip'
Invoke-WebRequest -Uri $metadata.url -OutFile $archive -TimeoutSec 120 -MaximumRetryCount 2 -RetryIntervalSec 2
if ((Get-Item $archive).Length -ne $metadata.size -or
    (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $metadata.sha256) {
    throw 'SQLite source archive does not match the pinned size and checksum'
}
Expand-Archive -Path $archive -DestinationPath $root
$include = Join-Path $root $metadata.directory
$compiler = (Get-Command clang-cl -ErrorAction Stop).Source
$librarian = (Get-Command llvm-lib -ErrorAction Stop).Source
& $compiler --version *> (Join-Path $root 'compiler.txt')
if ($LASTEXITCODE -ne 0) { throw 'SQLite compiler unavailable' }
$object = Join-Path $root 'sqlite3.obj'
$library = Join-Path $root 'sqlite3.lib'
$defines = @($metadata.compileDefinitions | ForEach-Object { "/D$_" })
$compileArguments = @('/nologo', '/c', '/O2', '/MD') + $defines + @((Join-Path $include 'sqlite3.c'), "/Fo$object")
& $compiler @compileArguments *> (Join-Path $root 'compile.log')
if ($LASTEXITCODE -ne 0) { throw 'SQLite static compilation failed; see compile.log' }
& $librarian /nologo "/out:$library" $object *> (Join-Path $root 'library.log')
if ($LASTEXITCODE -ne 0) { throw 'SQLite static archive failed; see library.log' }

$probe = Join-Path $PSScriptRoot '../Tests/WindowsSQLite/verify.c'
$executable = Join-Path $root 'verify.exe'
$probeArguments = @('/nologo', '/O2', '/MD', "/I$include", $probe, $library,
    "/Fe$executable", "/Fo$(Join-Path $root 'verify.obj')")
& $compiler @probeArguments *> (Join-Path $root 'verify-build.log')
if ($LASTEXITCODE -ne 0) { throw 'SQLite verification build failed; see verify-build.log' }
& $executable (Join-Path $root 'verify.sqlite') $metadata.version *> (Join-Path $root 'verify.json')
if ($LASTEXITCODE -ne 0) { throw 'SQLite native verification failed; see verify.json' }

$receipt = [pscustomobject]@{
    source = $metadata
    compiler = $compiler
    librarian = $librarian
    compileArguments = $compileArguments
    verificationArguments = $probeArguments
    librarySHA256 = (Get-FileHash $library -Algorithm SHA256).Hash.ToLowerInvariant()
    headerSHA256 = (Get-FileHash (Join-Path $include 'sqlite3.h') -Algorithm SHA256).Hash.ToLowerInvariant()
    probeSHA256 = (Get-FileHash $probe -Algorithm SHA256).Hash.ToLowerInvariant()
    verification = (Get-Content (Join-Path $root 'verify.json') -Raw | ConvertFrom-Json)
}
$receipt | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'receipt.json')
[pscustomobject]@{ includeDirectory = $include; libraryDirectory = $root; receipt = $receipt }
