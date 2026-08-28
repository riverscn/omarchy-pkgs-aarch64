#!/bin/bash
set -euo pipefail

release=$(curl -fsSL https://api.github.com/repos/pingdotgg/t3code/releases/latest)
version=$(jq -r '.tag_name | sub("^v"; "")' <<< "$release")
published_at=$(jq -r '.published_at' <<< "$release")
current=$(sed -n 's/^pkgver=//p' PKGBUILD)

if [[ -z $version || $version == null || $(vercmp "$version" "$current") -le 0 ]]; then
  echo '{}'
  exit 0
fi

sha256=$(curl -fsSL --retry 3 \
  "https://github.com/pingdotgg/t3code/archive/refs/tags/v${version}.tar.gz" |
  sha256sum | awk '{ print $1 }')

jq -n --arg pkgver "$version" --arg published_at "$published_at" --arg sha256 "$sha256" \
  '{pkgver: $pkgver, published_at: $published_at, sha256sums: {aarch64: [$sha256]}}'
