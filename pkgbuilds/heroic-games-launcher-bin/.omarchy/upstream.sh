#!/bin/bash

set -euo pipefail

releases=$(curl -fsSL --retry 3 \
  'https://api.github.com/repos/Heroic-Games-Launcher/HeroicGamesLauncher/releases?per_page=100')
release=$(jq -c '
  [
    .[]
    | select(.draft == false and .prerelease == false)
    | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
    | (.tag_name | sub("^v"; "")) as $version
    | select(any(.assets[]?; .name == "Heroic-\($version)-linux-x64.pacman"))
    | {pkgver: $version, tag: .tag_name, published_at: .published_at}
  ]
  | first // empty
' <<<"$releases")

[[ -n $release ]] || {
  echo 'No stable Heroic desktop release was found' >&2
  exit 1
}

candidate=$(jq -r '.pkgver' <<<"$release")
current=$(grep -m1 '^pkgver=' PKGBUILD | cut -d= -f2- | tr -d "\"'")
if [[ $candidate == "$current" ]]; then
  echo '{}'
  exit 0
fi

tag=$(jq -r '.tag' <<<"$release")
helper_manifest=$(curl -fsSL --retry 3 \
  "https://raw.githubusercontent.com/Heroic-Games-Launcher/HeroicGamesLauncher/${tag}/meta/downloadHelperBinaries.ts")

source PKGBUILD
declare -A expected=(
  [legendary]="$_legendary_tag"
  [gogdl]="$_gogdl_tag"
  [nile]="$_nile_tag"
  [comet]="$_comet_tag"
  [epic-integration]="$_epic_integration_tag"
)

for helper in legendary gogdl nile comet epic-integration; do
  actual=$(sed -n -E "s/^[[:space:]]*'?${helper}'?:[[:space:]]*'([^']+)'.*/\\1/p" <<<"$helper_manifest")
  if [[ -z $actual || $actual != "${expected[$helper]}" ]]; then
    echo "Heroic $tag changes the $helper helper tag (${expected[$helper]} -> ${actual:-missing}); audit and update the PKGBUILD manually" >&2
    exit 1
  fi
done

archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
curl -fsSL --retry 3 -o "$archive" \
  "https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/archive/refs/tags/${tag}.tar.gz"
checksum=$(sha256sum "$archive" | awk '{print $1}')

jq -n \
  --arg pkgver "$candidate" \
  --arg published_at "$(jq -r '.published_at' <<<"$release")" \
  --arg checksum "$checksum" \
  '{pkgver: $pkgver, published_at: $published_at, sha256sums: {any: [$checksum]}}'
