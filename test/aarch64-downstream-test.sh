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

cmp -s \
  "$ROOT/pkgbuilds/limine-mkinitcpio-hook/limine-entry-tool-aarch64.patch" \
  "$ROOT/pkgbuilds/limine-mkinitcpio-hook/.omarchy/files/limine-entry-tool-aarch64.patch" ||
  fail "Limine source patch and AUR-sync copy differ"

grep -q 'TARGETARCH.*amd64' "$ROOT/build/Dockerfile" ||
  fail "build container does not isolate the x86_64-only production repo"
grep -q 'OMARCHY_SRC=/omarchy-src' "$ROOT/bin/build" ||
  fail "local Omarchy source override is not mounted into the builder"
grep -q "PKGEXT='.pkg.tar.zst'" "$ROOT/build/Dockerfile" ||
  fail "AArch64 build output is not normalized to zstd package archives"
grep -q -- '--force-explicit' "$ROOT/.github/workflows/release-aarch64.yml" ||
  fail "stable snapshot build does not explicitly bypass upstream release rings"

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
  "$ROOT/pkgbuilds/omarchy-spice-guest-tools/omarchy-spice-guest-tools.install"

echo "PASS: AArch64 package scope and downstream recipes are internally consistent"
