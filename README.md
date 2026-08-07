# Git Slop Scoop Bucket

This is the official external [Scoop](https://scoop.sh) bucket for
[Git Slop](https://github.com/coreycoto/git-slop). It installs the existing
checksummed Windows release archives; the bucket does not build Git Slop or add
another asset to its GitHub Release.

The first publishable manifest is reserved for Git Slop 0.9.5. Until that
stable release is public, `bucket/` intentionally contains no `git-slop.json`.
The v0.9.4 manifest under `tests/fixtures/` exercises the complete contract
without advertising an earlier version from this bucket.

## Install

After `bucket/git-slop.json` is published:

```powershell
scoop bucket add coreycoto https://github.com/coreycoto/scoop-bucket
scoop install coreycoto/git-slop
git-slop version
git-slop build-info --format json
git slop version
```

Upgrade in place with `scoop update git-slop`. Uninstall with
`scoop uninstall git-slop`.

## Publication Contract

The manifest supports native Windows x86-64 and ARM64. Each architecture entry
must name its exact `git-slop-v<version>-<target>.zip`, use the literal SHA-256
from the release's seven-line `SHA256SUMS`, and agree with the corresponding
entry in `release-manifest.json`. Validation also requires:

- one stable public release with the exact eight-asset inventory;
- GitHub asset digests matching `SHA256SUMS`;
- the public tag, release manifest, and installed `build-info` sharing one full
  source revision with `source_dirty: false`;
- successful native installation and removal on `windows-2025` and
  `windows-11-arm`;
- an explicitly dispatched cross-version upgrade-in-place proof on both
  Windows architectures for every release after the first published manifest;
  and
- deliberate hash corruption failing before a shim is installed.

The normal release path is an automatic trusted-main receiver. After the stable
Git Slop GitHub Release becomes public, its read-only publication verifier
dispatches only the exact version, release ID, source revision, and release
manifest digest. This bucket carries no cross-repository secret. A separate
bucket-only `SCOOP_BUCKET_AUTOMATION_TOKEN`, scoped to Contents and Pull
requests read/write for this repository, is exposed only to the two trusted-main
steps that push the exact automation branch and open or update its pull request.

The receiver renders one manifest-only pull request. The bucket-only writer
credential lets GitHub start its canonical pull-request CI without a per-release
approval; the credential is never exposed to that CI. The receiver awaits the
required `Windows 64bit` and `Windows arm64` jobs, rechecks the current base, PR
author, single-file allowlist, run identity, and job results, then merges through
the active `main` ruleset. It explicitly dispatches the same native qualification
on the resulting merge commit.
There is no per-release approval or merge for the repository owner.

## Maintaining The Manifest

The automatic receiver owns normal publication. For local review or an
explicit recovery, render the candidate from its authoritative checksum file:

```powershell
pwsh ./scripts/New-GitSlopManifest.ps1 -Version 0.9.5
pwsh ./scripts/Test-GitSlopManifest.ps1 -ManifestPath ./bucket/git-slop.json
```

Both commands are deterministic and idempotent. A receiver recovery uses the
`Update git-slop manifest` workflow on exact current `main` with the same four
immutable values from the public release; it never accepts an archive or hash
that it cannot rederive. CI repeats release identity, schema, clean-install,
uninstall, and bad-hash validation on both supported architectures. The Scoop
core used in CI is pinned to an immutable revision.

After publishing a new manifest, dispatch `CI` on exact current `main` with
`previous_manifest_ref` set to the full ancestor commit that contains the
previous public manifest. That bounded lane installs the previous version,
runs `scoop update` and `scoop update git-slop` without uninstalling, and proves
the pre-update and post-update versions and source revisions on x64 and ARM64.

Repository layout:

- `bucket/`: public manifests discovered by Scoop;
- `scripts/`: deterministic rendering and validation;
- `tests/fixtures/`: immutable non-published regression manifests; and
- `.github/workflows/ci.yml`: read-only native Windows qualification; and
- `.github/workflows/update-git-slop.yml`: trusted release receiver, exact-head
  qualification, governed merge, and exact-main proof.
