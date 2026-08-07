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
  `windows-11-arm`; and
- deliberate hash corruption failing before a shim is installed.

The workflow has only `contents: read`, runs no scheduled updater, and carries
no cross-repository credential. `checkver` and `autoupdate` describe a future
candidate; every manifest update still arrives as a reviewed pull request.

## Maintaining The Manifest

After the new Git Slop release is stable and public, render the candidate from
its authoritative checksum file:

```powershell
pwsh ./scripts/New-GitSlopManifest.ps1 -Version 0.9.5
pwsh ./scripts/Test-GitSlopManifest.ps1 -ManifestPath ./bucket/git-slop.json
```

Open a pull request only after both commands pass. CI repeats release identity,
schema, clean-install, uninstall, and bad-hash validation on both supported
architectures. The Scoop core used in CI is pinned to an immutable revision.

Repository layout:

- `bucket/`: public manifests discovered by Scoop;
- `scripts/`: deterministic rendering and validation;
- `tests/fixtures/`: immutable non-published regression manifests; and
- `.github/workflows/ci.yml`: read-only native Windows qualification.
