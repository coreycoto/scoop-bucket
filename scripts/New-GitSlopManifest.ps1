[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot '../bucket/git-slop.json'
}

$releaseBase = "https://github.com/coreycoto/git-slop/releases/download/v$Version"
$checksumsUrl = "$releaseBase/SHA256SUMS"
$releaseManifestUrl = "$releaseBase/release-manifest.json"
$temporaryChecksums = Join-Path ([System.IO.Path]::GetTempPath()) "git-slop-$Version-SHA256SUMS"
$temporaryReleaseManifest = Join-Path ([System.IO.Path]::GetTempPath()) "git-slop-$Version-release-manifest.json"

Invoke-WebRequest -Uri $checksumsUrl -OutFile $temporaryChecksums -Headers @{
    'User-Agent' = 'coreycoto-scoop-bucket-renderer/1'
}
Invoke-WebRequest -Uri $releaseManifestUrl -OutFile $temporaryReleaseManifest -Headers @{
    'User-Agent' = 'coreycoto-scoop-bucket-renderer/1'
}

$releaseManifest = Get-Content -LiteralPath $temporaryReleaseManifest -Raw | ConvertFrom-Json
if (
    [int] $releaseManifest.schema_version -ne 3 -or
    [string] $releaseManifest.project -cne 'git-slop' -or
    [string] $releaseManifest.repository -cne 'coreycoto/git-slop' -or
    [string] $releaseManifest.version -cne $Version -or
    [string] $releaseManifest.tag -cne "v$Version"
) {
    throw 'release-manifest.json does not match the requested Git Slop release identity.'
}

$releaseArtifacts = @($releaseManifest.artifacts)
if ($releaseArtifacts.Count -eq 0) {
    throw 'release-manifest.json must contain at least one artifact.'
}
$artifactNames = @($releaseArtifacts | ForEach-Object { [string] $_.name })
$artifactTargets = @($releaseArtifacts | ForEach-Object { [string] $_.target })
if (
    @($artifactNames | Sort-Object -Unique).Count -ne $artifactNames.Count -or
    @($artifactTargets | Sort-Object -Unique).Count -ne $artifactTargets.Count
) {
    throw 'release-manifest.json artifact names and targets must be unique.'
}
foreach ($artifact in $releaseArtifacts) {
    $expectedName = "git-slop-v$Version-$($artifact.target).$($artifact.archive)"
    if (
        [string] $artifact.target -cnotmatch '^[A-Za-z0-9_+-]+$' -or
        ([string] $artifact.archive -cne 'zip' -and [string] $artifact.archive -cne 'tar.gz') -or
        [string] $artifact.name -cne $expectedName -or
        [string] $artifact.path -cne $expectedName -or
        [string] $artifact.url -cne "$releaseBase/$expectedName" -or
        [string] $artifact.sha256 -cnotmatch '^[a-f0-9]{64}$'
    ) {
        throw "Invalid release-manifest.json artifact contract for '$($artifact.target)'."
    }
}

$checksumByName = @{}
$checksumLines = @(Get-Content -LiteralPath $temporaryChecksums | Where-Object { $_ -ne '' })
foreach ($line in $checksumLines) {
    if ($line -cnotmatch '^(?<hash>[a-f0-9]{64})  (?<name>[A-Za-z0-9._+-]+)$') {
        throw "Invalid SHA256SUMS entry: $line"
    }
    if ($checksumByName.ContainsKey($Matches.name)) {
        throw "Duplicate SHA256SUMS filename: $($Matches.name)"
    }
    $checksumByName[$Matches.name] = $Matches.hash
}

$targetByArchitecture = [ordered]@{
    '64bit' = 'x86_64-pc-windows-msvc'
    'arm64' = 'aarch64-pc-windows-msvc'
}
$requiredNames = @($artifactNames + @('release-manifest.json', 'git-slop.rb'))
$missingNames = @($requiredNames | Where-Object { -not $checksumByName.ContainsKey($_) })
if ($missingNames.Count -ne 0) {
    throw "SHA256SUMS is missing required Git Slop release assets: $($missingNames -join ', ')."
}
$releaseManifestDigest = (Get-FileHash -LiteralPath $temporaryReleaseManifest -Algorithm SHA256).Hash.ToLowerInvariant()
if ([string] $checksumByName['release-manifest.json'] -cne $releaseManifestDigest) {
    throw 'SHA256SUMS does not match the downloaded release-manifest.json.'
}
foreach ($artifact in $releaseArtifacts) {
    if ([string] $checksumByName[$artifact.name] -cne [string] $artifact.sha256) {
        throw "SHA256SUMS does not match release-manifest.json for '$($artifact.name)'."
    }
}

$architecture = [ordered]@{}
$autoupdateArchitecture = [ordered]@{}
foreach ($entry in $targetByArchitecture.GetEnumerator()) {
    $artifacts = @($releaseArtifacts | Where-Object { $_.target -ceq $entry.Value })
    if ($artifacts.Count -ne 1) {
        throw "release-manifest.json must contain exactly one artifact for $($entry.Value)."
    }
    $artifact = $artifacts[0]
    $archive = "git-slop-v$Version-$($entry.Value).zip"
    if (
        [string] $artifact.name -cne $archive -or
        [string] $artifact.archive -cne 'zip' -or
        [string] $artifact.os -cne 'windows' -or
        (
            $entry.Key -ceq '64bit' -and
            [string] $artifact.arch -cne 'x86_64'
        ) -or
        (
            $entry.Key -ceq 'arm64' -and
            [string] $artifact.arch -cne 'aarch64'
        )
    ) {
        throw "Invalid Windows artifact contract for $($entry.Value)."
    }
    $architecture[$entry.Key] = [ordered]@{
        url = "$releaseBase/$archive"
        hash = $checksumByName[$archive]
        extract_dir = "git-slop-v$Version-$($entry.Value)"
    }
    $autoupdateArchitecture[$entry.Key] = [ordered]@{
        url = "https://github.com/coreycoto/git-slop/releases/download/v`$version/git-slop-v`$version-$($entry.Value).zip"
        extract_dir = "git-slop-v`$version-$($entry.Value)"
    }
}

$manifest = [ordered]@{
    version = $Version
    description = 'Deterministic repository health and maintenance-pressure analysis for humans and AI agents.'
    homepage = 'https://github.com/coreycoto/git-slop'
    license = 'MIT'
    suggest = [ordered]@{
        Git = 'git'
    }
    architecture = $architecture
    bin = 'git-slop.exe'
    checkver = 'github'
    autoupdate = [ordered]@{
        architecture = $autoupdateArchitecture
        hash = [ordered]@{
            url = 'https://github.com/coreycoto/git-slop/releases/download/v$version/SHA256SUMS'
        }
    }
}

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$json = $manifest | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText(
    $resolvedOutput,
    "$json$([Environment]::NewLine)",
    [System.Text.UTF8Encoding]::new($false)
)

Write-Output "Rendered $resolvedOutput from $checksumsUrl"
