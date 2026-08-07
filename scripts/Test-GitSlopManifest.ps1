[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $ManifestPath,

    [string] $EvidenceDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [AllowNull()] [object] $Actual,
        [AllowNull()] [object] $Expected,
        [Parameter(Mandatory = $true)] [string] $Label
    )
    if ([string] $Actual -cne [string] $Expected) {
        throw "$Label must equal '$Expected'; found '$Actual'."
    }
}

function Assert-ExactSet {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Actual,
        [Parameter(Mandatory = $true)] [object[]] $Expected,
        [Parameter(Mandatory = $true)] [string] $Label
    )
    $actualValues = @($Actual | ForEach-Object { [string] $_ } | Sort-Object -Unique)
    $expectedValues = @($Expected | ForEach-Object { [string] $_ } | Sort-Object -Unique)
    $difference = @(Compare-Object -ReferenceObject $expectedValues -DifferenceObject $actualValues)
    if ($difference.Count -ne 0 -or $actualValues.Count -ne $Expected.Count) {
        throw "$Label must equal [$($expectedValues -join ', ')]; found [$($actualValues -join ', ')]."
    }
}

function Get-PropertyNames {
    param([Parameter(Mandatory = $true)] [object] $Value)
    return @($Value.PSObject.Properties.Name)
}

$manifestFile = (Resolve-Path -LiteralPath $ManifestPath).Path
$manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
$version = [string] $manifest.version
if ($version -cnotmatch '^\d+\.\d+\.\d+$') {
    throw "Manifest version must be strict stable semver; found '$version'."
}
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "git-slop-$version-scoop-evidence"
}

Assert-ExactSet (Get-PropertyNames $manifest) @(
    'version', 'description', 'homepage', 'license', 'suggest', 'architecture',
    'bin', 'checkver', 'autoupdate'
) 'Manifest properties'
Assert-Equal $manifest.homepage 'https://github.com/coreycoto/git-slop' 'Manifest homepage'
Assert-Equal $manifest.license 'MIT' 'Manifest license'
Assert-Equal $manifest.bin 'git-slop.exe' 'Manifest bin'
Assert-Equal $manifest.checkver 'github' 'Manifest checkver'
Assert-ExactSet (Get-PropertyNames $manifest.suggest) @('Git') 'Manifest suggestions'
Assert-Equal $manifest.suggest.Git 'git' 'Git suggestion'
Assert-ExactSet (Get-PropertyNames $manifest.architecture) @('64bit', 'arm64') 'Manifest architectures'
Assert-ExactSet (Get-PropertyNames $manifest.autoupdate) @('architecture', 'hash') 'Autoupdate properties'
Assert-ExactSet (Get-PropertyNames $manifest.autoupdate.architecture) @('64bit', 'arm64') 'Autoupdate architectures'
Assert-Equal $manifest.autoupdate.hash.url 'https://github.com/coreycoto/git-slop/releases/download/v$version/SHA256SUMS' 'Autoupdate checksum URL'

$targetByArchitecture = [ordered]@{
    '64bit' = 'x86_64-pc-windows-msvc'
    'arm64' = 'aarch64-pc-windows-msvc'
}
$manifestHashByArchive = @{}
foreach ($entry in $targetByArchitecture.GetEnumerator()) {
    $architecture = $entry.Key
    $target = $entry.Value
    $archive = "git-slop-v$version-$target.zip"
    $expectedUrl = "https://github.com/coreycoto/git-slop/releases/download/v$version/$archive"
    $selected = $manifest.architecture.$architecture
    Assert-ExactSet (Get-PropertyNames $selected) @('url', 'hash', 'extract_dir') "$architecture properties"
    Assert-Equal $selected.url $expectedUrl "$architecture URL"
    Assert-Equal $selected.extract_dir "git-slop-v$version-$target" "$architecture extract_dir"
    if ([string] $selected.hash -cnotmatch '^[a-f0-9]{64}$') {
        throw "$architecture hash must be one lowercase SHA-256 value."
    }
    $manifestHashByArchive[$archive] = [string] $selected.hash

    $autoupdate = $manifest.autoupdate.architecture.$architecture
    Assert-ExactSet (Get-PropertyNames $autoupdate) @('url', 'extract_dir') "$architecture autoupdate properties"
    Assert-Equal $autoupdate.url "https://github.com/coreycoto/git-slop/releases/download/v`$version/git-slop-v`$version-$target.zip" "$architecture autoupdate URL"
    Assert-Equal $autoupdate.extract_dir "git-slop-v`$version-$target" "$architecture autoupdate extract_dir"
}

New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$releaseManifestPath = Join-Path $EvidenceDirectory 'release-manifest.json'
$checksumsPath = Join-Path $EvidenceDirectory 'SHA256SUMS'
$releaseBase = "https://github.com/coreycoto/git-slop/releases/download/v$version"
$headers = @{ 'User-Agent' = 'coreycoto-scoop-bucket-validator/1' }
Invoke-WebRequest -Uri "$releaseBase/release-manifest.json" -OutFile $releaseManifestPath -Headers $headers
Invoke-WebRequest -Uri "$releaseBase/SHA256SUMS" -OutFile $checksumsPath -Headers $headers

$checksumByName = @{}
$checksumLines = @(Get-Content -LiteralPath $checksumsPath | Where-Object { $_ -ne '' })
if ($checksumLines.Count -ne 7) {
    throw "SHA256SUMS must contain exactly seven non-empty entries; found $($checksumLines.Count)."
}
foreach ($line in $checksumLines) {
    if ($line -cnotmatch '^(?<hash>[a-f0-9]{64})  (?<name>[A-Za-z0-9._+-]+)$') {
        throw "Invalid SHA256SUMS entry: $line"
    }
    if ($checksumByName.ContainsKey($Matches.name)) {
        throw "Duplicate SHA256SUMS filename: $($Matches.name)"
    }
    $checksumByName[$Matches.name] = $Matches.hash
}

$expectedChecksumNames = @(
    'release-manifest.json'
    'git-slop.rb'
    "git-slop-v$version-x86_64-unknown-linux-gnu.tar.gz"
    "git-slop-v$version-aarch64-unknown-linux-gnu.tar.gz"
    "git-slop-v$version-aarch64-apple-darwin.tar.gz"
    "git-slop-v$version-x86_64-pc-windows-msvc.zip"
    "git-slop-v$version-aarch64-pc-windows-msvc.zip"
)
Assert-ExactSet @($checksumByName.Keys) $expectedChecksumNames 'SHA256SUMS filenames'

$releaseManifestDigest = (Get-FileHash -LiteralPath $releaseManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-Equal $releaseManifestDigest $checksumByName['release-manifest.json'] 'release-manifest.json SHA-256'

$releaseManifest = Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json
Assert-Equal $releaseManifest.schema_version 3 'Release manifest schema version'
Assert-Equal $releaseManifest.project 'git-slop' 'Release manifest project'
Assert-Equal $releaseManifest.repository 'coreycoto/git-slop' 'Release manifest repository'
Assert-Equal $releaseManifest.version $version 'Release manifest version'
Assert-Equal $releaseManifest.tag "v$version" 'Release manifest tag'
if ([string] $releaseManifest.revision -cnotmatch '^[a-f0-9]{40}$') {
    throw 'Release manifest revision must be one full lowercase commit SHA.'
}
Assert-Equal $releaseManifest.crate_source.version $version 'Crate-source version'
Assert-Equal $releaseManifest.crate_source.revision $releaseManifest.revision 'Crate-source revision'
Assert-Equal $releaseManifest.crate_source.vcs_dirty $false 'Crate-source dirty flag'

$expectedTargets = @(
    'x86_64-unknown-linux-gnu',
    'aarch64-unknown-linux-gnu',
    'aarch64-apple-darwin',
    'x86_64-pc-windows-msvc',
    'aarch64-pc-windows-msvc'
)
if (@($releaseManifest.artifacts).Count -ne 5) {
    throw "Release manifest must contain exactly five native artifacts."
}
Assert-ExactSet @($releaseManifest.artifacts.target) $expectedTargets 'Release manifest targets'
foreach ($entry in $targetByArchitecture.GetEnumerator()) {
    $target = $entry.Value
    $archive = "git-slop-v$version-$target.zip"
    $artifacts = @($releaseManifest.artifacts | Where-Object { $_.target -ceq $target })
    if ($artifacts.Count -ne 1) {
        throw "Release manifest must contain exactly one artifact for $target."
    }
    $artifact = $artifacts[0]
    Assert-Equal $artifact.name $archive "$target artifact name"
    Assert-Equal $artifact.path $archive "$target artifact path"
    Assert-Equal $artifact.archive 'zip' "$target archive type"
    Assert-Equal $artifact.os 'windows' "$target operating system"
    Assert-Equal $artifact.url "$releaseBase/$archive" "$target artifact URL"
    Assert-Equal $artifact.sha256 $checksumByName[$archive] "$target release-manifest hash"
    Assert-Equal $manifestHashByArchive[$archive] $checksumByName[$archive] "$target Scoop hash"
}

$releaseApiUrl = "https://api.github.com/repos/coreycoto/git-slop/releases/tags/v$version"
$release = Invoke-RestMethod -Uri $releaseApiUrl -Headers $headers
Assert-Equal $release.tag_name "v$version" 'Public release tag'
Assert-Equal $release.draft $false 'Public release draft flag'
Assert-Equal $release.prerelease $false 'Public release prerelease flag'
$expectedReleaseAssets = @($expectedChecksumNames + 'SHA256SUMS')
Assert-ExactSet @($release.assets.name) $expectedReleaseAssets 'Public release assets'
foreach ($name in $expectedChecksumNames) {
    $assets = @($release.assets | Where-Object { $_.name -ceq $name })
    if ($assets.Count -ne 1) {
        throw "Public release must contain exactly one $name asset."
    }
    Assert-Equal $assets[0].digest "sha256:$($checksumByName[$name])" "$name GitHub asset digest"
}

$tagRows = @(& git ls-remote --tags https://github.com/coreycoto/git-slop.git "refs/tags/v$version" "refs/tags/v$version^{}")
if ($LASTEXITCODE -ne 0) {
    throw "Unable to resolve public tag v$version."
}
$tagByRef = @{}
foreach ($row in $tagRows) {
    $parts = @($row -split '\s+')
    if ($parts.Count -eq 2) {
        $tagByRef[$parts[1]] = $parts[0]
    }
}
$tagRef = "refs/tags/v$version"
$peeledRef = "$tagRef^{}"
if ($tagByRef.ContainsKey($peeledRef)) {
    $tagRevision = $tagByRef[$peeledRef]
} elseif ($tagByRef.ContainsKey($tagRef)) {
    $tagRevision = $tagByRef[$tagRef]
} else {
    throw "Public tag v$version did not resolve in the exact tag namespace."
}
if ([string] $tagRevision -cnotmatch '^[a-f0-9]{40}$') {
    throw "Public tag v$version did not resolve to one full lowercase object ID."
}
Assert-Equal $releaseManifest.revision $tagRevision 'Release manifest and public tag revision'

[ordered]@{
    version = $version
    revision = $tagRevision
    manifest = $manifestFile
    release_manifest_sha256 = $releaseManifestDigest
    x86_64_sha256 = $manifestHashByArchive["git-slop-v$version-x86_64-pc-windows-msvc.zip"]
    arm64_sha256 = $manifestHashByArchive["git-slop-v$version-aarch64-pc-windows-msvc.zip"]
} | ConvertTo-Json -Compress
