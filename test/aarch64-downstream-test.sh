#!/bin/bash

set -euo pipefail

ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
SCOPE="$ROOT/config/aarch64-packages"
LOCAL_PACKAGES="$ROOT/config/aarch64-local-packages"
OVERLAY_PACKAGES="$ROOT/config/aarch64-overlay-packages"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mapfile -t packages < <(sed -E '/^[[:space:]]*(#|$)/d' "$SCOPE")
[[ ${#packages[@]} -gt 0 ]] || fail "AArch64 package scope is empty"

duplicates=$(printf '%s\n' "${packages[@]}" | sort | uniq -d)
[[ -z $duplicates ]] || fail "duplicate packages in scope: $duplicates"

for policy_file in "$LOCAL_PACKAGES" "$OVERLAY_PACKAGES"; do
  while IFS= read -r package_name; do
    grep -Fxq "$package_name" < <(sed -E '/^[[:space:]]*(#|$)/d' "$SCOPE") ||
      fail "policy package is outside the AArch64 scope: $package_name"
  done < <(sed -E '/^[[:space:]]*(#|$)/d' "$policy_file")
done

policy_overlap=$(comm -12 \
  <(sed -E '/^[[:space:]]*(#|$)/d' "$LOCAL_PACKAGES" | sort) \
  <(sed -E '/^[[:space:]]*(#|$)/d' "$OVERLAY_PACKAGES" | sort))
[[ -z $policy_overlap ]] || fail "packages have conflicting stable policies: $policy_overlap"

for package_name in "${packages[@]}"; do
  package_dir="$ROOT/pkgbuilds/$package_name"
  [[ -f "$package_dir/PKGBUILD" ]] ||
    fail "missing PKGBUILD for $package_name"
  [[ -f "$package_dir/.omarchy/package.json" ]] ||
    fail "missing metadata for $package_name"
  unreadable_file=$(find "$package_dir" -type f ! -perm -004 -print -quit)
  [[ -z $unreadable_file ]] ||
    fail "builder cannot read package source: ${unreadable_file#$ROOT/}"
  jq -e . "$package_dir/.omarchy/package.json" >/dev/null ||
    fail "invalid metadata for $package_name"

  srcinfo=$(cd "$package_dir" && makepkg --printsrcinfo) ||
    fail "cannot generate .SRCINFO for $package_name"
  grep -Eq '^[[:space:]]+arch = (any|aarch64)$' <<<"$srcinfo" ||
    fail "$package_name does not declare any or aarch64 support"
done

for variable_name in _tag _commit pkgver pkgrel sha256sums; do
  omarchy_value=$(bash -c 'source "$1" >/dev/null 2>&1; declare -p "$2"' _ \
    "$ROOT/pkgbuilds/omarchy/PKGBUILD" "$variable_name")
  settings_value=$(bash -c 'source "$1" >/dev/null 2>&1; declare -p "$2"' _ \
    "$ROOT/pkgbuilds/omarchy-settings/PKGBUILD" "$variable_name")
  [[ ${omarchy_value#*=} == "${settings_value#*=}" ]] ||
    fail "$variable_name differs between omarchy and omarchy-settings"
done

readarray -t omarchy_release < <(
  bash -c '
    source "$1" >/dev/null 2>&1
    printf "%s\n" "$_tag" "$_commit" "$pkgver" "$pkgrel" "${sha256sums[0]}"
  ' _ "$ROOT/pkgbuilds/omarchy/PKGBUILD"
)
tag=${omarchy_release[0]}
commit=${omarchy_release[1]}
pkgver=${omarchy_release[2]}
pkgrel=${omarchy_release[3]}
checksum=${omarchy_release[4]}

[[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-aarch64\.[0-9]+$ ]] ||
  fail "invalid Omarchy AArch64 release tag: $tag"
base_version=${BASH_REMATCH[1]}
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail "invalid Omarchy commit pin: $commit"
[[ $pkgver =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.r[0-9]+\.g([0-9a-f]{12})$ ]] ||
  fail "Omarchy pkgver does not describe its tag and commit: $pkgver"
[[ ${BASH_REMATCH[1]} == "$base_version" && ${BASH_REMATCH[2]} == "${commit:0:12}" ]] ||
  fail "Omarchy pkgver does not match its tag and commit: $pkgver"
[[ $pkgrel =~ ^[1-9][0-9]*$ ]] || fail "invalid Omarchy pkgrel: $pkgrel"
[[ $checksum =~ ^[0-9a-f]{64}$ ]] || fail "invalid Omarchy source checksum"

grep -Fq "#commit=\${_commit}" "$ROOT/pkgbuilds/omarchy/PKGBUILD" ||
  fail "Omarchy source is not tied to its commit pin"
grep -Fq "\"omarchy-settings=\${pkgver}\"" "$ROOT/pkgbuilds/omarchy/PKGBUILD" ||
  fail "Omarchy does not require its matching settings package"
grep -Fq "'omarchy-aarch64-keyring'" "$ROOT/pkgbuilds/omarchy/PKGBUILD" ||
  fail "Omarchy does not install the downstream repository keyring"

key_file="$ROOT/pkgbuilds/omarchy-aarch64-keyring/omarchy-aarch64.gpg"
expected_fingerprint=$(<"$ROOT/config/aarch64-signing-fingerprint")
[[ $expected_fingerprint =~ ^[0-9A-F]{40}$ ]] ||
  fail "invalid configured repository signing fingerprint"
key_home=$(mktemp -d)
trap 'rm -rf "$key_home"' EXIT
chmod 700 "$key_home"
actual_fingerprint=$(GNUPGHOME=$key_home \
  gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null |
  awk -F: '$1 == "fpr" { print $10; exit }')
[[ $actual_fingerprint == "$expected_fingerprint" ]] ||
  fail "unexpected repository signing fingerprint: $actual_fingerprint"
grep -Fxq "$expected_fingerprint:4:" \
  "$ROOT/pkgbuilds/omarchy-aarch64-keyring/omarchy-aarch64-trusted" ||
  fail "repository signing key is not trusted by its keyring"
grep -Fq 'sudo pacman-key --add "$repository_key"' "$ROOT/build/build.sh" ||
  fail "local AArch64 builds do not bootstrap the signed baseline repository key"
grep -Fq "repository_siglevel='Required TrustAll'" "$ROOT/build/build.sh" ||
  fail "local AArch64 builds do not require signatures from the baseline repository"
grep -Fq 'cp --remove-destination "$repo/omarchy.db.tar.zst.sig"' \
  "$ROOT/bin/prepare-github-release" ||
  fail "repository preparation cannot replace repo-add database signature links"
grep -Fq 'repo-add omarchy-build.db.tar.zst "${built_filenames[@]}"' \
  "$ROOT/build/build.sh" ||
  fail "split-package outputs are not all indexed for dependent builds"
grep -Fq -- "--pattern '*.pkg.tar.zst.sig'" \
  "$ROOT/bin/download-aarch64-baseline" ||
  fail "incremental build baseline does not download package signatures"
grep -Fq -- "--pattern 'omarchy.db'" \
  "$ROOT/bin/download-aarch64-baseline" &&
  grep -Fq -- "--pattern 'omarchy.db.sig'" \
    "$ROOT/bin/download-aarch64-baseline" ||
  fail "incremental build baseline lacks pacman's signed database aliases"
grep -Fq 'rm -f -- "$path.sig"' "$ROOT/build/sign-repository.sh" ||
  fail "database signing cannot replace a host-owned incremental signature"

for package_name in bindfs pinta tensaku tzupdate; do
  find "$ROOT/pkgbuilds/$package_name/.omarchy/patches" -name '*.patch' -print -quit |
    grep -q . || fail "$package_name has no reproducible AArch64 overlay"
done

jq -e '.source == "aur" and (.upstream_commit | length == 40)' \
  "$ROOT/pkgbuilds/bindfs/.omarchy/package.json" >/dev/null ||
  fail "bindfs does not follow its pinned AUR recipe"
grep -Eq "^[[:space:]]*arch=.*'aarch64'" "$ROOT/pkgbuilds/bindfs/PKGBUILD" ||
  fail "bindfs does not carry its reproducible AArch64 architecture overlay"
grep -Fq './bin/sync-aur bindfs dotnet-runtime-bin' \
  "$ROOT/.github/workflows/sync-official-stable.yml" ||
  fail "stable synchronization does not follow bindfs AUR updates"

jq -e '
  .source == "aur" and .aur == "dotnet-core-bin"
' "$ROOT/pkgbuilds/dotnet-runtime-bin/.omarchy/package.json" >/dev/null ||
  fail ".NET does not follow the AUR ARM64 binary package base"
grep -Fq "source_aarch64=(" "$ROOT/pkgbuilds/dotnet-runtime-bin/PKGBUILD" ||
  fail ".NET has no ARM64 vendor source"
grep -Fq "runtime_arch=arm64" "$ROOT/pkgbuilds/pinta/PKGBUILD" ||
  fail "Pinta does not build for the linux-arm64 runtime"
grep -Fq "'dotnet-runtime-bin'" "$ROOT/pkgbuilds/pinta/PKGBUILD" ||
  fail "Pinta does not consume the maintained binary .NET runtime"
grep -Fq 'obsidian-${pkgver}-arm64.tar.gz' "$ROOT/pkgbuilds/obsidian/PKGBUILD" ||
  fail "Obsidian does not consume its official ARM64 desktop tarball"

cmp -s \
  "$ROOT/pkgbuilds/limine-mkinitcpio-hook/limine-entry-tool-aarch64.patch" \
  "$ROOT/pkgbuilds/limine-mkinitcpio-hook/.omarchy/files/limine-entry-tool-aarch64.patch" ||
  fail "Limine source patch and AUR-sync copy differ"

limine_package="$ROOT/pkgbuilds/limine-mkinitcpio-hook"
limine_patch="$limine_package/limine-entry-tool-aarch64.patch"
readarray -t limine_release < <(
  bash -c '
    source "$1" >/dev/null 2>&1
    printf "%s\n" "$pkgrel" "${sha256sums[1]}"
  ' _ "$limine_package/PKGBUILD"
)
limine_suffix=$(jq -r '.pkgrel.suffix' "$limine_package/.omarchy/package.json")
[[ ${limine_release[0]} == *.* && ${limine_release[0]##*.} == "$limine_suffix" ]] ||
  fail "Limine pkgrel does not preserve its downstream release suffix"
[[ ${limine_release[1]} == "$(sha256sum "$limine_patch" | awk '{print $1}')" ]] ||
  fail "Limine PKGBUILD does not verify the current downstream patch"
[[ $(grep -Fc 'Target = etc/mkinitcpio.d/*.preset' "$limine_patch") -eq 3 ]] ||
  fail "Limine hooks do not install, update, and remove ALARM preset kernels"
grep -Fq 'KERNEL_IMAGE=/boot/Image' "$limine_patch" ||
  fail "Limine does not use Arch Linux ARM's generic kernel image"
grep -Fq 'aarch64:linux-aarch64 | arm64:linux-aarch64' "$limine_patch" ||
  fail "Limine does not normalize the ALARM kernel to Omarchy's stable UKI name"
grep -Fq 'args+=(--kernelimage "$KERNEL_IMAGE")' "$limine_patch" ||
  fail "Limine does not pass the ALARM kernel image into mkinitcpio's UKI build"
grep -Fq 'isSystemEfiArchitecture()' "$limine_patch" ||
  fail "Limine native entry tool still rejects AArch64 UKIs"
grep -Fq 'System.getenv("LIMINE_FORCE_UEFI")' "$limine_patch" ||
  fail "Limine native entry tool cannot generate UKI entries in an offline image chroot"

grep -q 'TARGETARCH.*amd64' "$ROOT/build/Dockerfile" ||
  fail "build container does not isolate the x86_64-only production repo"
grep -q 'OMARCHY_SRC=/omarchy-src' "$ROOT/bin/build" ||
  fail "local Omarchy source override is not mounted into the builder"
grep -q "PKGEXT='.pkg.tar.zst'" "$ROOT/build/Dockerfile" ||
  fail "AArch64 build output is not normalized to zstd package archives"
grep -q -- '--force-explicit' "$ROOT/.github/workflows/release-aarch64.yml" ||
  fail "stable snapshot build does not explicitly bypass upstream release rings"
grep -Fq -- '--rebuild-explicit requires --package' "$ROOT/bin/build" ||
  fail "an unpublished same-version AArch64 package cannot be rebuilt explicitly"
grep -Fq -- '-e SRCDEST=/srcdest' "$ROOT/bin/build" &&
  grep -Fq -- '-v "$SRCDEST_DIR:/srcdest"' "$ROOT/bin/build" ||
  fail "makepkg source downloads are not persisted across container builds"

bash -n \
  "$ROOT/bin/check-official-stable" \
  "$ROOT/bin/download-aarch64-baseline" \
  "$ROOT/bin/prepare-github-release" \
  "$ROOT/bin/release-aarch64" \
  "$ROOT/bin/sign-database" \
  "$ROOT/bin/sync-official-stable" \
  "$ROOT/bin/sync-omarchy-aarch64" \
  "$ROOT/build/sign-repository.sh" \
  "$ROOT/build/validate-repository.sh" \
  "$ROOT/helpers/aarch64-stable.sh" \
  "$ROOT/pkgbuilds/limine-mkinitcpio-hook/.omarchy/post-sync.sh" \
  "$ROOT/pkgbuilds/obsidian/.omarchy/upstream.sh" \
  "$ROOT/pkgbuilds/omarchy-spice-guest-tools/omarchy-spice-guest-tools.install"

echo "PASS: AArch64 package scope and downstream recipes are internally consistent"
