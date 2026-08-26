#!/bin/bash

set -euo pipefail

repository=${REPOSITORY_DIR:-/repository}
scope=${PACKAGE_SCOPE:-/config/aarch64-packages}
public_key=${PUBLIC_KEY:-/public/omarchy-aarch64.gpg}

# Keep archive inspection inside the Arch build image. GitHub's Ubuntu host
# does not provide bsdtar by default, while the image already does.
database_filenames=$(bsdtar -xOf "$repository/omarchy.db.tar.zst" '*/desc' |
  awk '$0 == "%FILENAME%" { getline; print }')
[[ -n $database_filenames ]] || {
  echo "ERROR: repository database contains no package filenames" >&2
  exit 1
}
while IFS= read -r filename; do
  [[ -f $repository/$filename ]] || {
    echo "ERROR: database references missing asset: $filename" >&2
    exit 1
  }
  [[ -f $repository/$filename.sig ]] || {
    echo "ERROR: database package lacks signature: $filename" >&2
    exit 1
  }
done <<< "$database_filenames"

pacman-key --add "$public_key"

cat >> /etc/pacman.conf <<EOF

[omarchy]
SigLevel = Required TrustAll
Server = file://$repository
EOF

pacman -Syy --noconfirm

mapfile -t packages < <(sed -E '/^[[:space:]]*(#|$)/d' "$scope")
for package in "${packages[@]}"; do
  pacman -Si "$package" >/dev/null || {
    echo "ERROR: pacman cannot resolve scoped package: $package" >&2
    exit 1
  }
done

# Resolve the complete transaction without installing it. This catches missing
# dependencies while keeping validation fast and side-effect free.
pacman -Sp --noconfirm "${packages[@]}" >/dev/null
