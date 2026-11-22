# Fork patches

This fork publishes the latest stable release of
[steamEngineer/bravia-quad-homeassistant](https://github.com/steamEngineer/bravia-quad-homeassistant)
with the patches in this directory applied. Home Assistant's Marketplace
installs it from this fork's releases.

The `Sync upstream release` workflow
([`.github/workflows/sync-upstream.yml`](../.github/workflows/sync-upstream.yml),
script [`.github/scripts/build-release.sh`](../.github/scripts/build-release.sh))
runs every 6 hours, on a push that changes a patch, and on demand. When the
upstream release or the patches changed since the last build, it:

1. applies `patches/*.patch` in name order to the upstream release tag
   (`git apply --3way`),
2. sets `manifest.json`'s version to `X.Y.Z.N`: the upstream version plus a
   build number,
3. commits the result to `main` with this fork's `.github/` and `patches/` in
   place of upstream's, and
4. publishes release `vX.Y.Z.N` with the `bravia_quad.zip` asset the
   Marketplace downloads.

Upstream pre-releases are skipped. `main` holds builds only: it is not
upstream's history.

## Patch problems

- **A patch does not apply**: upstream changed the same code and the run
  fails. GitHub emails a failed scheduled run to the account that last
  changed the schedule. Rebase the patch onto the new upstream tag, replace
  the file here and push.
- **A patch is already upstream**: the run succeeds with a warning that the
  patch changes nothing, and the release notes say so. Delete the patch.

## Adding a patch

```sh
git format-patch -1 <commit> -o patches --zero-commit
```

Patches apply on top of each other in name order, so number them.
