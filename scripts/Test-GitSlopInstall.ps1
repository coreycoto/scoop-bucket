[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $ManifestPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet('64bit', 'arm64')]
    [string] $Architecture,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedTarget,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $ScoopHome,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $ReleaseManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'Native Scoop installation validation must run on Windows.'
}

$manifestFile = (Resolve-Path -LiteralPath $ManifestPath).Path
$scoopSourcePath = (Resolve-Path -LiteralPath $ScoopHome).Path
$releaseManifest = Get-Content -LiteralPath $ReleaseManifestPath -Raw | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
$version = [string] $manifest.version
$selected = $manifest.architecture.$Architecture
if ([string] $selected.url -cnotmatch "git-slop-v$([regex]::Escape($version))-$([regex]::Escape($ExpectedTarget))\.zip$") {
    throw "$Architecture must select the $ExpectedTarget archive."
}

$env:SCOOP = Join-Path $env:RUNNER_TEMP 'git-slop-scoop-user'
$env:SCOOP_GLOBAL = Join-Path $env:RUNNER_TEMP 'git-slop-scoop-global'
$env:SCOOP_CACHE = Join-Path $env:RUNNER_TEMP 'git-slop-scoop-cache'
$shimDirectory = Join-Path $env:SCOOP 'shims'
$bucketDirectory = Join-Path $env:SCOOP 'buckets'
$installedScoopHome = Join-Path $env:SCOOP 'apps\scoop\current'
foreach ($directory in @(
    $env:SCOOP,
    $env:SCOOP_GLOBAL,
    $env:SCOOP_CACHE,
    $shimDirectory,
    $bucketDirectory,
    $installedScoopHome
)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

# Scoop resolves its shim helper from apps\scoop\current, even when its entry
# point is invoked from a separate source checkout.
Get-ChildItem -LiteralPath $scoopSourcePath -Force |
    Where-Object { $_.Name -cne '.git' } |
    Copy-Item -Destination $installedScoopHome -Recurse -Force
$scoopScript = Join-Path $installedScoopHome 'bin\scoop.ps1'
$env:SCOOP_HOME = $installedScoopHome
$env:PATH = "$shimDirectory;$env:PATH"

function Invoke-Scoop {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments)
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scoopScript @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Scoop command failed with exit code ${LASTEXITCODE}: $($Arguments -join ' ')"
    }
}

Invoke-Scoop -Arguments @('config', 'NO_JUNCTION', 'true')
Invoke-Scoop -Arguments @('config', 'aria2-enabled', 'false')
Invoke-Scoop -Arguments @(
    'install', '--independent', '--no-update-scoop', '--arch', $Architecture, $manifestFile
)

$versionOutput = (& git-slop version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $versionOutput -cne "git-slop $version") {
    throw "git-slop version returned '$versionOutput'."
}
$buildInfoText = (& git-slop build-info --format json | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'git-slop build-info failed.'
}
$buildInfo = $buildInfoText | ConvertFrom-Json
if ([string] $buildInfo.project -cne 'git-slop') {
    throw "Installed project identity must be git-slop; found '$($buildInfo.project)'."
}
if ([string] $buildInfo.version -cne $version) {
    throw "Installed version must be $version; found '$($buildInfo.version)'."
}
if ([string] $buildInfo.source_revision -cne [string] $releaseManifest.revision) {
    throw 'Installed source revision does not match release-manifest.json.'
}
if ($buildInfo.source_dirty -ne $false) {
    throw 'Installed release binary must report source_dirty: false.'
}

$gitSubcommandOutput = (& git slop version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $gitSubcommandOutput -cne "git-slop $version") {
    throw "git slop version returned '$gitSubcommandOutput'."
}

$installInfoPath = Join-Path $env:SCOOP "apps\git-slop\$version\install.json"
$installInfo = Get-Content -LiteralPath $installInfoPath -Raw | ConvertFrom-Json
if ([string] $installInfo.architecture -cne $Architecture) {
    throw "Scoop recorded architecture '$($installInfo.architecture)' instead of '$Architecture'."
}

Invoke-Scoop -Arguments @('uninstall', 'git-slop')
$shimNames = @('git-slop.exe', 'git-slop.shim', 'git-slop.cmd', 'git-slop.ps1')
foreach ($shimName in $shimNames) {
    if (Test-Path -LiteralPath (Join-Path $shimDirectory $shimName)) {
        throw "Scoop uninstall left the $shimName shim behind."
    }
}

$badManifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
$badManifest.architecture.$Architecture.hash = ('0' * 64)
$badManifestPath = Join-Path $env:RUNNER_TEMP 'git-slop-bad-hash.json'
$badJson = $badManifest | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText(
    $badManifestPath,
    "$badJson$([Environment]::NewLine)",
    [System.Text.UTF8Encoding]::new($false)
)

$badHashArguments = @(
    'install', '--independent', '--no-cache', '--no-update-scoop', '--arch',
    $Architecture, $badManifestPath
)
$badHashOutput = @(
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scoopScript @badHashArguments 2>&1
)
$badHashExitCode = $LASTEXITCODE
$badHashOutput | ForEach-Object { Write-Output $_ }
$badHashText = ($badHashOutput | Out-String).Trim()
if ($badHashText -cnotmatch 'ERROR Hash check failed!') {
    throw 'Scoop did not report the expected corrupted archive hash rejection.'
}
$badInstallInfoPath = Join-Path $env:SCOOP "apps\git-slop-bad-hash\$version\install.json"
if (Test-Path -LiteralPath $badInstallInfoPath) {
    throw 'The bad-hash installation wrote installed-app metadata.'
}
foreach ($shimName in $shimNames) {
    if (Test-Path -LiteralPath (Join-Path $shimDirectory $shimName)) {
        throw "The bad-hash installation created the $shimName shim."
    }
}

[ordered]@{
    version = $version
    revision = $buildInfo.source_revision
    architecture = $Architecture
    target = $ExpectedTarget
    bad_hash_rejected = $true
    bad_hash_exit_code = $badHashExitCode
} | ConvertTo-Json -Compress
