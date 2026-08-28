#!/bin/bash

set -euo pipefail

repository=${REPOSITORY_DIR:-/repository}
scope=${PACKAGE_SCOPE:-/config/aarch64-packages}
pkgbuilds=${PKGBUILDS_DIR:-/pkgbuilds}
public_key=${PUBLIC_KEY:-/public/omarchy-aarch64.gpg}
baseline_sums=${BASELINE_SUMS:-/repository/.baseline-SHA256SUMS}
remote_server=${REMOTE_REPOSITORY_SERVER:-}
release_state=${RELEASE_STATE:-$repository/repository-version-set.json}

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
declare -A failed_packages=()
if [[ -f $release_state ]]; then
  while IFS= read -r package; do
    [[ -n $package ]] && failed_packages["$package"]=1
  done < <(jq -r '.failed_packages[]?' "$release_state")
fi

available_packages=()
srcinfo_work=/tmp/makepkg-srcinfo
install -d -o builder -g builder "$srcinfo_work"
for package_base in "${packages[@]}"; do
  if [[ -n ${failed_packages[$package_base]:-} ]]; then
    echo "WARNING: newly pending package base is not yet published: $package_base" >&2
    continue
  fi

  package_dir="$pkgbuilds/$package_base"
  [[ -f $package_dir/PKGBUILD ]] || {
    echo "ERROR: scoped package base has no PKGBUILD: $package_base" >&2
    exit 1
  }
  if ! srcinfo=$(runuser -u builder -- bash -c \
    'cd "$1" && env CARCH=aarch64 BUILDDIR="$2" PKGDEST="$2" SRCDEST="$2" SRCPKGDEST="$2" LOGDEST="$2" makepkg --printsrcinfo' \
    _ "$package_dir" "$srcinfo_work"); then
    echo "ERROR: cannot enumerate outputs for scoped package base: $package_base" >&2
    exit 1
  fi
  mapfile -t outputs < <(
    awk -F' = ' '$1 ~ /^[[:space:]]*pkgname$/ { print $2 }' <<< "$srcinfo"
  )
  (( ${#outputs[@]} > 0 )) || {
    echo "ERROR: scoped package base has no package outputs: $package_base" >&2
    exit 1
  }

  for package in "${outputs[@]}"; do
    if pacman -Si "$package" >/dev/null; then
      available_packages+=("$package")
    else
      echo "ERROR: pacman cannot resolve output $package from scoped package base $package_base" >&2
      exit 1
    fi
  done
done

# Resolve the complete transaction without installing it. This catches missing
# dependencies while keeping validation fast and side-effect free.
(( ${#available_packages[@]} > 0 )) || {
  echo "ERROR: repository contains no resolvable scoped packages" >&2
  exit 1
}
transaction_output=$(mktemp)
if ! pacman -Sp --noconfirm "${available_packages[@]}" >"$transaction_output" 2>&1; then
  cat "$transaction_output" >&2
  echo "ERROR: cannot resolve the complete scoped package transaction" >&2
  exit 1
fi
rm -f "$transaction_output"
