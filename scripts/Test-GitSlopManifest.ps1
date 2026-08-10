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
foreach ($line in $checksumLines) {
    if ($line -cnotmatch '^(?<hash>[a-f0-9]{64})  (?<name>[A-Za-z0-9._+-]+)$') {
        throw "Invalid SHA256SUMS entry: $line"
    }
    if ($checksumByName.ContainsKey($Matches.name)) {
        throw "Duplicate SHA256SUMS filename: $($Matches.name)"
    }
    $checksumByName[$Matches.name] = $Matches.hash
}

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

$releaseArtifacts = @($releaseManifest.artifacts)
if ($releaseArtifacts.Count -eq 0) {
    throw 'Release manifest must contain at least one native artifact.'
}
$artifactNames = @($releaseArtifacts | ForEach-Object { [string] $_.name })
$artifactTargets = @($releaseArtifacts | ForEach-Object { [string] $_.target })
if (
    @($artifactNames | Sort-Object -Unique).Count -ne $artifactNames.Count -or
    @($artifactTargets | Sort-Object -Unique).Count -ne $artifactTargets.Count
) {
    throw 'Release manifest artifact names and targets must be unique.'
}
foreach ($artifact in $releaseArtifacts) {
    if ([string] $artifact.target -cnotmatch '^[A-Za-z0-9_+-]+$') {
        throw "Release manifest target '$($artifact.target)' is invalid."
    }
    if ([string] $artifact.archive -cne 'zip' -and [string] $artifact.archive -cne 'tar.gz') {
        throw "Release manifest archive '$($artifact.archive)' is invalid."
    }
    $expectedName = "git-slop-v$version-$($artifact.target).$($artifact.archive)"
    Assert-Equal $artifact.name $expectedName "$($artifact.target) artifact name"
    Assert-Equal $artifact.path $expectedName "$($artifact.target) artifact path"
    Assert-Equal $artifact.url "$releaseBase/$expectedName" "$($artifact.target) artifact URL"
    if ([string] $artifact.sha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw "$($artifact.target) artifact hash must be one lowercase SHA-256 value."
    }
}

$requiredChecksumNames = @($artifactNames + @('release-manifest.json', 'git-slop.rb'))
$missingChecksumNames = @(
    $requiredChecksumNames | Where-Object { -not $checksumByName.ContainsKey($_) }
)
if ($missingChecksumNames.Count -ne 0) {
    throw "SHA256SUMS is missing required release assets: $($missingChecksumNames -join ', ')."
}

$releaseManifestDigest = (Get-FileHash -LiteralPath $releaseManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-Equal $releaseManifestDigest $checksumByName['release-manifest.json'] 'release-manifest.json SHA-256'

foreach ($artifact in $releaseArtifacts) {
    Assert-Equal $artifact.sha256 $checksumByName[$artifact.name] "$($artifact.target) release-manifest hash"
}
foreach ($entry in $targetByArchitecture.GetEnumerator()) {
    $target = $entry.Value
    $archive = "git-slop-v$version-$target.zip"
    $artifacts = @($releaseArtifacts | Where-Object { $_.target -ceq $target })
    if ($artifacts.Count -ne 1) {
        throw "Release manifest must contain exactly one artifact for $target."
    }
    $artifact = $artifacts[0]
    Assert-Equal $artifact.name $archive "$target artifact name"
    Assert-Equal $artifact.path $archive "$target artifact path"
    Assert-Equal $artifact.archive 'zip' "$target archive type"
    Assert-Equal $artifact.os 'windows' "$target operating system"
    $expectedArch = if ($entry.Key -ceq '64bit') { 'x86_64' } else { 'aarch64' }
    Assert-Equal $artifact.arch $expectedArch "$target architecture"
    Assert-Equal $artifact.url "$releaseBase/$archive" "$target artifact URL"
    Assert-Equal $manifestHashByArchive[$archive] $checksumByName[$archive] "$target Scoop hash"
}

$releaseApiUrl = "https://api.github.com/repos/coreycoto/git-slop/releases/tags/v$version"
$release = Invoke-RestMethod -Uri $releaseApiUrl -Headers $headers
Assert-Equal $release.tag_name "v$version" 'Public release tag'
Assert-Equal $release.draft $false 'Public release draft flag'
Assert-Equal $release.prerelease $false 'Public release prerelease flag'
$expectedReleaseAssets = @(@($checksumByName.Keys) + 'SHA256SUMS')
Assert-ExactSet @($release.assets.name) $expectedReleaseAssets 'Public release assets'
foreach ($name in $checksumByName.Keys) {
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
