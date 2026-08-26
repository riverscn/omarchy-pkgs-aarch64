#!/bin/bash

# Shared helpers for the downstream AArch64 channel. The caller must set
# BUILD_ROOT before sourcing this file.

OFFICIAL_STABLE_DB_URL=${OMARCHY_OFFICIAL_STABLE_DB_URL:-https://pkgs.omarchy.org/stable/x86_64/omarchy.db.tar.zst}

stable_read_list() {
  sed -E '/^[[:space:]]*(#|$)/d' "$1"
}

stable_list_contains() {
  local list_file="$1"
  local package="$2"
  grep -Fxq "$package" < <(stable_read_list "$list_file")
}

stable_local_version() {
  local package_dir="$1"
  local srcinfo epoch pkgver pkgrel

  srcinfo=$(cd "$package_dir" && env -u OMARCHY_SRC makepkg --printsrcinfo)
  epoch=$(awk -F' = ' '/^[[:space:]]+epoch = / { print $2; exit }' <<<"$srcinfo")
  pkgver=$(awk -F' = ' '/^[[:space:]]+pkgver = / { print $2; exit }' <<<"$srcinfo")
  pkgrel=$(awk -F' = ' '/^[[:space:]]+pkgrel = / { print $2; exit }' <<<"$srcinfo")

  [[ -n $pkgver && -n $pkgrel ]] || return 1
  printf '%s%s-%s\n' "${epoch:+$epoch:}" "$pkgver" "$pkgrel"
}

stable_version_pkgver() {
  local version="${1#*:}"
  printf '%s\n' "${version%-*}"
}

stable_version_pkgrel() {
  printf '%s\n' "${1##*-}"
}

declare -Ag OFFICIAL_STABLE_VERSION=()

stable_load_official_db() {
  local destination="$1"
  local source=${OMARCHY_OFFICIAL_STABLE_DB_FILE:-}

  if [[ -n $source ]]; then
    cp "$source" "$destination"
  else
    curl -fsSL --retry 3 --max-time 120 -o "$destination" "$OFFICIAL_STABLE_DB_URL"
  fi

  local name version filename
  while IFS=$'\t' read -r name version filename; do
    [[ -n $name && -n $version && -n $filename ]] || continue
    OFFICIAL_STABLE_VERSION["$name"]=$version
  done < <(
    bsdtar -xOf "$destination" '*/desc' | awk '
      function emit() {
        if (name != "" && version != "" && filename != "")
          print name "\t" version "\t" filename
        name=""; version=""; filename=""
      }
      $0 == "%FILENAME%" { emit(); getline; filename=$0; next }
      $0 == "%NAME%" { getline; name=$0; next }
      $0 == "%VERSION%" { getline; version=$0; next }
      END { emit() }
    '
  )

  [[ ${#OFFICIAL_STABLE_VERSION[@]} -gt 0 ]]
}
