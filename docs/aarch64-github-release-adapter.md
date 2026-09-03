# AArch64 GitHub Actions release adapter

## Purpose

This fork integrates the upstream-ready AArch64 support changes on its
canonical `master` branch and keeps GitHub Actions as a storage and
orchestration adapter around the normal Omarchy package tools.

It does not change the upstream release host, rclone destination, release-ring
policy, or x86_64 workflow. Those remain the source design. The fork-specific
adapter exists because this repository publishes each signed rolling pacman
channel as assets in a GitHub Release rather than as a complete filesystem tree
on the upstream repository host.

## Boundary with the upstream-ready layer

The following responsibilities remain in the shared package tooling:

- AArch64 recipe selection and package-local `.omarchy` patches/hooks;
- native Docker image construction and `makepkg` execution;
- package dependency ordering and version comparison;
- package signing and promotion;
- existing edge/rc/stable behavior for the upstream repository host.

The GitHub adapter adds only:

- the fork's package-base scope and signing identity;
- download and verification of the previous rolling database;
- handoff of the checked-in repository public key and pinned fingerprint to
  pacman before it consumes that signed baseline;
- an optional remote package server when the local workspace contains the
  database but not every unchanged archive;
- incremental database assembly and complete-transaction validation;
- channel-isolated Release tags and forward-only package advancement;
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

## Branch contract

This fork keeps the same long-lived package-repository branches as upstream:

- `master` is the canonical integration and build-host branch. It follows
  `upstream/master` and is the source of edge builds plus the normal fast-ring
  builds for initialized rc and stable repositories. It does not mean the
  stable channel.
- `rc` is a standing release-control branch rebuilt from `master` when a
  release candidate is cut. Its only intended difference is the pinned
  `omarchy` and `omarchy-settings` candidate pair. A build from this branch is
  the only one allowed to set `OMARCHY_RC_PINS=1`.

`edge`, `rc`, and `stable` are signed repository/Release states. They are not
three parallel development branches, and no `edge` or `stable` Git branch is
maintained. Temporary `auto/*` branches belong to one synchronization pull
request and are deleted after it is merged, closed, or superseded. Feature
branches such as the upstream AArch64 contribution exist only for the lifetime
of their pull request. Historical pre-migration commits are retained as
immutable annotated `archive/*` tags instead of live backup branches.

The generic AUR, upstream-release, and dependency-rebuild schedules remain
owned by `omacom/omarchy-pkgs`. In this fork those workflows run only when a
maintainer dispatches them explicitly; normal intake comes from reviewed
`upstream/master` merges. This prevents both repositories from opening the
same automated pull request while retaining a deliberate recovery/debug path.

## Channel model

The adapter implements the same three channels and release rules as the shared
tooling. It does not introduce a fourth `dev` channel. The development pair,
`omarchy-dev` and `omarchy-settings-dev`, is explicitly edge-only in its package
metadata.

The package sources follow the same split. Stable and RC use the normal
`omarchy`/`omarchy-settings` pair pinned to a reviewed AArch64-adapted commit;
edge and dev use `omarchy-dev`/`omarchy-settings-dev` from the adapted
`quattro` branch. The adapter never packages an unmodified
`basecamp/omarchy` checkout for AArch64, because that would discard the native
Arch Linux ARM pacman configuration and channel mapping during a channel
change.

The fork must retain the upstream `_pkgver_base_tag` used by these VCS
recipes. The AArch64 development recipes fail closed when that tag is absent;
otherwise `pkgver()` would silently switch from post-tag counting to whole
history counting and create a version sequence that no longer matches the
upstream development packages.

Likewise, `alpha`, `beta`, and `rc` in `bin/omarchy-pkgs release` are package
version labels, not additional repository channels. Their pinned artifacts are
published to the repository channel selected by the upstream release workflow;
the storage layout remains exactly `edge`, `rc`, and `stable`.

| Channel | Managed tag | Client URL | Repository scope | Native build scope |
| --- | --- | --- | ---: | ---: |
| edge | `aarch64-edge` | `releases/download/aarch64-edge` | 121 bases | 121 bases |
| rc | `aarch64-rc` | `releases/download/aarch64-rc` | 119 bases | metadata-derived fast ring, plus 2 pinned bases only from the `rc` branch |
| stable | `aarch64-stable` | `releases/download/aarch64-stable` | 119 bases | metadata-derived fast ring |

The scope is derived from the same `channels`, `release_ring`, and `pinned`
metadata functions used by `bin/repo`. Normal packages are built in edge and
their exact signed archives move forward through `edge → rc → stable`.
Fast-ring packages are built independently against all three channel images.
The pinned release pair can be built for rc only when `OMARCHY_RC_PINS=1`, which
the workflow sets only for the standing `rc` branch.

Stable is the only formal/latest GitHub Release. Edge and rc are prereleases,
so the existing `/releases/latest/download` stable client URL cannot
accidentally switch channels.

Both the adapter entry point and the low-level publisher require the target
tag to equal `aarch64-<channel>`. A command, environment override, or stale
baseline marker cannot direct an edge/rc manifest at `aarch64-stable`; the
publisher also rechecks the manifest channel before its first upload. This
makes stable client isolation a fail-closed invariant rather than a workflow
input convention.

The GitHub backend exposes the upstream transitions directly:

```sh
# One-time seed of rc from the existing stable repository
bin/github-release-aarch64 advance --from stable --to rc --bootstrap

# Open and ship a train
bin/github-release-aarch64 advance --from edge --to rc
bin/github-release-aarch64 advance --from rc --to stable
```

Advancement reads the signed source database, applies the shared destination
eligibility rules, downloads only archives absent from the destination, verifies
their source SHA-256 entries and detached signatures, rebuilds and signs the
destination database, resolves every destination package transaction, and then
uses the same atomic Release publisher. All selected archives are downloaded in
one Release operation so bootstrap does not repeat the asset-list API request
for every package. The Ubuntu runner host only reads the trusted PKGBUILD
identity variables needed to match database entries; Arch-specific metadata
generation, build selection, and repository auditing remain inside the normal
native Arch builder image. Reverse movement and stable-to-rc
movement without the explicit one-time bootstrap flag fail before any network
mutation.

## Zero-baseline full validation

The zero-baseline path is edge-only and is designed to run directly on a native
AArch64 host.
It is a separate, read-only validation path rather than an unusual form of
incremental release; a hosted manual dispatch may invoke the same commands,
but is not required for acceptance:

1. `seed --channel edge --no-baseline` deletes the generated repository workspace and creates
   only a full-rebuild marker. It does not call the GitHub Release API, download
   a database, or copy baseline checksums.
2. With no final database available for version comparison, the regular
   builder selects every one of the 121 scoped package bases. Dependencies built
   earlier in the run are resolved through its normal local build database;
   distribution dependencies still come from the native Arch Linux ARM repos.
3. Repository preparation receives no remote Omarchy package server. It
   requires every filename recorded in the new repository database, and its
   detached signature, to exist in the current local build result.
4. Every package signature is verified. Each archive's `.PKGINFO` must name a
   scoped package and package base and report `arch = aarch64` or `arch = any`.
   The same generic package auditor used by the native builder then recursively
   opens Electron ASAR, SquashFS/AppImage, and libarchive-supported containers.
   AppImages are inspected without executing their vendor runtime. Every ELF
   machine must be AArch64, while Mach-O, PE, and DOS executables fail until a
   package-local recipe has reviewed and removed them.
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

The manifest records both the complete archive filename set and a normalized
package-name/version state derived from the final signed repository database.
It is intentionally not derived from the locally changed archives: an
incremental release would otherwise omit unchanged packages and could not be
used as a complete immutable input by an image builder. The manifest also pins
the package-repository commit that assembled that state.

The audit records the package name, base, version, declared architecture,
archive and signature SHA-256 hashes, expanded file and byte counts, ELF and
managed-PE counts, reviewed/unreviewed wrong-architecture ELF and foreign
executable counts, nested-container count, and maximum recursion depth for
every archive produced in the run. Package-local exact file/container policies
are selected by package output, including split PKGBUILDs. The complete package
repository remains on the local disk, so it can be inspected and reused
without an upload/download cycle; every archive is still recursively opened,
hashed, signature-checked, indexed, and consumed by pacman.

This validation proves package construction, target architecture, signing,
repository completeness, and dependency solvability. It does not prove that
every graphical application starts successfully on a particular AArch64
machine. Representative runtime smoke tests on supported ARM hardware should
remain a separate follow-up rather than being hidden in the release adapter.

## Package scope

The adapter configures 121 package bases from two deliberately separate manifests:

- `config/aarch64-packages` is the reviewed 118-base range that the shared
  AArch64 layer selects for an `edge/aarch64` build, including the two
  edge-only development packages;
- `config/aarch64-fork-packages` appends only the three explicit fork packages
  below.

The three fork-only packages remain explicit in
`config/aarch64-fork-packages`:

- `omarchy-aarch64-keyring` distributes this repository's public signing key;
- `omarchy-aarch64-config` distributes upgradeable generic-VM package
  exclusions and replacements without changing desktop behavior or the shared upstream package scope;
- `omarchy-spice-guest-tools` is a fork-owned guest integration package.

The test suite requires the upstream-aligned manifest to contain 118 unique
bases and the fork overlay to contain exactly the three reviewed additions. It
also independently derives the complete `edge/aarch64` set from package
metadata, requires it to match the combined manifests, and checks that removing
the overlay yields the upstream-aligned manifest exactly. Finally, it generates
`.SRCINFO` with `CARCH=aarch64` for every scoped base and requires the derived
edge, rc, and stable repository scopes to remain 121/119/119, requires the edge
build scope to equal its complete repository scope, and requires rc and stable
to derive the same fast-ring set from current metadata. An RC-branch build must
add exactly the two pinned bases. Upstream package additions, removals, ring or
channel changes, or accidental fork-only additions cannot drift silently.

The integration also carries forward the current fork's newer package state
where the shared upstream contribution alone would be a downgrade:

- the fork source revisions of the paired `omarchy` and `omarchy-settings`;
- the published Limine package revision floor; its AArch64 UEFI/runtime patch
  and sync hook are maintained in the shared AArch64 layer;
- the published rebuild revisions for `tensaku` and `tzupdate`;
- T3 Code 0.0.37, updated through the shared upstream-sync mechanism while
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

1. Download metadata for the selected `aarch64-<channel>` Release.
2. Verify the checked-in public-key fingerprint, checksums, and signed baseline
   database.
3. Derive the channel's native build set through the shared package metadata,
   pass the checked-in key and fingerprint to the generic builder, and build
   only versions missing from that channel database with `bin/repo build`.
4. Sign and promote changed archives with `bin/repo sign` and
   `bin/repo promote`.
5. Update the previous database with changed or advanced packages, remove
   entries outside the selected channel's declared scope, and sign the new
   database with the manifest channel set explicitly.
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

The signed baseline is also part of the build dependency path, not only the
final repository check. The adapter passes the read-only checked-in public key
and `config/aarch64-signing-fingerprint` through the generic builder's explicit
key interface before pacman synchronizes the baseline. A missing, unreadable,
multi-key, or mismatched key fails before package selection; signature checking
is not disabled to make incremental builds work.

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
only `contents: write`. Pushes to `master` update edge and every already
initialized rc/stable channel; an uninitialized non-edge channel is skipped
until its explicit bootstrap. Pushes to `rc` update only rc and enable the
shared pinned-package guard. Manual `release` runs select one channel and are
incremental/non-publishing by default. A manual full rebuild is accepted only
for edge and can never publish. The three manual advancement operations map to
RC bootstrap, edge-to-rc advance, and rc-to-stable advance. RC bootstrap
remains a stable-based operation, but its first publication is atomic: after
staging the stable baseline it overlays packages that are currently eligible
to move from edge, then audits and publishes the resulting snapshot once. This
keeps a legacy stable archive that has already been superseded by a reviewed
edge correction from becoming a briefly visible or unauditable RC baseline.
Fast-ring packages are not overlaid; they remain native RC builds. If stable
and edge contain a forwardable package with the same versioned filename but
different independently built bytes, only the unpublished staged copy may be
replaced; an existing target Release asset remains immutable and a different
digest still fails closed.

The initial fork rollout is deliberate: retain the already validated
`aarch64-stable`, publish the first `aarch64-edge`, update the legacy stable
snapshot so its two edge-only development packages are removed, bootstrap
`aarch64-rc` from that stable snapshot plus the current forwardable edge
deltas, and then use only forward advancement. The combined first snapshot is
audited before it becomes visible. No workflow silently constructs rc or
stable by rebuilding the complete edge set.

## Validation checklist

Do not change a production channel based only on static tests:

1. Run all repository self-tests and the adapter test.
2. On a native AArch64 host, export the fork's signing key and run
   `bin/github-release-aarch64 full-rebuild`. Confirm that seeding reports an
   empty, non-publishable repository and that no emulation setup appears.
3. Inspect the generated local evidence. Confirm the manifest reports
   `validation_mode=full`, 121 package bases, and the expected signing
   fingerprint; confirm the audit covers every filename in the database.
4. Inspect the build logs for the complete package selection and successful
   `pacman -Sp` validation. Any wrong-architecture archive or ELF would have
   failed before this point.
5. Seed a disposable copy from the locally generated signed repository and run
   the incremental build path. Versioned packages and unchanged VCS refs must
   remain up to date; any queued VCS package must correspond to a ref that
   genuinely advanced after the zero-baseline build.
6. Review the branch diff once more and publish only after those checks pass.

The zero-baseline run is expected to be expensive. That is an operational
limitation, not a reason to add emulation or a parallel package-building
implementation.

On 2026-08-30, the current tree completed a native, local, non-publishing
zero-baseline run: 118 package bases produced 147 archives (113 `aarch64` and
34 `any`). The audit inspected 92,535 regular files and 563 AArch64 ELF files;
all package and repository signatures verified, all 305 `SHA256SUMS` entries
matched, the manifest/audit/database named the same 147 archives, and pacman
resolved every scoped output independently.

Those historical counts came from the earlier ELF-only auditor and therefore
do not certify opaque nested containers or non-ELF executable formats. The
hardened auditor was exercised through the normal native Docker build with
Typora, Cursor, Copilot CLI, T3 Code, VS Code, and all six outputs of the .NET
split PKGBUILD. Every build passed without QEMU; only VS Code's documented,
checksum-reviewed nested x64 seccomp helper and .NET's five output-scoped
Windows tooling assets remained.

The published stable snapshot was then downloaded read-only and verified
against all 145 package checksums before an independent recursive audit. It
expanded 287,417 files (21.8 GB) and 422 containers. 140 archives passed; the
five historical Cursor, Copilot CLI, T3 Code, Typora, and VS Code revisions
contained exactly the foreign payloads removed by the new recipes. No
stable-only defect was found. A subsequent zero-baseline run should still be
retained as the first recursive audit of a newly built complete 118-base
repository; until then, the earlier run remains valid for its stated signing,
completeness, and dependency evidence, while the stable audit remains evidence
about its downloaded historical archives.

The first audit also caught a generic output-discovery bug: a PKGBUILD that
consumed an official `.pkg.tar.zst` source caused the source archive to be
mistaken for a makepkg output. The builder now copies only paths reported by
`makepkg --packagelist`; an isolated Chromium rebuild produced and indexed
only `omarchy-chromium-bin`, and the complete audit then passed. A follow-up
incremental dry-run kept every versioned package and unchanged VCS ref current.
Only the two `quattro` development packages were queued because that branch
advanced from `158e8cf` to `002c70a` during the multi-hour validation, which is
the intended VCS update behavior. No GitHub workflow or QEMU was used.

A later production rehearsal published the same 118-base/147-archive scope to
the managed `aarch64-stable` Release under the former single-channel model and
independently verified all 305 referenced asset digests, four repository
signatures, the configured signing fingerprint, and exact
manifest/audit/database package-name parity. The first channel-aware stable
publication deliberately reduces that legacy snapshot to 116 bases by removing
the two edge-only development packages. Its first automatic
incremental follow-up exposed a missing pacman key handoff before any Release
mutation occurred. After adding the generic pinned-key interface, a local
native ARM reproduction synchronized that production-signed database and
correctly skipped an up-to-date package; a deliberately wrong fingerprint
failed before repository synchronization.

The channel adapter was then rehearsed locally on the same native AArch64 host.
The signed production database selected all 118 edge bases—including
`omarchy-dev` and `omarchy-settings-dev`—and skipped all 118 as current. Separate
stable and bootstrapped-rc runs selected exactly the 40 fast-ring bases present
in that tested snapshot and skipped all 40 as current. The three runs imported the pinned repository
key, synchronized the channel database, and used the regular Docker builder;
none registered binfmt or invoked QEMU. This validates channel isolation and
incremental selection without mutating a GitHub Release.

The first production RC bootstrap on 2026-09-01 then exercised the fail-closed
boundary against the legacy stable snapshot. The complete bootstrap audit
rejected `typora-1.14.9-1-aarch64.pkg.tar.zst` because it still contained the
old x86_64 Mach-O `cld.node`; no RC Release was created. Edge already contained
the reviewed `1.14.9-1.1` cleanup. The atomic bootstrap overlay described above
was added so the corrected forwardable archive replaces that legacy version in
the unpublished workspace before the complete RC audit. The foreign binary is
not allowlisted, copied into RC, or exposed during an intermediate publication.
