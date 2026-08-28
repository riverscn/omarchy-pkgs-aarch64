#!/bin/bash

set -euo pipefail

ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
SCOPE="$ROOT/config/aarch64-packages"
LOCAL_PACKAGES="$ROOT/config/aarch64-local-packages"
OVERLAY_PACKAGES="$ROOT/config/aarch64-overlay-packages"
EXCLUDED_PACKAGES="$ROOT/config/aarch64-excluded-packages"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

read_scope() {
  sed -E '/^[[:space:]]*(#|$)/d' "$1"
}

mapfile -t packages < <(read_scope "$SCOPE")
[[ ${#packages[@]} -eq 89 ]] || fail "expected 89 AArch64 package bases, found ${#packages[@]}"
duplicates=$(printf '%s\n' "${packages[@]}" | sort | uniq -d)
[[ -z $duplicates ]] || fail "duplicate packages in scope: $duplicates"

mapfile -t excluded_packages < <(read_scope "$EXCLUDED_PACKAGES")
[[ ${#excluded_packages[@]} -eq 46 ]] || fail "expected 46 audited exclusions, found ${#excluded_packages[@]}"
excluded_duplicates=$(printf '%s\n' "${excluded_packages[@]}" | sort | uniq -d)
[[ -z $excluded_duplicates ]] || fail "duplicate packages in exclusions: $excluded_duplicates"
scope_overlap=$(comm -12 <(printf '%s\n' "${packages[@]}" | sort) <(printf '%s\n' "${excluded_packages[@]}" | sort))
[[ -z $scope_overlap ]] || fail "package is both included and excluded: $scope_overlap"
diff -u \
  <(find "$ROOT/pkgbuilds" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort) \
  <(printf '%s\n' "${packages[@]}" "${excluded_packages[@]}" | sort) ||
  fail "included and excluded lists do not cover every package base"

mapfile -t expected_scope <<'EOF'
bindfs
dotnet-runtime-bin
gradle
omarchy-aarch64-keyring
omarchy-keyring
limine-mkinitcpio-hook
limine-snapper-sync
omarchy-settings
omarchy
omarchy-spice-guest-tools
aether
basecamp-cli
omarchy-audio-tuner
omarchy-fish
omarchy-zsh
cliamp
herdr
localsend
mise-bin
obsidian
omacalc
omacut
omarchy-emacs
omarchy-nvim
omawrite
omazed
pinta
tensaku
tobi-try
ttf-ia-writer
ttf-jetbrains-mono-nerd-basic
ttfx
tzupdate
ufw-docker
xdg-terminal-exec
yaru-icon-theme
yay
1password-cli
1password
bitwarden
brave-bin
brave-origin-bin
bun-bin
crush-bin
cursor-cli
cursor-bin
dbxcli-bin
ghostty
github-copilot-cli
google-chrome
grok-bot
hermes-desktop
heroic-games-launcher-bin
hyprshade
lmstudio-bin
nautilus-open-any-terminal
nordvpn-bin
ollama
omasnap
omatrack
once-bin
openai-codex-desktop
quickshell-git
rustdesk
sublime-text-4
sunshine
symfony-cli
t3code-bin
typora
visual-studio-code-bin
voxtype-bin
zed
zen-browser-bin
asdcontrol
hyprland-preview-share-picker
qmk-hid
v4l2-relayd
xpadneo-dkms
yt6801-dkms
libretro-blastem
libretro-cap32-git
libretro-database-git
libretro-desmume
libretro-fbneo-git
libretro-kronos
libretro-ppsspp
libretro-uae-git
libretro-vice-git
retroarch-joypad-autoconfig-git
EOF
diff -u <(printf '%s\n' "${expected_scope[@]}") <(printf '%s\n' "${packages[@]}") ||
  fail "AArch64 scope differs from the audited package set"

[[ $(read_scope "$LOCAL_PACKAGES" | wc -l) -eq 26 ]] || fail "unexpected local-policy package count"
[[ $(read_scope "$OVERLAY_PACKAGES" | wc -l) -eq 18 ]] || fail "unexpected overlay package count"
for policy_file in "$LOCAL_PACKAGES" "$OVERLAY_PACKAGES"; do
  while IFS= read -r package_name; do
    grep -Fxq "$package_name" < <(read_scope "$SCOPE") ||
      fail "policy package is outside the AArch64 scope: $package_name"
  done < <(read_scope "$policy_file")
done
policy_overlap=$(comm -12 <(read_scope "$LOCAL_PACKAGES" | sort) <(read_scope "$OVERLAY_PACKAGES" | sort))
[[ -z $policy_overlap ]] || fail "packages have conflicting stable policies: $policy_overlap"

output_count=0
for package_name in "${packages[@]}"; do
  package_dir="$ROOT/pkgbuilds/$package_name"
  [[ -f "$package_dir/PKGBUILD" ]] || fail "missing PKGBUILD for $package_name"
  [[ -f "$package_dir/.omarchy/package.json" ]] || fail "missing metadata for $package_name"
  unreadable_file=$(find "$package_dir" -type f ! -perm -004 -print -quit)
  [[ -z $unreadable_file ]] || fail "builder cannot read package source: ${unreadable_file#$ROOT/}"
  jq -e . "$package_dir/.omarchy/package.json" >/dev/null || fail "invalid metadata for $package_name"
  jq -e 'has("pkgrel")' "$package_dir/.omarchy/package.json" >/dev/null 2>&1 &&
    fail "$package_name carries forbidden dotted pkgrel metadata"

  srcinfo=$(cd "$package_dir" && CARCH=aarch64 makepkg --printsrcinfo) ||
    fail "cannot generate .SRCINFO for $package_name"
  printf '%s\n' "$srcinfo" > "$TEST_TMP/$package_name.srcinfo"
  grep -Eq '^[[:space:]]+arch = (any|aarch64)$' <<<"$srcinfo" ||
    fail "$package_name does not declare any or aarch64 support"
  release=$(awk -F' = ' '$1 ~ /^[[:space:]]*pkgrel$/ { print $2; exit }' <<<"$srcinfo")
  [[ $release =~ ^[1-9][0-9]*(\.[0-9]+)*$ ]] || fail "$package_name uses invalid pkgrel=$release"
  output_count=$((output_count + $(grep -Ec '^[[:space:]]*pkgname = ' <<<"$srcinfo")))

  if [[ $package_name != libretro-vice-git ]]; then
    awk -F' = ' -v wanted="$package_name" '
      $1 ~ /^[[:space:]]*pkgname$/ && $2 == wanted { found=1 }
      END { exit !found }
    ' <<<"$srcinfo" || fail "$package_name does not emit its requested package name"
  fi
done
[[ $output_count -eq 119 ]] || fail "expected 119 AArch64 package outputs, found $output_count"

vice_srcinfo=$(<"$TEST_TMP/libretro-vice-git.srcinfo")
for core in x128 x64 x64dtv x64sc xcbm2 xcbm5x0 xpet xplus4 xscpu64 xvic; do
  grep -Fq "pkgname = libretro-vice-$core-git" <<<"$vice_srcinfo" ||
    fail "libretro-vice-git does not emit libretro-vice-$core-git"
done

while IFS= read -r package_name; do
  overlay="$ROOT/pkgbuilds/$package_name/.omarchy"
  has_patch=$(find "$overlay/patches" -type f -name '*.patch' -print -quit 2>/dev/null || true)
  [[ -n $has_patch || -x $overlay/post-sync.sh ]] ||
    fail "$package_name has no reproducible AArch64 overlay"
done < <(read_scope "$OVERLAY_PACKAGES")

for variable_name in _tag _commit pkgver pkgrel sha256sums; do
  omarchy_value=$(bash -c 'source "$1" >/dev/null 2>&1; declare -p "$2"' _ \
    "$ROOT/pkgbuilds/omarchy/PKGBUILD" "$variable_name")
  settings_value=$(bash -c 'source "$1" >/dev/null 2>&1; declare -p "$2"' _ \
    "$ROOT/pkgbuilds/omarchy-settings/PKGBUILD" "$variable_name")
  [[ ${omarchy_value#*=} == "${settings_value#*=}" ]] ||
    fail "$variable_name differs between omarchy and omarchy-settings"
done

readarray -t omarchy_release < <(
  bash -c 'source "$1" >/dev/null 2>&1; printf "%s\n" "$_tag" "$_commit" "$pkgver" "$pkgrel" "${sha256sums[0]}"' \
    _ "$ROOT/pkgbuilds/omarchy/PKGBUILD"
)
tag=${omarchy_release[0]}
commit=${omarchy_release[1]}
pkgver=${omarchy_release[2]}
pkgrel=${omarchy_release[3]}
checksum=${omarchy_release[4]}
[[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-aarch64\.[0-9]+$ ]] || fail "invalid Omarchy AArch64 release tag: $tag"
base_version=${BASH_REMATCH[1]}
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail "invalid Omarchy commit pin: $commit"
[[ $pkgver =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.r[0-9]+\.g([0-9a-f]{12})$ ]] ||
  fail "Omarchy pkgver does not describe its tag and commit: $pkgver"
[[ ${BASH_REMATCH[1]} == "$base_version" && ${BASH_REMATCH[2]} == "${commit:0:12}" ]] ||
  fail "Omarchy pkgver does not match its tag and commit"
[[ $pkgrel =~ ^[1-9][0-9]*$ && $checksum =~ ^[0-9a-f]{64}$ ]] || fail "invalid Omarchy release metadata"
grep -Fq '#commit=${_commit}' "$ROOT/pkgbuilds/omarchy/PKGBUILD" || fail "Omarchy source is not commit-pinned"
grep -Fq '"omarchy-settings=${pkgver}"' "$ROOT/pkgbuilds/omarchy/PKGBUILD" || fail "Omarchy pair dependency is not exact"
grep -Fq "'omarchy-aarch64-keyring'" "$ROOT/pkgbuilds/omarchy/PKGBUILD" || fail "Omarchy lacks the repository keyring"

key_file="$ROOT/pkgbuilds/omarchy-aarch64-keyring/omarchy-aarch64.gpg"
expected_fingerprint=$(<"$ROOT/config/aarch64-signing-fingerprint")
[[ $expected_fingerprint =~ ^[0-9A-F]{40}$ ]] || fail "invalid signing fingerprint"
key_home="$TEST_TMP/gnupg"
mkdir -p "$key_home"
chmod 700 "$key_home"
actual_fingerprint=$(GNUPGHOME=$key_home gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null |
  awk -F: '$1 == "fpr" { print $10; exit }')
[[ $actual_fingerprint == "$expected_fingerprint" ]] || fail "unexpected signing fingerprint"
grep -Fxq "$expected_fingerprint:4:" "$ROOT/pkgbuilds/omarchy-aarch64-keyring/omarchy-aarch64-trusted" ||
  fail "repository signing key is not trusted by its keyring"

grep -Fq "source_aarch64=(" "$ROOT/pkgbuilds/dotnet-runtime-bin/PKGBUILD" || fail ".NET lacks an ARM64 source"
grep -Fq "runtime_arch=arm64" "$ROOT/pkgbuilds/pinta/PKGBUILD" || fail "Pinta does not target linux-arm64"
grep -Fq "'dotnet-runtime-bin'" "$ROOT/pkgbuilds/pinta/PKGBUILD" || fail "Pinta lacks its runtime dependency"
grep -Fq 'obsidian-${pkgver}-arm64.tar.gz' "$ROOT/pkgbuilds/obsidian/PKGBUILD" || fail "Obsidian lacks its ARM64 archive"

for mapping in 'bitwarden bitwarden-bin' 'voxtype-bin voxtype' 'zed zed-bin'; do
  read -r package_name aur_name <<<"$mapping"
  jq -e --arg aur "$aur_name" '.source == "aur" and .aur == $aur' \
    "$ROOT/pkgbuilds/$package_name/.omarchy/package.json" >/dev/null ||
    fail "$package_name does not track the intended AUR source package"
done

ollama_srcinfo=$(<"$TEST_TMP/ollama.srcinfo")
for output in ollama ollama-vulkan ollama-cuda ollama-cuda-jetpack5 ollama-cuda-jetpack6; do
  grep -Fq "pkgname = $output" <<<"$ollama_srcinfo" || fail "Ollama does not emit $output"
done
grep -Fq 'ollama-linux-arm64-jetpack5.tar.zst' "$ROOT/pkgbuilds/ollama/PKGBUILD" || fail "Ollama lacks JetPack 5"
grep -Fq 'ollama-linux-arm64-jetpack6.tar.zst' "$ROOT/pkgbuilds/ollama/PKGBUILD" || fail "Ollama lacks JetPack 6"
grep -Fq 'OLLAMA_VULKAN=1' "$ROOT/pkgbuilds/ollama/ollama-vulkan.conf" || fail "Ollama Vulkan is not enabled"
grep -qi rocm "$ROOT/pkgbuilds/ollama/PKGBUILD" && fail "Ollama incorrectly ships an ARM ROCm backend"

t3_srcinfo=$(<"$TEST_TMP/t3code-bin.srcinfo")
grep -Fq 'arch = aarch64' <<<"$t3_srcinfo" || fail "T3 Code is not AArch64-only"
grep -Fq 't3code/archive/refs/tags/' "$ROOT/pkgbuilds/t3code-bin/PKGBUILD" || fail "T3 Code does not build tagged source"
grep -Fq -- '--target AppImage --arch arm64' "$ROOT/pkgbuilds/t3code-bin/PKGBUILD" || fail "T3 Code does not build ARM64"

heroic_srcinfo=$(<"$TEST_TMP/heroic-games-launcher-bin.srcinfo")
grep -Fq 'arch = aarch64' <<<"$heroic_srcinfo" || fail "Heroic is not AArch64-only"
grep -Fq 'HeroicGamesLauncher/archive/refs/tags/' "$ROOT/pkgbuilds/heroic-games-launcher-bin/PKGBUILD" ||
  fail "Heroic does not build tagged source"
for helper in legendary gogdl nile comet GalaxyCommunication EpicGamesLauncher; do
  grep -Fq "$helper" "$ROOT/pkgbuilds/heroic-games-launcher-bin/PKGBUILD" ||
    fail "Heroic lacks its $helper helper"
done
grep -Fq -- 'electron-builder --linux pacman --arm64' "$ROOT/pkgbuilds/heroic-games-launcher-bin/PKGBUILD" ||
  fail "Heroic does not produce an ARM64 Linux package"

rustdesk_srcinfo=$(<"$TEST_TMP/rustdesk.srcinfo")
grep -Fq 'rustdesk-1.4.9-aarch64.deb' <<<"$rustdesk_srcinfo" || fail "RustDesk lacks its official AArch64 artifact"
grep -Fq 'arch = aarch64' <<<"$rustdesk_srcinfo" || fail "RustDesk is not AArch64-only"

ghostty_srcinfo=$(<"$TEST_TMP/ghostty.srcinfo")
for output in ghostty ghostty-shell-integration ghostty-terminfo ghostty-nautilus; do
  grep -Fq "pkgname = $output" <<<"$ghostty_srcinfo" || fail "Ghostty does not emit $output"
done

grep -Fq "arch=('any')" "$ROOT/pkgbuilds/yt6801-dkms/PKGBUILD" || fail "yt6801 DKMS sources are not architecture-independent"
for package_name in github-copilot-cli hermes-desktop omasnap qmk-hid v4l2-relayd; do
  srcinfo=$(<"$TEST_TMP/$package_name.srcinfo")
  grep -Fq 'arch = aarch64' <<<"$srcinfo" || fail "$package_name lacks native AArch64 support"
  grep -Fq 'arch = x86_64' <<<"$srcinfo" || fail "$package_name dropped its verified x86_64 support"
done

limine_package="$ROOT/pkgbuilds/limine-mkinitcpio-hook"
limine_patch="$limine_package/limine-entry-tool-aarch64.patch"
cmp -s "$limine_patch" "$limine_package/.omarchy/files/limine-entry-tool-aarch64.patch" || fail "Limine patch copies differ"
limine_checksum=$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${sha256sums[1]}"' _ "$limine_package/PKGBUILD")
[[ $limine_checksum == "$(sha256sum "$limine_patch" | awk '{print $1}')" ]] || fail "Limine patch checksum is stale"
grep -Fq 'KERNEL_IMAGE=/boot/Image' "$limine_patch" || fail "Limine does not use the ALARM kernel image"
grep -Fq 'aarch64:linux-aarch64 | arm64:linux-aarch64' "$limine_patch" || fail "Limine does not normalize ARM kernel names"
grep -Fq 'isSystemEfiArchitecture()' "$limine_patch" || fail "Limine rejects AArch64 UKIs"

grep -Fq 'OMARCHY_REPOSITORY_SERVER' "$ROOT/build/build.sh" || fail "builder cannot use the rolling Release"
grep -Fq -- '--force-explicit' "$ROOT/bin/release-aarch64" || fail "local AArch64 release helper still filters non-fast packages"
grep -Fq 'repo-add omarchy-build.db.tar.zst "${built_filenames[@]}"' "$ROOT/build/build.sh" || fail "split outputs are not indexed"
grep -Fq -- '--database-only' "$ROOT/bin/download-aarch64-baseline" || fail "baseline downloader lacks database-only mode"
[[ $(grep -Fc './bin/download-aarch64-baseline --database-only' "$ROOT/.github/workflows/release-aarch64.yml") -eq 2 ]] ||
  fail "build and publish jobs do not seed only the database"
grep -Fq './bin/publish-github-release' "$ROOT/.github/workflows/release-aarch64.yml" || fail "workflow lacks incremental publisher"
grep -Fq 'aarch64-changed-packages' "$ROOT/.github/workflows/release-aarch64.yml" || fail "workflow transfers more than changed packages"
grep -Fq 'release_tag=${release_tag:-aarch64-stable}' "$ROOT/bin/publish-github-release" || fail "publisher lacks a permanent tag"
grep -Fq 'gh release delete-asset' "$ROOT/bin/publish-github-release" || fail "publisher does not prune stale assets"
grep -Fq 'gh release delete "$old_tag"' "$ROOT/bin/publish-github-release" || fail "publisher does not prune old Releases"
grep -Fq 'gh api --paginate --slurp' "$ROOT/bin/publish-github-release" || fail "publisher does not paginate Release assets"
grep -Fq 'schema: 2' "$ROOT/bin/prepare-github-release" || fail "manifest does not list the complete database"
grep -Fq 'baseline_line_for' "$ROOT/bin/prepare-github-release" || fail "unchanged remote hashes are not reused"
grep -Fq 'REMOTE_REPOSITORY_SERVER' "$ROOT/build/validate-repository.sh" || fail "validator cannot resolve remote packages"
grep -Fq 'Count the complete database' "$ROOT/build/update-repo.sh" || fail "incremental count is not database-wide"
grep -Fq '"$BUILD_ROOT/bin/publish-github-release"' "$ROOT/bin/check-official-stable" || fail "publisher changes do not trigger a release"
grep -Fq '"$BUILD_ROOT/bin/repo"' "$ROOT/bin/check-official-stable" || fail "repository entrypoint changes do not trigger a release"

grep -Fq 'local_packages=' "$ROOT/bin/sync-aarch64-sources" || fail "source sync does not distinguish local packages"
grep -Fq 'sync-arch-packages' "$ROOT/bin/sync-aarch64-sources" || fail "Arch source sync is not wired"
for package_name in ghostty libretro-blastem libretro-desmume libretro-kronos libretro-ppsspp; do
  jq -e '.source == "local" and .arch_package == true and (.upstream_commit | length == 40)' \
    "$ROOT/pkgbuilds/$package_name/.omarchy/package.json" >/dev/null || fail "$package_name does not track Arch packaging"
done

while IFS= read -r script; do
  bash -n "$script" || fail "invalid shell syntax: ${script#$ROOT/}"
done < <(
  find "$ROOT/bin" "$ROOT/build" "$ROOT/helpers" -maxdepth 2 -type f \( -name '*.sh' -o -perm -0100 \) -print
  while IFS= read -r package_name; do
    find "$ROOT/pkgbuilds/$package_name" -type f \( -name '*.sh' -o -name '*.install' \) -print
  done < <(read_scope "$SCOPE")
)

echo "PASS: 89-package-base/119-output AArch64 scope, 46 explicit exclusions, upstream pkgrel policy, ARM recipes, and rolling Release are internally consistent"
