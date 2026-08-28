#!/bin/bash

set -euo pipefail

repository=${REPOSITORY_DIR:-/repository}
scope=${PACKAGE_SCOPE:-/config/aarch64-packages}
public_key=${PUBLIC_KEY:-/public/omarchy-aarch64.gpg}
baseline_sums=${BASELINE_SUMS:-/repository/.baseline-SHA256SUMS}
remote_server=${REMOTE_REPOSITORY_SERVER:-}

baseline_has_asset() {
  local wanted="$1"
  awk -v wanted="$wanted" '
    { name=$2; sub(/^\*/, "", name) }
    name == wanted && $1 ~ /^[0-9a-f]{64}$/ { found=1; exit }
    END { exit !found }
  ' "$baseline_sums"
}

# Keep archive inspection inside the Arch build image. GitHub's Ubuntu host
# does not provide bsdtar by default, while the image already does.
database_filenames=$(bsdtar -xOf "$repository/omarchy.db.tar.zst" '*/desc' |
  awk '$0 == "%FILENAME%" { getline; print }')
[[ -n $database_filenames ]] || {
  echo "ERROR: repository database contains no package filenames" >&2
  exit 1
}
while IFS= read -r filename; do
  if [[ -f $repository/$filename ]]; then
    [[ -f $repository/$filename.sig ]] || {
      echo "ERROR: changed package lacks signature: $filename" >&2
      exit 1
    }
  else
    [[ -f $baseline_sums ]] || {
      echo "ERROR: database references a remote package without baseline checksums: $filename" >&2
      exit 1
    }
    baseline_has_asset "$filename" || {
      echo "ERROR: baseline checksum is missing for remote package: $filename" >&2
      exit 1
    }
    baseline_has_asset "$filename.sig" || {
      echo "ERROR: baseline checksum is missing for remote signature: $filename.sig" >&2
      exit 1
    }
  fi
done <<< "$database_filenames"

pacman-key --add "$public_key"

cat >> /etc/pacman.conf <<EOF

[omarchy]
SigLevel = Required TrustAll
Server = file://$repository
EOF

if [[ -n $remote_server ]]; then
  sed -i "/^Server = file:\/\/$repository$/a Server = $remote_server" /etc/pacman.conf
fi

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
