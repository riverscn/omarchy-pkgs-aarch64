#!/bin/bash
# Repository database update script (runs inside Docker container)

set -e

ARCH=${ARCH:-x86_64}
MIRROR=${MIRROR:-edge}
OUTPUT_DIR="/output/$MIRROR/$ARCH"
REPO_NAME="omarchy"
DB_FILE="$OUTPUT_DIR/${REPO_NAME}.db.tar.zst"
INCREMENTAL=false

if [[ $ARCH == aarch64 && $MIRROR == stable && -f $DB_FILE ]]; then
  INCREMENTAL=true
fi

cd "$OUTPUT_DIR"

# The rolling AArch64 Release keeps unchanged package assets in GitHub. Its CI
# downloads only the previous signed database, then updates that database with
# locally built packages. Other channels retain the inherited full rebuild.
if [[ $INCREMENTAL == true ]]; then
  rm -f "${REPO_NAME}.db" "${REPO_NAME}.files"
  rm -f "${REPO_NAME}.db.sig" "${REPO_NAME}.db.tar.zst.sig"
  rm -f "${REPO_NAME}.files.sig" "${REPO_NAME}.files.tar.zst.sig"
else
  rm -f "${REPO_NAME}.db" "${REPO_NAME}.db.tar.zst"
  rm -f "${REPO_NAME}.files" "${REPO_NAME}.files.tar.zst"
fi

# Check if there are any packages
if [[ $INCREMENTAL == false ]] && ! ls *.pkg.tar.* 1>/dev/null 2>&1; then
  echo "==> No packages found in $OUTPUT_DIR"
  echo "==> Run bin/repo build first to build packages"
  exit 1
fi

# Add all packages to the database (only latest version of each)
echo "==> Adding packages to database..."

# Build list of latest packages using vercmp for proper version sorting
declare -A latest_pkgs
declare -A latest_vers

# Helper to extract pkgname and version from filename
# Uses bsdtar to read .PKGINFO for accurate info
get_pkg_info() {
  local pkg="$1"
  bsdtar -xOqf "$pkg" .PKGINFO 2>/dev/null | awk '
    /^pkgname = / { name = substr($0, 11) }
    /^pkgver = / { ver = substr($0, 10) }
    END { print name " " ver }
  '
}

for pkg in *.pkg.tar.*; do
  [[ "$pkg" == *.sig ]] && continue
  [[ ! -f "$pkg" ]] && continue
  
  read -r name ver <<< "$(get_pkg_info "$pkg")"
  [[ -z "$name" ]] && continue
  
  if [[ -z "${latest_pkgs[$name]}" ]]; then
    latest_pkgs[$name]="$pkg"
    latest_vers[$name]="$ver"
  else
    if [[ $(vercmp "$ver" "${latest_vers[$name]}") -gt 0 ]]; then
      latest_pkgs[$name]="$pkg"
      latest_vers[$name]="$ver"
    fi
  fi
done

if [[ $INCREMENTAL == true ]]; then
  scope=/config/aarch64-packages
  [[ -f $scope ]] || { echo "==> Missing AArch64 package scope: $scope" >&2; exit 1; }

  declare -A expected_names=()
  while IFS= read -r package_base; do
    [[ -n $package_base ]] || continue
    pkgbuild="/pkgbuilds/$package_base/PKGBUILD"
    [[ -f $pkgbuild ]] || { echo "==> Missing PKGBUILD for $package_base" >&2; exit 1; }
    while IFS= read -r package_name; do
      [[ -n $package_name ]] && expected_names["$package_name"]=1
    done < <(bash -c 'source "$1" >/dev/null 2>&1; printf "%s\n" "${pkgname[@]}"' _ "$pkgbuild")
  done < <(sed -E '/^[[:space:]]*(#|$)/d' "$scope")

  mapfile -t database_names < <(
    bsdtar -xOf "$DB_FILE" '*/desc' | awk '$0 == "%NAME%" { getline; print }' | sort -u
  )
  stale_names=()
  for package_name in "${database_names[@]}"; do
    [[ -n ${expected_names[$package_name]:-} ]] || stale_names+=("$package_name")
  done
  if (( ${#stale_names[@]} > 0 )); then
    echo "==> Removing packages outside the maintained AArch64 scope..."
    printf '  Removing: %s\n' "${stale_names[@]}"
    repo-remove "$DB_FILE" "${stale_names[@]}"
  fi
fi

# Add latest packages to repo
for pkg in "${latest_pkgs[@]}"; do
  echo "  Adding: $pkg"
done | sort

if (( ${#latest_pkgs[@]} > 0 )); then
  repo-add "$DB_FILE" "${latest_pkgs[@]}" || {
    echo "==> Failed to update repository database"
    exit 1
  }
elif [[ $INCREMENTAL == false ]]; then
  echo "==> No packages were available to create the repository database" >&2
  exit 1
else
  echo "==> No changed package archives; keeping the updated baseline database."
fi

# A full AArch64 repository assembly keeps only database-reachable archives.
# Incremental assemblies contain only the changed archives, so remote cleanup
# is deferred until after the new database has been published.
if [[ $ARCH == aarch64 && $MIRROR == stable && $INCREMENTAL == false ]]; then
  for pkg in *.pkg.tar.*; do
    [[ "$pkg" == *.sig ]] && continue
    [[ ! -f "$pkg" ]] && continue
    keep=false
    for latest in "${latest_pkgs[@]}"; do
      if [[ "$pkg" == "$latest" ]]; then
        keep=true
        break
      fi
    done
    if [[ $keep == false ]]; then
      echo "  Removing superseded archive: $pkg"
      rm -f -- "$pkg" "$pkg.sig"
    fi
  done
fi

# Create symlinks for compatibility
ln -sf "${REPO_NAME}.db.tar.zst" "${REPO_NAME}.db"
ln -sf "${REPO_NAME}.files.tar.zst" "${REPO_NAME}.files"

# Count the complete database, not only the archives changed in this run.
PACKAGE_COUNT=$(bsdtar -xOf "$DB_FILE" '*/desc' |
  awk '$0 == "%NAME%" { getline; count++ } END { print count + 0 }')

echo "==> Database updated successfully!"
echo "==> Total packages in repository: $PACKAGE_COUNT"

# List packages in database
echo "==> Packages in database:"
tar -tf "$DB_FILE" 2>/dev/null | grep -E "^[^/]+/$" | sed 's|/$||' | sort -u | while read -r pkg; do
  echo "  - $pkg"
done
