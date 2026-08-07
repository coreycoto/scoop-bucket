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
$temporaryChecksums = Join-Path ([System.IO.Path]::GetTempPath()) "git-slop-$Version-SHA256SUMS"

Invoke-WebRequest -Uri $checksumsUrl -OutFile $temporaryChecksums -Headers @{
    'User-Agent' = 'coreycoto-scoop-bucket-renderer/1'
}

$checksumByName = @{}
$checksumLines = @(Get-Content -LiteralPath $temporaryChecksums | Where-Object { $_ -ne '' })
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

$targetByArchitecture = [ordered]@{
    '64bit' = 'x86_64-pc-windows-msvc'
    'arm64' = 'aarch64-pc-windows-msvc'
}
$expectedNames = @(
    'release-manifest.json'
    'git-slop.rb'
    "git-slop-v$Version-x86_64-unknown-linux-gnu.tar.gz"
    "git-slop-v$Version-aarch64-unknown-linux-gnu.tar.gz"
    "git-slop-v$Version-aarch64-apple-darwin.tar.gz"
    "git-slop-v$Version-x86_64-pc-windows-msvc.zip"
    "git-slop-v$Version-aarch64-pc-windows-msvc.zip"
)
$actualNames = @($checksumByName.Keys | Sort-Object)
$nameDifference = @(Compare-Object -ReferenceObject @($expectedNames | Sort-Object) -DifferenceObject $actualNames)
if ($nameDifference.Count -ne 0) {
    throw "SHA256SUMS does not match the exact seven-entry Git Slop release contract."
}

$architecture = [ordered]@{}
$autoupdateArchitecture = [ordered]@{}
foreach ($entry in $targetByArchitecture.GetEnumerator()) {
    $archive = "git-slop-v$Version-$($entry.Value).zip"
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
