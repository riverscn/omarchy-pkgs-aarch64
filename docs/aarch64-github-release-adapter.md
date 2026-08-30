# AArch64 GitHub Actions release adapter

## Purpose

This branch is a replacement experiment for the fork's current `master`
release automation. It starts from the upstream-ready AArch64 support branch
and keeps GitHub Actions as a storage and orchestration adapter around the
normal Omarchy package tools.

It does not change the upstream release host, rclone destination, release-ring
policy, or x86_64 workflow. Those remain the source design. The fork-specific
adapter exists because this repository publishes a signed rolling pacman
repository as assets in one GitHub Release rather than as a complete filesystem
tree on the upstream repository host.

## Boundary with the upstream-ready branch

The following responsibilities remain in the shared package tooling:

- AArch64 recipe selection and package-local `.omarchy` patches/hooks;
- native Docker image construction and `makepkg` execution;
- package dependency ordering and version comparison;
- package signing and promotion;
- existing edge/rc/stable behavior for the upstream repository host.

The GitHub adapter adds only:

- the fork's package-base scope and signing identity;
- download and verification of the previous rolling database;
- an optional remote package server when the local workspace contains the
  database but not every unchanged archive;
- incremental database assembly and complete-transaction validation;
- ordered GitHub Release uploads, with the signed database uploaded last.

`bin/github-release-aarch64` is the entry point. It delegates builds, package
signing, and promotion to `bin/repo`; `build/github-release-prepare.sh` performs
the backend-specific database operation inside the same native builder image;
`bin/publish-github-release` owns the GitHub API boundary.

The hosted runner and the image do not use the same numeric user ID (the
runner is normally 1001; the image's `builder` is 1000). The existing bind-mount
permission helper therefore applies write permissions after its host-side
`chown`, even when that `chown` succeeds. This is a storage compatibility fix,
not a second build path. Repository initialization also fails immediately if
the empty local build database or its first pacman synchronization cannot be
created, instead of repeating one setup failure for every package.

The adapter uses `edge/aarch64` only as the generic builder's local workspace.
The externally published rolling repository is still identified as `stable` in
its manifest. Arch Linux ARM is rolling, and this fork does not implement a
second edge/rc/stable release train. Adding such a train should be discussed as
a separate design rather than hidden in this compatibility layer.

## Zero-baseline full validation

The zero-baseline path is designed to run directly on a native AArch64 host.
It is a separate, read-only validation path rather than an unusual form of
incremental release; a hosted manual dispatch may invoke the same commands,
but is not required for acceptance:

1. `seed --no-baseline` deletes the generated repository workspace and creates
   only a full-rebuild marker. It does not call the GitHub Release API, download
   a database, or copy baseline checksums.
2. With no final database available for version comparison, the regular
   builder selects every one of the 118 scoped package bases. Dependencies built
   earlier in the run are resolved through its normal local build database;
   distribution dependencies still come from the native Arch Linux ARM repos.
3. Repository preparation receives no remote Omarchy package server. It
   requires every filename recorded in the new repository database, and its
   detached signature, to exist in the current local build result.
4. Every package signature is verified. Each archive's `.PKGINFO` must name a
   scoped package and package base and report `arch = aarch64` or `arch = any`.
   The archive is then unpacked and every ELF file is inspected with `readelf`;
   any machine type other than AArch64 fails the run.
5. The newly signed repository is synchronized with pacman, then a complete
   dependency transaction is resolved for every scoped output using only the
   local repository plus the normal Arch Linux ARM repositories. Outputs are
   checked separately because package bases may intentionally publish mutually
   exclusive variants, such as Ollama's CUDA and JetPack backends.

The marker is checked again by the publish command, so a full-rebuild workspace
cannot be published even if a caller bypasses the workflow condition. The
workflow also rejects the contradictory `full_rebuild=true,publish=true`
combination before building.

A successful local run retains two evidence sets in the workspace:

- the signed database and files indexes, public key, `SHA256SUMS`, repository
  manifest, and `repository-build-audit.json`;
- all `bin/repo` build/sign/promote logs.

The audit records the package name, base, version, declared architecture,
archive and signature SHA-256 hashes, regular-file count, and AArch64 ELF count
for every archive produced in the run. The complete package repository remains
on the local disk, so it can be inspected and reused without an upload/download
cycle; every archive is still opened, hashed, signature-checked, indexed, and
consumed by pacman.

This validation proves package construction, target architecture, signing,
repository completeness, and dependency solvability. It does not prove that
every graphical application starts successfully on a particular AArch64
machine. Representative runtime smoke tests on supported ARM hardware should
remain a separate follow-up rather than being hidden in the release adapter.

## Package scope

The adapter builds 118 package bases from two deliberately separate manifests:

- `config/aarch64-packages` is the complete 116-base range that the
  upstream-ready tree selects for an `edge/aarch64` build, including the two
  edge-only development packages;
- `config/aarch64-fork-packages` appends only the two explicit fork packages
  below.

The two fork-only packages remain explicit in
`config/aarch64-fork-packages`:

- `omarchy-aarch64-keyring` distributes this repository's public signing key;
- `omarchy-spice-guest-tools` is a fork-owned guest integration package.

The test suite requires the upstream-aligned manifest to contain 116 unique
bases and the fork overlay to contain exactly the two reviewed additions. It
also independently derives the complete `edge/aarch64` set from package
metadata, requires it to match the combined manifests, and checks that removing
the overlay yields the upstream-aligned manifest exactly. Finally, it generates
`.SRCINFO` with `CARCH=aarch64` for every scoped base. Upstream package
additions, removals, channel changes, or accidental fork-only additions cannot
drift silently.

The integration also carries forward the current fork's newer package state
where the upstream-ready branch alone would be a downgrade:

- the fork source revisions of the paired `omarchy` and `omarchy-settings`;
- the published Limine package revision floor; its AArch64 UEFI/runtime patch
  and sync hook now live in the upstream-ready branch;
- the published rebuild revisions for `tensaku` and `tzupdate`;
- T3 Code 0.0.36, updated through the shared upstream-sync mechanism while
  retaining both the existing x86_64 AppImage and native AArch64 source build.

These are package/product differences, not release-backend code. Migration
tests record their current versions as minimums so the first run cannot replace
an already published package with an older recipe.

## Native-only build invariant

The workflow runs on `ubuntu-24.04-arm`, and the adapter exits before invoking
Docker unless `uname -m` reports ARM64. It does not register binfmt handlers,
install QEMU, or request an emulated platform. The upstream builder's existing
cross-host behavior is unchanged; the GitHub adapter simply never takes that
path.

## Publication transaction

1. Download metadata for the managed `aarch64-stable` Release.
2. Verify the checked-in public-key fingerprint, checksums, and signed baseline
   database.
3. Build only versions missing from that database with `bin/repo build`.
4. Sign and promote changed archives with `bin/repo sign` and
   `bin/repo promote`.
5. Update the previous database with changed packages, remove entries outside
   the declared scope, and sign the new database.
6. Require every scoped package output in the database and resolve each
   output's complete pacman dependency transaction using local changed archives
   plus unchanged Release assets.
7. Upload immutable package archives first, supporting metadata next, database
   signatures next, and database aliases last.
8. Delete only assets no longer referenced by the managed rolling Release.
   Other Releases and tags are outside the adapter's ownership.

GitHub does not preserve `:` in Release asset names. Epoch-bearing package
filenames are therefore normalized to `_epoch_` before `repo-add`; the package
contents and internal epoch version remain unchanged.

## Failure and recovery behavior

This implementation deliberately does not publish partial builds. If any
package build, signature, database, or transaction validation fails, the
existing Release database remains visible and unchanged. A rerun compares
against that unchanged database and retries the missing versions.

If an upload is interrupted before the database switch, the next run recognizes
already uploaded package assets by GitHub's SHA-256 digest and resumes without
transferring them again. If interruption happens after the signed database is
visible, clients already see the new consistent repository; the next run can
finish removal of stale assets.

This is intentionally simpler than the current `master` machinery for partial
releases, cross-run artifact reuse, supplemental run IDs, and separate desired
version state. Reintroducing partial publication would expand the adapter and
should be justified by measured runner cost and failure frequency.

## GitHub configuration

The `release` environment must provide:

- `AARCH64_GPG_PRIVATE_KEY` — armored private key matching
  `config/aarch64-signing-fingerprint`;
- `AARCH64_GPG_PASSPHRASE` — non-interactive key passphrase.

The workflow uses the job-scoped `github.token` for Release access and declares
only `contents: write`. Pushes to `master` use the verified baseline and publish
incrementally. Manual runs default to a zero-baseline full rebuild without
publishing. To exercise the incremental path manually, select
`full_rebuild=false`; `publish=true` must also be selected explicitly to update
the rolling Release.

## Replacement checklist

Do not replace `master` based only on static tests. Before cutover:

1. Run all repository self-tests and the adapter test.
2. On a native AArch64 host, export the fork's signing key and run
   `bin/github-release-aarch64 full-rebuild`. Confirm that seeding reports an
   empty, non-publishable repository and that no emulation setup appears.
3. Inspect the generated local evidence. Confirm the manifest reports
   `validation_mode=full`, 118 package bases, and the expected signing
   fingerprint; confirm the audit covers every filename in the database.
4. Inspect the build logs for the complete package selection and successful
   `pacman -Sp` validation. Any wrong-architecture archive or ELF would have
   failed before this point.
5. Seed a disposable copy from the locally generated signed repository and run
   the incremental build path. Versioned packages and unchanged VCS refs must
   remain up to date; any queued VCS package must correspond to a ref that
   genuinely advanced after the zero-baseline build.
6. Review the branch diff once more, then fast-forward or merge it into the
   fork's `master` only after those checks pass.

The zero-baseline run is expected to be expensive. That is an operational
limitation, not a reason to add emulation or a parallel package-building
implementation.

On 2026-08-30, the current tree completed a native, local, non-publishing
zero-baseline run: 118 package bases produced 147 archives (113 `aarch64` and
34 `any`). The audit inspected 92,535 regular files and 563 AArch64 ELF files;
all package and repository signatures verified, all 305 `SHA256SUMS` entries
matched, the manifest/audit/database named the same 147 archives, and pacman
resolved every scoped output independently.

The first audit also caught a generic output-discovery bug: a PKGBUILD that
consumed an official `.pkg.tar.zst` source caused the source archive to be
mistaken for a makepkg output. The builder now copies only paths reported by
`makepkg --packagelist`; an isolated Chromium rebuild produced and indexed
only `omarchy-chromium-bin`, and the complete audit then passed. A follow-up
incremental dry-run kept every versioned package and unchanged VCS ref current.
Only the two `quattro` development packages were queued because that branch
advanced from `158e8cf` to `002c70a` during the multi-hour validation, which is
the intended VCS update behavior. No GitHub workflow or QEMU was used.
