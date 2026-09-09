# Omarchy 4.0.3 AArch64 release preparation

## Source and package pins

- Official source: `v4.0.3`, commit `0534987009061cbe2dacdde4ad564092ab698d12`.
- Adapted source: branch `v4-0-3`, tag `v4.0.3-aarch64.1`, commit
  `d0f3651baae330938f373e40bb5169b23aef91a2`.
- Runtime pair: `omarchy` and `omarchy-settings`, both `4.0.3-1`.
- Source checksum, computed using makepkg's `git archive --format tar`:
  `75478e2aa2ead13c7132edc6e6ff328906dcfa1ef94eb48b52a8f64ccbcc0c5d`.

The source keeps the existing minimal AArch64 compatibility layer: repository
channels, package policy, VM setup, offline ARM64 Node selection, and existing
profile migrations. Desktop and shell files match the official release.

The settings recipe additionally installs the new plocate service drop-in at
`/usr/lib/systemd/system/plocate-updatedb.service.d/10-omarchy.conf`. The 4.0.3
source no longer installs that default through the former setup script.

## Local validation on 2026-09-09

- The CLI suite passed. The shell suite ran all 236 test files; 231 passed on
  the initial run, and the remaining five passed on focused reruns after the
  plocate packaging correction and environment isolation. Some tests report
  environment-dependent skips; this is not graphical acceptance evidence.
- Package coverage tests use `OMARCHY_PKGS_PATH` pointing at this repository.
  The upstream channel test uses a nonexistent `OMARCHY_AARCH64_PROFILE` so
  the development host's installed AArch64 profile cannot change its expected
  upstream clone command. Separate AArch64 profile/runtime tests also passed.
- The network QR test passed outside the sandbox: its mocked credentials are
  local, but its read-only default-route query is denied inside the sandbox.
- `test/aarch64-support-test.sh` passed for 47 package bases, and
  `test/github-release-aarch64-test.sh` passed.
- Both runtime packages built locally on native AArch64 using `OMARCHY_SRC`
  and `makepkg --nodeps`. No installation, QEMU, or binfmt setup was used.
  These builds validate packaging against host tools; they are not clean
  builder dependency-resolution or signed-repository validation.
- Recursive payload audits with `--arch aarch64 --reject-foreign` passed:
  1,177 runtime files and 435 settings files, with no foreign executables or
  audit errors. The settings archive contains the plocate drop-in, Kitty
  system defaults, mise configuration, and sudo expiry tmpfiles configuration.

## Publication sequence

The first edge and RC CI runs exposed an Arch Linux ARM repository mismatch:
`hyprland 0.56.1-3` requires `libaquamarine.so=13-64`, while the published
`aquamarine 0.15.0-2` provides `libaquamarine.so=14-64`. Both runs stopped before
publication. The fork overlay now includes a temporary native rebuild of the
official `0.56.1-3` recipe as `0.56.1-3.1`, retaining its release archive and
checksum. It uses the fast ring so each channel builds against its actual
libraries. Remove this override after ALARM publishes a compatible newer
package; no compositor configuration or source patch is introduced.

The builder also now places `omarchy-build` and the published `omarchy`
repository before the distribution repositories, matching its documented
dependency priority. Otherwise an older package in `extra` shadows the rebuilt
dependency. A fixture checks the exact order, preservation of signature policy,
and idempotence.

This records local preparation, not a published channel update. Publish the
adapted source branch and immutable tag before building from the package pins.
Use the existing native builder and signed repository audit, then advance the
verified artifacts through RC to stable. Build the pinned VM image only after
the stable manifest contains the exact runtime pair. Fresh-install, upgrade,
and graphical VM acceptance remain required before announcing image readiness.
