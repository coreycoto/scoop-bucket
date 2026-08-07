[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$receiverPath = Join-Path $repositoryRoot '.github/workflows/update-git-slop.yml'
$ciPath = Join-Path $repositoryRoot '.github/workflows/ci.yml'
$readmePath = Join-Path $repositoryRoot 'README.md'
$receiver = Get-Content -LiteralPath $receiverPath -Raw
$ci = Get-Content -LiteralPath $ciPath -Raw
$readme = Get-Content -LiteralPath $readmePath -Raw

function Require-Text {
    param(
        [Parameter(Mandatory = $true)] [string] $Text,
        [Parameter(Mandatory = $true)] [string] $Expected,
        [Parameter(Mandatory = $true)] [string] $Label
    )
    if (-not $Text.Contains($Expected, [System.StringComparison]::Ordinal)) {
        throw "$Label is missing required contract text: $Expected"
    }
}

function Reject-Text {
    param(
        [Parameter(Mandatory = $true)] [string] $Text,
        [Parameter(Mandatory = $true)] [string] $Rejected,
        [Parameter(Mandatory = $true)] [string] $Label
    )
    if ($Text.Contains($Rejected, [System.StringComparison]::Ordinal)) {
        throw "$Label contains forbidden contract text: $Rejected"
    }
}

function Require-Count {
    param(
        [Parameter(Mandatory = $true)] [string] $Text,
        [Parameter(Mandatory = $true)] [string] $Expected,
        [Parameter(Mandatory = $true)] [int] $Count,
        [Parameter(Mandatory = $true)] [string] $Label
    )
    $actual = ([regex]::Matches($Text, [regex]::Escape($Expected))).Count
    if ($actual -ne $Count) {
        throw "$Label requires $Count occurrences of '$Expected'; found $actual."
    }
}

foreach ($required in @(
    'workflow_dispatch:',
    'release_manifest_sha256:',
    'permissions: {}',
    'group: git-slop-scoop-publication',
    'cancel-in-progress: false',
    "github.ref == 'refs/heads/main' && github.actor == github.repository_owner",
    'actions: write',
    'contents: write',
    'pull-requests: write',
    'persist-credentials: false',
    'Verify dispatch ran from exact bucket main',
    'test "$GITHUB_SHA" = "$live_main"',
    '(.assets | length) == 8',
    'test "$tag_revision" = "$RELEASE_REVISION"',
    'test "$manifest_sha256" = "$EXPECTED_MANIFEST_SHA256"',
    'test "$(wc -l < "$release_dir/SHA256SUMS" | tr -d '' '')" = 7',
    './scripts/New-GitSlopManifest.ps1',
    './scripts/Test-GitSlopManifest.ps1',
    'branch="automation/git-slop-v${RELEASE_VERSION}"',
    'gh auth setup-git',
    'test "$(git diff --cached --name-only --no-renames)" = "bucket/git-slop.json"',
    '--force-with-lease="refs/heads/${branch}:${remote_sha}"',
    '.user.login == "github-actions[bot]"',
    '.user.login == $owner',
    'Await exact-PR Windows qualification',
    'event=pull_request',
    '.event == "pull_request"',
    '.actor.login == $owner',
    '.triggering_actor.login == $owner',
    '([.jobs[].name] | sort) == ["Windows 64bit", "Windows arm64"]',
    'Reverify exact PR head and governed-merge',
    'length == 1 and',
    '.[0].filename == "bucket/git-slop.json"',
    '"repos/${GITHUB_REPOSITORY}/pulls/${PULL_REQUEST}/merge"',
    '-f sha="$HEAD_SHA"',
    '.parents[0].sha == $base and',
    '.parents[1].sha == $head and',
    'gh workflow run ci.yml --repo "$GITHUB_REPOSITORY" --ref main',
    'Exact-main qualification:'
)) {
    Require-Text -Text $receiver -Expected $required -Label 'update-git-slop.yml'
}

foreach ($forbidden in @(
    'schedule:',
    'pull_request_target:',
    'repository_dispatch:',
    'secrets.GITHUB_TOKEN',
    'secrets.SCOOP_BUCKET_DISPATCH_TOKEN',
    'gh workflow run ci.yml --repo "$GITHUB_REPOSITORY" --ref "$BRANCH"',
    'HEAD:refs/heads/main',
    'gh release create',
    'gh release upload',
    'git tag '
)) {
    Reject-Text -Text $receiver -Rejected $forbidden -Label 'update-git-slop.yml'
}

Require-Count -Text $receiver -Expected 'GH_TOKEN: ${{ secrets.SCOOP_BUCKET_AUTOMATION_TOKEN }}' -Count 2 -Label 'update-git-slop.yml'

foreach ($required in @(
    'pull_request:',
    'push:',
    'workflow_dispatch:',
    'permissions:',
    'contents: read',
    'Windows ${{ matrix.architecture }}',
    'windows-2025',
    'windows-11-arm',
    './scripts/Test-AutomationContract.ps1',
    './scripts/Test-GitSlopManifest.ps1',
    './scripts/Test-GitSlopInstall.ps1'
)) {
    Require-Text -Text $ci -Expected $required -Label 'ci.yml'
}

foreach ($forbidden in @(
    'secrets.',
    'pull_request_target:'
)) {
    Reject-Text -Text $ci -Rejected $forbidden -Label 'ci.yml'
}

foreach ($required in @(
    'automatic trusted-main receiver',
    'manifest-only pull request',
    'Windows 64bit',
    'Windows arm64',
    'no per-release approval or merge'
)) {
    Require-Text -Text $readme -Expected $required -Label 'README.md'
}

Write-Output 'Trusted Scoop automation contract passed.'
