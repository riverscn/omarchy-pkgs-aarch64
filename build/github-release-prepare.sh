#!/bin/bash

# Assemble a complete signed repository database from a previous database plus
# the packages changed in this run. This script runs inside the regular native
# AArch64 builder image; it is storage-backend code, not a second builder.

set -euo pipefail

repository=${REPOSITORY_DIR:-/repository}
scope=${PACKAGE_SCOPE:-/config/aarch64-packages}
fork_scope=${FORK_PACKAGE_SCOPE:-/config/aarch64-fork-packages}
pkgbuilds=${PKGBUILDS_DIR:-/pkgbuilds}
public_key=${PUBLIC_KEY:-/public/omarchy-aarch64.gpg}
baseline_sums=${BASELINE_SUMS:-$repository/.baseline-SHA256SUMS}
remote_server=${REMOTE_REPOSITORY_SERVER:-}
commit=${GITHUB_SHA:-unknown}
validation_mode=${VALIDATION_MODE:-incremental}
channel=${REPOSITORY_CHANNEL:-edge}
full_rebuild_marker=$repository/.full-rebuild-validation

: "${GPG_PRIVATE_KEY:?GPG_PRIVATE_KEY is required}"
: "${GPG_PASSPHRASE:?GPG_PASSPHRASE is required}"
: "${EXPECTED_SIGNING_FINGERPRINT:?EXPECTED_SIGNING_FINGERPRINT is required}"
[[ $EXPECTED_SIGNING_FINGERPRINT =~ ^[0-9A-F]{40}$ ]] || {
  echo "ERROR: invalid expected signing fingerprint" >&2
  exit 1
}
case "$channel" in
  edge|rc|stable) ;;
  *) echo "ERROR: invalid repository channel: $channel" >&2; exit 1 ;;
esac
[[ -d $repository && -f $scope && -f $fork_scope && -f $public_key ]] || {
  echo "ERROR: repository, package scopes, or public key is missing" >&2
  exit 1
}
case "$validation_mode" in
  incremental)
    [[ ! -f $full_rebuild_marker ]] || {
      echo "ERROR: full-rebuild marker present during incremental validation" >&2
      exit 1
    }
    ;;
  full)
    [[ -f $full_rebuild_marker ]] || {
      echo "ERROR: full validation requires the zero-baseline marker" >&2
      exit 1
    }
    [[ -z $remote_server ]] || {
      echo "ERROR: full validation must not configure a remote package fallback" >&2
      exit 1
    }
    [[ ! -f $baseline_sums ]] || {
      echo "ERROR: full validation must not contain baseline checksums" >&2
      exit 1
    }
    ;;
  *)
    echo "ERROR: invalid validation mode: $validation_mode" >&2
    exit 1
    ;;
esac

key_home=$(mktemp -d)
srcinfo_work=$(mktemp -d)
new_sums=$(mktemp)
audit_rows=$(mktemp)
trap 'rm -rf "$key_home" "$srcinfo_work" "$new_sums" "$audit_rows"' EXIT
chmod 700 "$key_home"
chown builder:builder "$srcinfo_work"

export GNUPGHOME=$key_home
gpg --batch --import "$public_key" >/dev/null 2>&1
public_fingerprint=$(gpg --batch --with-colons --list-keys |
  awk -F: '$1 == "fpr" { print $10; exit }')
[[ $public_fingerprint == "$EXPECTED_SIGNING_FINGERPRINT" ]] || {
  echo "ERROR: checked-in public key fingerprint mismatch" >&2
  exit 1
}

printf '%s' "$GPG_PRIVATE_KEY" | gpg --batch --import >/dev/null 2>&1
secret_fingerprint=$(gpg --batch --with-colons --list-secret-keys |
  awk -F: '$1 == "fpr" { print $10; exit }')
[[ $secret_fingerprint == "$EXPECTED_SIGNING_FINGERPRINT" ]] || {
  echo "ERROR: private signing key fingerprint mismatch" >&2
  exit 1
}

mapfile -t package_bases < <(
  sed -E '/^[[:space:]]*(#|$)/d' "$scope" "$fork_scope"
)
(( ${#package_bases[@]} > 0 )) || { echo "ERROR: package scope is empty" >&2; exit 1; }

declare -A expected_names=()
declare -A expected_bases=()
declare -A expected_outputs=()
declare -A expected_base_dirs=()
for package_base in "${package_bases[@]}"; do
  package_dir="$pkgbuilds/$package_base"
  [[ -f $package_dir/PKGBUILD ]] || {
    echo "ERROR: scoped package base has no PKGBUILD: $package_base" >&2
    exit 1
  }
  # shellcheck disable=SC2016 # expanded by the nested bash, not this shell
  srcinfo=$(runuser -u builder -- bash -c '
    cd "$1"
    env CARCH=aarch64 BUILDDIR="$2" PKGDEST="$2" SRCDEST="$2" \
      SRCPKGDEST="$2" LOGDEST="$2" makepkg --printsrcinfo
  ' _ "$package_dir" "$srcinfo_work") || {
      echo "ERROR: cannot evaluate AArch64 metadata for $package_base" >&2
      exit 1
    }
  grep -Eq '^[[:space:]]+arch = (any|aarch64)$' <<< "$srcinfo" || {
    echo "ERROR: scoped package base does not support AArch64: $package_base" >&2
    exit 1
  }
  metadata_base=$(awk -F' = ' '$1 ~ /^[[:space:]]*pkgbase$/ { print $2; exit }' <<< "$srcinfo")
  [[ -n $metadata_base ]] || {
    echo "ERROR: scoped package metadata has no pkgbase: $package_base" >&2
    exit 1
  }
  [[ -z ${expected_base_dirs[$metadata_base]:-} ]] || {
    echo "ERROR: duplicate scoped package base: $metadata_base" >&2
    exit 1
  }
  expected_bases["$metadata_base"]=1
  expected_base_dirs["$metadata_base"]=$package_dir
  while IFS= read -r package_name; do
    if [[ -n $package_name ]]; then
      expected_names["$package_name"]=1
      expected_outputs["$metadata_base:$package_name"]=1
    fi
  done < <(awk -F' = ' '$1 ~ /^[[:space:]]*pkgname$/ { print $2 }' <<< "$srcinfo")
done
(( ${#expected_names[@]} > 0 )) || { echo "ERROR: scope has no package outputs" >&2; exit 1; }

cd "$repository"
database=omarchy.db.tar.zst
database_exists=false
stale_names=()
if [[ -f $database ]]; then
  database_exists=true
  mapfile -t old_names < <(
    bsdtar -xOf "$database" '*/desc' |
      awk '$0 == "%NAME%" { getline; print }' | sort -u
  )
  for package_name in "${old_names[@]}"; do
    [[ -n ${expected_names[$package_name]:-} ]] || stale_names+=("$package_name")
  done
fi

shopt -s nullglob
changed_packages=("$repository"/*.pkg.tar.zst)
shopt -u nullglob
[[ $database_exists == true || ${#changed_packages[@]} -gt 0 ]] || {
  echo "ERROR: cannot assemble a repository without a baseline or changed packages" >&2
  exit 1
}

for package in "${changed_packages[@]}"; do
  [[ -f $package.sig ]] || {
    echo "ERROR: changed package lacks signature: ${package##*/}" >&2
    exit 1
  }
  gpg --batch --verify "$package.sig" "$package" >/dev/null 2>&1 || {
    echo "ERROR: changed package signature is invalid: ${package##*/}" >&2
    exit 1
  }
done

package_info_value() {
  local key=$1 info=$2
  awk -F ' = ' -v key="$key" '$1 == key { print $2; exit }' <<< "$info"
}

audit_package_archive() {
  local package=$1 info package_name package_base package_version package_arch
  local package_hash signature_hash architecture_evidence package_dir
  local generic_allowlist output_allowlist
  local file_count elf_count non_target_elf_count expanded_bytes managed_pe_count
  local reviewed_non_target_elf_count nested_archive_count
  local foreign_executable_count reviewed_foreign_executable_count max_depth_seen
  local -a audit_args=(--arch aarch64 --reject-foreign --json)

  info=$(bsdtar -xOf "$package" .PKGINFO) || {
    echo "ERROR: package archive lacks readable .PKGINFO: ${package##*/}" >&2
    return 1
  }
  package_name=$(package_info_value pkgname "$info")
  package_base=$(package_info_value pkgbase "$info")
  package_version=$(package_info_value pkgver "$info")
  package_arch=$(package_info_value arch "$info")
  [[ -n $package_name && -n $package_base && -n $package_version ]] || {
    echo "ERROR: incomplete .PKGINFO in ${package##*/}" >&2
    return 1
  }
  [[ -n ${expected_names[$package_name]:-} ]] || {
    echo "ERROR: built archive has an out-of-scope package name: $package_name" >&2
    return 1
  }
  [[ -n ${expected_bases[$package_base]:-} ]] || {
    echo "ERROR: built archive has an out-of-scope package base: $package_base" >&2
    return 1
  }
  [[ -n ${expected_outputs["$package_base:$package_name"]:-} ]] || {
    echo "ERROR: built archive has an invalid package base/name pair: $package_base/$package_name" >&2
    return 1
  }
  [[ $package_arch == aarch64 || $package_arch == any ]] || {
    echo "ERROR: built archive has invalid target architecture $package_arch: ${package##*/}" >&2
    return 1
  }
  if bsdtar -tf "$package" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    echo "ERROR: unsafe path in package archive: ${package##*/}" >&2
    return 1
  fi

  package_dir=${expected_base_dirs[$package_base]}
  generic_allowlist=$package_dir/.omarchy/aarch64-audit-allowlist
  output_allowlist=$generic_allowlist.$package_name
  if [[ -f $generic_allowlist && -f $output_allowlist ]]; then
    echo "ERROR: ambiguous architecture audit allowlists for $package_base/$package_name" >&2
    return 1
  elif [[ -f $output_allowlist ]]; then
    audit_args+=(--allowlist "$output_allowlist")
  elif [[ -f $generic_allowlist ]]; then
    audit_args+=(--allowlist "$generic_allowlist")
  fi

  architecture_evidence=$(
    /build/audit-package-architecture.sh "${audit_args[@]}" "$package"
  ) || {
    echo "ERROR: recursive architecture audit failed: ${package##*/}" >&2
    return 1
  }
  jq -e '.target_architecture == "aarch64" and .errors == 0' \
    <<< "$architecture_evidence" >/dev/null || {
    echo "ERROR: invalid architecture evidence: ${package##*/}" >&2
    return 1
  }
  file_count=$(jq -r '.file_count' <<< "$architecture_evidence")
  expanded_bytes=$(jq -r '.expanded_bytes' <<< "$architecture_evidence")
  elf_count=$(jq -r '.elf_count' <<< "$architecture_evidence")
  non_target_elf_count=$(jq -r '.non_target_elf_count' <<< "$architecture_evidence")
  reviewed_non_target_elf_count=$(jq -r '.reviewed_non_target_elf_count' <<< "$architecture_evidence")
  managed_pe_count=$(jq -r '.managed_pe_count' <<< "$architecture_evidence")
  nested_archive_count=$(jq -r '.nested_archive_count' <<< "$architecture_evidence")
  foreign_executable_count=$(jq -r '.foreign_executable_count' <<< "$architecture_evidence")
  reviewed_foreign_executable_count=$(jq -r '.reviewed_foreign_executable_count' <<< "$architecture_evidence")
  max_depth_seen=$(jq -r '.max_depth_seen' <<< "$architecture_evidence")

  package_hash=$(sha256sum "$package" | awk '{ print $1 }') || return 1
  signature_hash=$(sha256sum "$package.sig" | awk '{ print $1 }') || return 1
  jq -c -n \
    --arg filename "${package##*/}" \
    --arg package_name "$package_name" \
    --arg package_base "$package_base" \
    --arg version "$package_version" \
    --arg package_architecture "$package_arch" \
    --arg sha256 "$package_hash" \
    --arg signature_sha256 "$signature_hash" \
    --argjson file_count "$file_count" \
    --argjson expanded_bytes "$expanded_bytes" \
    --argjson elf_count "$elf_count" \
    --argjson non_target_elf_count "$non_target_elf_count" \
    --argjson reviewed_non_target_elf_count "$reviewed_non_target_elf_count" \
    --argjson managed_pe_count "$managed_pe_count" \
    --argjson nested_archive_count "$nested_archive_count" \
    --argjson foreign_executable_count "$foreign_executable_count" \
    --argjson reviewed_foreign_executable_count "$reviewed_foreign_executable_count" \
    --argjson max_depth_seen "$max_depth_seen" \
    '{filename: $filename, package_name: $package_name,
      package_base: $package_base, version: $version,
      package_architecture: $package_architecture, sha256: $sha256,
      signature_sha256: $signature_sha256, file_count: $file_count,
      expanded_bytes: $expanded_bytes, elf_count: $elf_count,
      non_target_elf_count: $non_target_elf_count,
      reviewed_non_target_elf_count: $reviewed_non_target_elf_count,
      managed_pe_count: $managed_pe_count,
      nested_archive_count: $nested_archive_count,
      foreign_executable_count: $foreign_executable_count,
      reviewed_foreign_executable_count: $reviewed_foreign_executable_count,
      max_depth_seen: $max_depth_seen}' >> "$audit_rows" || return 1
}

audit_failures=0
for package in "${changed_packages[@]}"; do
  if ! audit_package_archive "$package"; then
    ((audit_failures += 1))
  fi
done
(( audit_failures == 0 )) || {
  echo "ERROR: repository archive audit failed for $audit_failures package(s)" >&2
  exit 1
}

modified=false
if (( ${#stale_names[@]} > 0 || ${#changed_packages[@]} > 0 )); then
  modified=true
  # Signatures and aliases describe the previous database and must not survive
  # a mutation. The canonical compressed databases are retained for repo-add.
  rm -f omarchy.db omarchy.db.sig omarchy.db.tar.zst.sig
  rm -f omarchy.files omarchy.files.sig omarchy.files.tar.zst.sig
fi
if (( ${#stale_names[@]} > 0 )); then
  printf 'Removing package outside the configured scope: %s\n' "${stale_names[@]}"
  repo-remove "$database" "${stale_names[@]}"
fi
if (( ${#changed_packages[@]} > 0 )); then
  repo-add "$database" "${changed_packages[@]}"
fi

mapfile -t database_names < <(
  bsdtar -xOf "$database" '*/desc' |
    awk '$0 == "%NAME%" { getline; print }' | sort -u
)
mapfile -t database_filenames < <(
  bsdtar -xOf "$database" '*/desc' |
    awk '$0 == "%FILENAME%" { getline; print }' | sort -u
)

for package in "${changed_packages[@]}"; do
  printf '%s\n' "${database_filenames[@]}" | grep -Fxq "${package##*/}" || {
    echo "ERROR: built archive is not referenced by the repository database: ${package##*/}" >&2
    exit 1
  }
done

if [[ $validation_mode == full ]]; then
  (( ${#changed_packages[@]} == ${#database_filenames[@]} )) || {
    echo "ERROR: full validation did not rebuild every repository archive" >&2
    exit 1
  }
  for filename in "${database_filenames[@]}"; do
    [[ -f $repository/$filename && -f $repository/$filename.sig ]] || {
      echo "ERROR: full validation attempted to use a non-local archive: $filename" >&2
      exit 1
    }
  done
fi

for package_name in "${!expected_names[@]}"; do
  printf '%s\n' "${database_names[@]}" | grep -Fxq "$package_name" || {
    echo "ERROR: repository database is missing scoped output: $package_name" >&2
    exit 1
  }
done
for package_name in "${database_names[@]}"; do
  [[ -n ${expected_names[$package_name]:-} ]] || {
    echo "ERROR: repository database contains an out-of-scope package: $package_name" >&2
    exit 1
  }
done

baseline_line_for() {
  local wanted=$1
  [[ -f $baseline_sums ]] || return 1
  awk -v wanted="$wanted" '
    { name=$2; sub(/^\*/, "", name) }
    name == wanted && $1 ~ /^[0-9a-f]{64}$/ { print; found=1; exit }
    END { exit !found }
  ' "$baseline_sums"
}

for filename in "${database_filenames[@]}"; do
  if [[ -f $repository/$filename ]]; then
    [[ -f $repository/$filename.sig ]] || {
      echo "ERROR: local package lacks signature: $filename" >&2
      exit 1
    }
  else
    baseline_line_for "$filename" >/dev/null || {
      echo "ERROR: baseline checksum is missing for remote package: $filename" >&2
      exit 1
    }
    baseline_line_for "$filename.sig" >/dev/null || {
      echo "ERROR: baseline checksum is missing for remote signature: $filename.sig" >&2
      exit 1
    }
  fi
done

if [[ $modified == true ]]; then
  for path in omarchy.db.tar.zst omarchy.files.tar.zst; do
    [[ -f $path ]] || { echo "ERROR: repo-add did not create $path" >&2; exit 1; }
    gpg --batch --yes --pinentry-mode loopback \
      --passphrase "$GPG_PASSPHRASE" \
      --local-user "$EXPECTED_SIGNING_FINGERPRINT" \
      --detach-sign "$path"
  done

  # GitHub Release assets cannot preserve symlinks. Publish byte-identical
  # aliases and reuse canonical signatures for the identical bytes.
  cp --remove-destination omarchy.db.tar.zst omarchy.db
  cp --remove-destination omarchy.db.tar.zst.sig omarchy.db.sig
  cp --remove-destination omarchy.files.tar.zst omarchy.files
  cp --remove-destination omarchy.files.tar.zst.sig omarchy.files.sig
  cp --remove-destination "$public_key" omarchy-aarch64.gpg
fi

for database_asset in omarchy.db omarchy.db.tar.zst omarchy.files omarchy.files.tar.zst; do
  gpg --batch --verify "$database_asset.sig" "$database_asset" >/dev/null 2>&1 || {
    echo "ERROR: invalid repository signature: $database_asset" >&2
    exit 1
  }
done

# Validate a complete dependency transaction for every scoped output. Some
# package bases intentionally publish mutually exclusive variants (for example,
# Ollama's CUDA and JetPack backends), so requiring every output in one
# transaction would reject a valid repository. The local directory contains
# changed archives; unchanged archives are fetched from the managed Release.
pacman-key --add "$public_key" >/dev/null
cat >> /etc/pacman.conf <<EOF

[omarchy]
SigLevel = Required TrustAll
Server = file://$repository
EOF
if [[ -n $remote_server ]]; then
  [[ $remote_server != *$'\n'* ]] || { echo "ERROR: invalid remote server" >&2; exit 1; }
  echo "Server = $remote_server" >> /etc/pacman.conf
fi
pacman -Syy --noconfirm >/dev/null
mapfile -t expected_sorted < <(printf '%s\n' "${!expected_names[@]}" | sort)
for package_name in "${expected_sorted[@]}"; do
  pacman -Sp --noconfirm "$package_name" >/dev/null || {
    echo "ERROR: cannot resolve repository transaction for $package_name" >&2
    exit 1
  }
done

if [[ $modified == false ]]; then
  touch .no-changes
  echo "No package or scope changes; the signed rolling repository remains current."
  exit 0
fi

jq -S -n \
  --arg architecture aarch64 \
  --arg channel "$channel" \
  --arg commit "$commit" \
  --arg validation_mode "$validation_mode" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg signing_fingerprint "$EXPECTED_SIGNING_FINGERPRINT" \
  --argjson package_base_count "${#package_bases[@]}" \
  --args \
  '{schema: 1, architecture: $architecture, channel: $channel,
    commit: $commit, generated_at: $generated_at,
    signing_fingerprint: $signing_fingerprint,
    validation_mode: $validation_mode,
    package_base_count: $package_base_count, packages: $ARGS.positional}' \
  "${database_filenames[@]}" > repository-manifest.json

jq -S -s \
  --arg architecture aarch64 \
  --arg channel "$channel" \
  --arg validation_mode "$validation_mode" \
  --arg commit "$commit" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson package_base_count "${#package_bases[@]}" \
  '{schema: 1, architecture: $architecture, channel: $channel,
    validation_mode: $validation_mode, commit: $commit,
    generated_at: $generated_at, package_base_count: $package_base_count,
    archive_count: length, packages: .}' \
  "$audit_rows" > repository-build-audit.json

for filename in "${database_filenames[@]}"; do
  for asset in "$filename" "$filename.sig"; do
    if [[ -f $repository/$asset ]]; then
      sha256sum -- "$asset" >> "$new_sums"
    else
      baseline_line_for "$asset" >> "$new_sums"
    fi
  done
done
sha256sum -- \
  omarchy.db omarchy.db.sig omarchy.db.tar.zst omarchy.db.tar.zst.sig \
  omarchy.files omarchy.files.sig omarchy.files.tar.zst omarchy.files.tar.zst.sig \
  omarchy-aarch64.gpg repository-build-audit.json repository-manifest.json >> "$new_sums"
sort -k2 -u "$new_sums" > SHA256SUMS

echo "Prepared and validated ${#database_filenames[@]} package assets from ${#package_bases[@]} package bases."
