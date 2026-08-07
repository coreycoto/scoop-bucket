[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $PreviousManifestPath,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $CurrentManifestPath,

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
    [string] $CurrentReleaseManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'Native Scoop upgrade validation must run on Windows.'
}

$previousManifestFile = (Resolve-Path -LiteralPath $PreviousManifestPath).Path
$currentManifestFile = (Resolve-Path -LiteralPath $CurrentManifestPath).Path
$scoopSourcePath = (Resolve-Path -LiteralPath $ScoopHome).Path
$currentReleaseManifest = Get-Content -LiteralPath $CurrentReleaseManifestPath -Raw | ConvertFrom-Json
$previousManifest = Get-Content -LiteralPath $previousManifestFile -Raw | ConvertFrom-Json
$currentManifest = Get-Content -LiteralPath $currentManifestFile -Raw | ConvertFrom-Json
$previousVersion = [string] $previousManifest.version
$currentVersion = [string] $currentManifest.version

if ($previousVersion -cnotmatch '^\d+\.\d+\.\d+$' -or $currentVersion -cnotmatch '^\d+\.\d+\.\d+$') {
    throw 'Previous and current manifests must use strict stable semver.'
}
if ([version] $previousVersion -ge [version] $currentVersion) {
    throw "Previous version $previousVersion must precede current version $currentVersion."
}
foreach ($entry in @(
    @{ Label = 'previous'; Manifest = $previousManifest; Version = $previousVersion },
    @{ Label = 'current'; Manifest = $currentManifest; Version = $currentVersion }
)) {
    $selected = $entry.Manifest.architecture.$Architecture
    $expectedArchive = "git-slop-v$($entry.Version)-$ExpectedTarget.zip"
    if ([string] $selected.url -cnotmatch "/$([regex]::Escape($expectedArchive))$") {
        throw "$($entry.Label) $Architecture manifest must select $expectedArchive."
    }
}

$headers = @{ 'User-Agent' = 'coreycoto-scoop-bucket-upgrade-validator/1' }
$previousReleaseManifest = Invoke-RestMethod `
    -Uri "https://github.com/coreycoto/git-slop/releases/download/v$previousVersion/release-manifest.json" `
    -Headers $headers
if ([string] $previousReleaseManifest.version -cne $previousVersion) {
    throw 'Previous release manifest version does not match the previous Scoop manifest.'
}
if ([string] $currentReleaseManifest.version -cne $currentVersion) {
    throw 'Current release manifest version does not match the current Scoop manifest.'
}

$env:SCOOP = Join-Path $env:RUNNER_TEMP "git-slop-scoop-upgrade-$Architecture"
$env:SCOOP_GLOBAL = Join-Path $env:RUNNER_TEMP "git-slop-scoop-upgrade-global-$Architecture"
$env:SCOOP_CACHE = Join-Path $env:RUNNER_TEMP "git-slop-scoop-upgrade-cache-$Architecture"
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

Get-ChildItem -LiteralPath $scoopSourcePath -Force |
    Where-Object { $_.Name -cne '.git' } |
    Copy-Item -Destination $installedScoopHome -Recurse -Force
$scoopScript = Join-Path $installedScoopHome 'bin\scoop.ps1'
$env:SCOOP_HOME = $installedScoopHome
$env:PATH = "$shimDirectory;$env:PATH"
$expectedScoopRevision = (& git -C $scoopSourcePath rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $expectedScoopRevision -cnotmatch '^[a-f0-9]{40}$') {
    throw 'Pinned Scoop core did not resolve to one full commit SHA.'
}
$scoopProofBranch = 'git-slop-upgrade-proof'
& git -C $scoopSourcePath branch --force $scoopProofBranch HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to prepare the pinned local Scoop update branch.'
}

function Invoke-Scoop {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments)
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scoopScript @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Scoop command failed with exit code ${LASTEXITCODE}: $($Arguments -join ' ')"
    }
}

function Get-GitSlopIdentity {
    $versionOutput = (& git-slop version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $versionOutput -cnotmatch '^git-slop (?<version>\d+\.\d+\.\d+)$') {
        throw "git-slop version returned '$versionOutput'."
    }
    $buildInfoText = (& git-slop build-info --format json | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'git-slop build-info failed.'
    }
    $buildInfo = $buildInfoText | ConvertFrom-Json
    if ([string] $buildInfo.project -cne 'git-slop' -or $buildInfo.source_dirty -ne $false) {
        throw 'Installed Git Slop identity or dirty-state proof is invalid.'
    }
    return [ordered]@{
        version = [string] $buildInfo.version
        revision = [string] $buildInfo.source_revision
    }
}

function Assert-Identity {
    param(
        [Parameter(Mandatory = $true)] [object] $Identity,
        [Parameter(Mandatory = $true)] [string] $ExpectedVersion,
        [Parameter(Mandatory = $true)] [string] $ExpectedRevision,
        [Parameter(Mandatory = $true)] [string] $Label
    )
    if ([string] $Identity.version -cne $ExpectedVersion) {
        throw "$Label version must be $ExpectedVersion; found '$($Identity.version)'."
    }
    if ([string] $Identity.revision -cne $ExpectedRevision) {
        throw "$Label revision must be $ExpectedRevision; found '$($Identity.revision)'."
    }
}

Invoke-Scoop -Arguments @('config', 'NO_JUNCTION', 'true')
Invoke-Scoop -Arguments @('config', 'aria2-enabled', 'false')
Invoke-Scoop -Arguments @('config', 'SCOOP_REPO', $scoopSourcePath)
Invoke-Scoop -Arguments @('config', 'SCOOP_BRANCH', $scoopProofBranch)
Invoke-Scoop -Arguments @(
    'bucket', 'add', 'coreycoto', 'https://github.com/coreycoto/scoop-bucket'
)

$bucketCheckout = Join-Path $bucketDirectory 'coreycoto'
$bucketManifestPath = Join-Path $bucketCheckout 'bucket\git-slop.json'
if (-not (Test-Path -LiteralPath $bucketManifestPath -PathType Leaf)) {
    throw 'The public coreycoto bucket did not provide bucket/git-slop.json.'
}

# Begin from the exact previous public manifest while retaining the real public
# bucket identity in Scoop's installed-app metadata.
Copy-Item -LiteralPath $previousManifestFile -Destination $bucketManifestPath -Force
Invoke-Scoop -Arguments @(
    'install', '--no-update-scoop', '--arch', $Architecture, 'coreycoto/git-slop'
)
$before = Get-GitSlopIdentity
Assert-Identity `
    -Identity $before `
    -ExpectedVersion $previousVersion `
    -ExpectedRevision ([string] $previousReleaseManifest.revision) `
    -Label 'Pre-update identity'

# Restore the exact current public-bucket bytes, then exercise the documented
# refresh and package-update commands without replacing the installed app.
Copy-Item -LiteralPath $currentManifestFile -Destination $bucketManifestPath -Force
$bucketDiff = @(& git -C $bucketCheckout diff --exit-code -- bucket/git-slop.json 2>&1)
if ($LASTEXITCODE -ne 0) {
    $bucketDiff | ForEach-Object { Write-Output $_ }
    throw 'Current manifest bytes do not match the public bucket checkout.'
}
Invoke-Scoop -Arguments @('update')
Invoke-Scoop -Arguments @('update', 'git-slop')
$updatedScoopRevision = (& git -C $installedScoopHome rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $updatedScoopRevision -cne $expectedScoopRevision) {
    throw "Scoop update must retain pinned core $expectedScoopRevision; found '$updatedScoopRevision'."
}

$after = Get-GitSlopIdentity
Assert-Identity `
    -Identity $after `
    -ExpectedVersion $currentVersion `
    -ExpectedRevision ([string] $currentReleaseManifest.revision) `
    -Label 'Post-update identity'
$gitSubcommandOutput = (& git slop version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $gitSubcommandOutput -cne "git-slop $currentVersion") {
    throw "git slop version returned '$gitSubcommandOutput'."
}

$installInfoPath = Join-Path $env:SCOOP "apps\git-slop\$currentVersion\install.json"
$installInfo = Get-Content -LiteralPath $installInfoPath -Raw | ConvertFrom-Json
if ([string] $installInfo.architecture -cne $Architecture) {
    throw "Scoop recorded architecture '$($installInfo.architecture)' instead of '$Architecture'."
}

[ordered]@{
    architecture = $Architecture
    target = $ExpectedTarget
    before = $before
    after = $after
    scoop_revision = $updatedScoopRevision
    bucket_revision = (& git -C $bucketCheckout rev-parse HEAD | Out-String).Trim()
    manifest_url = 'https://github.com/coreycoto/scoop-bucket/blob/main/bucket/git-slop.json'
} | ConvertTo-Json -Depth 4 -Compress
