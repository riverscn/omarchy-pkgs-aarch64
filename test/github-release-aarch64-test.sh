#!/bin/bash

set -euo pipefail

ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
scope="$ROOT/config/aarch64-packages"
fork_scope="$ROOT/config/aarch64-fork-packages"
workflow="$ROOT/.github/workflows/release-aarch64.yml"
work=$(mktemp -d)
metadata_work="$work/metadata"
trap 'rm -rf "$work"' EXIT
mkdir -p "$metadata_work"

mapfile -t upstream_packages < <(sed -E '/^[[:space:]]*(#|$)/d' "$scope")
mapfile -t fork_packages < <(sed -E '/^[[:space:]]*(#|$)/d' "$fork_scope")
packages=("${upstream_packages[@]}" "${fork_packages[@]}")
[[ ${#upstream_packages[@]} -eq 118 ]] || {
  echo "Expected the reviewed 118-base upstream AArch64 edge scope; found ${#upstream_packages[@]}" >&2
  exit 1
}
[[ ${#packages[@]} -eq 121 ]] || {
  echo "Expected 118 upstream AArch64 bases plus 3 fork additions; found ${#packages[@]}" >&2
  exit 1
}

assert_scope_count() {
  local command=$1 channel=$2 expected=$3 actual
  actual=$("$ROOT/bin/github-release-aarch64" "$command" --channel "$channel" | sed '1d' | wc -l)
  [[ $actual -eq $expected ]] || {
    echo "Expected $expected entries from $command for $channel; found $actual" >&2
    exit 1
  }
}

assert_scope_count scope edge 121
assert_scope_count scope rc 119
assert_scope_count scope stable 119
assert_scope_count build-scope edge 121

# A staged release must retain the review boundary between the upstream-aligned
# scope and the fork-only overlay. A combined 121-entry file produces the same
# repository but loses the evidence that only three package bases are downstream.
adapter_root="$work/adapter-root"
mkdir -p "$adapter_root/bin"
cp "$ROOT/bin/github-release-aarch64" "$adapter_root/bin/"
ln -s "$ROOT/config" "$adapter_root/config"
ln -s "$ROOT/helpers" "$adapter_root/helpers"
ln -s "$ROOT/pkgbuilds" "$adapter_root/pkgbuilds"
"$adapter_root/bin/github-release-aarch64" seed --channel edge --no-baseline >/dev/null
mapfile -t staged_upstream_scope < \
  "$adapter_root/pkgs.omarchy.org/edge/aarch64/.channel-package-scope"
mapfile -t staged_fork_scope < \
  "$adapter_root/pkgs.omarchy.org/edge/aarch64/.channel-fork-scope"
[[ ${#staged_upstream_scope[@]} -eq ${#upstream_packages[@]} ]] || {
  echo "Staged upstream scope lost its 118-base review boundary" >&2
  exit 1
}
[[ ${#staged_fork_scope[@]} -eq ${#fork_packages[@]} ]] || {
  echo "Staged fork scope does not contain exactly the reviewed overlay" >&2
  exit 1
}
diff -u <(printf '%s\n' "${upstream_packages[@]}") \
  <(printf '%s\n' "${staged_upstream_scope[@]}")
diff -u <(printf '%s\n' "${fork_packages[@]}") \
  <(printf '%s\n' "${staged_fork_scope[@]}")

edge_scope_output=$("$ROOT/bin/github-release-aarch64" scope --channel edge)
rc_scope_output=$("$ROOT/bin/github-release-aarch64" scope --channel rc)
stable_scope_output=$("$ROOT/bin/github-release-aarch64" scope --channel stable)
edge_build_output=$("$ROOT/bin/github-release-aarch64" build-scope --channel edge)
rc_build_output=$("$ROOT/bin/github-release-aarch64" build-scope --channel rc)
stable_build_output=$("$ROOT/bin/github-release-aarch64" build-scope --channel stable)
rc_pinned_output=$(OMARCHY_RC_PINS=1 "$ROOT/bin/github-release-aarch64" \
  build-scope --channel rc)

diff -u <(sed '1d' <<< "$edge_scope_output" | sort) \
  <(sed '1d' <<< "$edge_build_output" | sort) || {
  echo "Edge build scope no longer matches the complete edge repository scope" >&2
  exit 1
}
diff -u <(sed '1d' <<< "$stable_build_output" | sort) \
  <(sed '1d' <<< "$rc_build_output" | sort) || {
  echo "RC and stable no longer derive the same fast-ring build scope" >&2
  exit 1
}
diff -u \
  <({ sed '1d' <<< "$stable_build_output"; printf '%s\n' omarchy omarchy-settings; } | sort -u) \
  <(sed '1d' <<< "$rc_pinned_output" | sort -u) || {
  echo "The RC branch build is not exactly the fast ring plus its two pinned packages" >&2
  exit 1
}
for development_package in omarchy-dev omarchy-settings-dev; do
  grep -Fxq "$development_package" <<< "$edge_scope_output"
  if grep -Fxq "$development_package" <<< "$rc_scope_output"; then
    echo "$development_package leaked from edge into rc" >&2
    exit 1
  fi
  if grep -Fxq "$development_package" <<< "$stable_scope_output"; then
    echo "$development_package leaked from edge into stable" >&2
    exit 1
  fi
done

# Both runtime settings packages must preserve upstream's staging boundary for
# configuration files owned by Arch packages. Owning cups-files.conf directly
# makes pacman reject omarchy as soon as current cups is installed in the clean
# builder (and would create the same conflict on user systems).
for settings_package in omarchy-settings omarchy-settings-dev; do
  settings_recipe="$ROOT/pkgbuilds/$settings_package/PKGBUILD"
  sed -n '/^_etc_override_paths=(/,/^)/p' "$settings_recipe" |
    grep -Fxq "  'etc/cups/cups-files.conf'" || {
      echo "$settings_package no longer stages cups-files.conf as an upstream-owned override" >&2
      exit 1
    }
  grep -Fq 'mv "$pkgdir/$path" "$pkgdir/usr/share/omarchy/etc-overrides/cups-cups-files.conf"' \
    "$settings_recipe" || {
      echo "$settings_package no longer removes cups-files.conf from its package-owned /etc tree" >&2
      exit 1
    }
done
if "$ROOT/bin/github-release-aarch64" advance --from stable --to edge \
  >"$work/reverse-advance.out" 2>&1; then
  echo "GitHub adapter allowed a reverse channel advance" >&2
  exit 1
fi
grep -Fq 'releases move edge -> rc -> stable' "$work/reverse-advance.out"
if "$ROOT/bin/github-release-aarch64" seed --channel rc --no-baseline \
  >"$work/rc-full.out" 2>&1; then
  echo "GitHub adapter allowed a zero-baseline RC build" >&2
  exit 1
fi
grep -Fq 'zero-baseline validation applies only to edge' "$work/rc-full.out"
[[ ${#fork_packages[@]} -eq 3 ]] || {
  echo "Expected exactly 3 explicit fork package bases; found ${#fork_packages[@]}" >&2
  exit 1
}
[[ $(printf '%s\n' "${packages[@]}" | sort -u | wc -l) -eq ${#packages[@]} ]] || {
  echo "AArch64 package scope contains duplicates" >&2
  exit 1
}
[[ $(printf '%s\n' "${fork_packages[@]}" | sort -u | wc -l) -eq ${#fork_packages[@]} ]] || {
  echo "AArch64 fork package overlay contains duplicates" >&2
  exit 1
}
for required in omarchy-aarch64-keyring omarchy-aarch64-config omarchy-spice-guest-tools libretro-blastem; do
  printf '%s\n' "${packages[@]}" | grep -Fxq "$required" || {
    echo "AArch64 package scope lost required package base: $required" >&2
    exit 1
  }
done
for package in "${fork_packages[@]}"; do
  if printf '%s\n' "${upstream_packages[@]}" | grep -Fxq "$package"; then
    echo "Fork package leaked into the upstream-aligned scope: $package" >&2
    exit 1
  fi
done
printf '%s\n' "${fork_packages[@]}" | sort -u | diff -u \
  <(printf '%s\n' omarchy-aarch64-keyring omarchy-aarch64-config omarchy-spice-guest-tools | sort -u) - || {
  echo "Fork package overlay contains an unreviewed package base" >&2
  exit 1
}

# The checked-in manifest is an intentionally reviewed snapshot, but it must
# not drift from the package/channel/architecture rules inherited from
# upstream. The rolling adapter builds the same edge range as upstream; its three
# fork packages participate through the same metadata rules as every upstream
# package and are tracked separately above.
expected_scope="$work/expected-edge-scope"
actual_scope="$work/actual-edge-scope"
(
  export PKGBUILDS_DIR="$ROOT/pkgbuilds"
  # shellcheck source=../helpers/package-metadata.sh
  source "$ROOT/helpers/package-metadata.sh"
  package_dirs | while IFS= read -r package_dir; do
    package_builds_for_mirror "$package_dir" edge || continue
    package_build_skipped "$package_dir" && continue
    package_arches=$(CARCH=aarch64 bash -c '
      source "$1/PKGBUILD" >/dev/null 2>&1 || exit 1
      printf "%s\n" "${arch[*]}"
    ' _ "$package_dir") || exit 1
    if grep -Eq '(^|[[:space:]])(any|aarch64)($|[[:space:]])' <<< "$package_arches"; then
      basename "$package_dir"
    fi
  done
) | sort -u > "$expected_scope"
printf '%s\n' "${packages[@]}" | sort -u > "$actual_scope"
if ! diff -u "$expected_scope" "$actual_scope"; then
  echo "AArch64 scope drifted from the upstream edge package policy" >&2
  exit 1
fi
configured_upstream_scope="$work/configured-upstream-edge-scope"
derived_upstream_scope="$work/derived-upstream-edge-scope"
printf '%s\n' "${upstream_packages[@]}" | sort -u > "$configured_upstream_scope"
comm -23 "$actual_scope" <(printf '%s\n' "${fork_packages[@]}" | sort -u) > "$derived_upstream_scope"
if ! diff -u "$configured_upstream_scope" "$derived_upstream_scope"; then
  echo "Shared AArch64 range drifted from the reviewed upstream edge scope" >&2
  exit 1
fi

check_aarch64_metadata() {
  local package=$1 srcinfo package_work="$metadata_work/$1"
  mkdir -p "$package_work"
  srcinfo=$(cd "$ROOT/pkgbuilds/$package" && \
    CARCH=aarch64 BUILDDIR="$package_work" PKGDEST="$package_work" \
    SRCDEST="$package_work" SRCPKGDEST="$package_work" LOGDEST="$package_work" \
    makepkg --printsrcinfo) || {
    echo "Cannot generate AArch64 metadata for scoped package: $package" >&2
    return 1
  }
  grep -Eq '^[[:space:]]+arch = (any|aarch64)$' <<< "$srcinfo" || {
    echo "Scoped package does not support AArch64: $package" >&2
    return 1
  }
}
export ROOT metadata_work
export -f check_aarch64_metadata
# shellcheck disable=SC2016 # expanded by each xargs child shell
printf '%s\n' "${packages[@]}" | xargs -r -P 8 -n 1 bash -c 'check_aarch64_metadata "$1"' _

# The integration branch must never seed a rolling Release with a recipe older
# than the package state already published from the fork's previous master.
declare -A migration_minimums=(
  [limine-mkinitcpio-hook]='1.37.1-2'
  [omarchy-settings]='4.0.1.r6114.g1e06f6fa6bec-1'
  [omarchy]='4.0.1.r6114.g1e06f6fa6bec-1'
  [tensaku]='0.28.0-2'
  [tzupdate]='3.1.0-2'
  [t3code-bin]='0.0.36-1'
)
for package in "${!migration_minimums[@]}"; do
  version=$(CARCH=aarch64 bash -c '
    source "$1" >/dev/null 2>&1
    if [[ -n ${epoch:-} ]]; then
      printf "%s:%s-%s" "$epoch" "$pkgver" "$pkgrel"
    else
      printf "%s-%s" "$pkgver" "$pkgrel"
    fi
  ' _ "$ROOT/pkgbuilds/$package/PKGBUILD")
  [[ $(vercmp "$version" "${migration_minimums[$package]}") -ge 0 ]] || {
    echo "Migration would downgrade $package: $version < ${migration_minimums[$package]}" >&2
    exit 1
  }
done

for arch in x86_64 aarch64; do
  t3_work="$metadata_work/t3code-$arch"
  mkdir -p "$t3_work"
  srcinfo=$(cd "$ROOT/pkgbuilds/t3code-bin" && \
    CARCH=$arch BUILDDIR="$t3_work" PKGDEST="$t3_work" SRCDEST="$t3_work" \
    SRCPKGDEST="$t3_work" LOGDEST="$t3_work" makepkg --printsrcinfo)
  grep -Eq "^[[:space:]]+arch = $arch$" <<< "$srcinfo" || {
    echo "T3 Code migration lost the existing $arch package path" >&2
    exit 1
  }
done
mkdir -p "$metadata_work/dotnet"
dotnet_srcinfo=$(cd "$ROOT/pkgbuilds/dotnet-runtime-bin" && \
  CARCH=aarch64 BUILDDIR="$metadata_work/dotnet" \
  PKGDEST="$metadata_work/dotnet" SRCDEST="$metadata_work/dotnet" \
  SRCPKGDEST="$metadata_work/dotnet" LOGDEST="$metadata_work/dotnet" \
  makepkg --printsrcinfo)
grep -Eq '^[[:space:]]*pkgbase = dotnet-core-bin$' <<< "$dotnet_srcinfo" || {
  echo "Dotnet scope fixture no longer exercises a directory/pkgbase mismatch" >&2
  exit 1
}
grep -Fq 'expected_bases["$metadata_base"]=1' \
  "$ROOT/build/github-release-prepare.sh" || {
  echo "Repository audit assumes package directories are package bases" >&2
  exit 1
}
grep -Fq 'expected_outputs["$metadata_base:$package_name"]=1' \
  "$ROOT/build/github-release-prepare.sh" || {
  echo "Repository audit does not bind package names to their package base" >&2
  exit 1
}
mkdir -p "$metadata_work/ollama"
ollama_srcinfo=$(cd "$ROOT/pkgbuilds/ollama" && \
  CARCH=aarch64 BUILDDIR="$metadata_work/ollama" \
  PKGDEST="$metadata_work/ollama" SRCDEST="$metadata_work/ollama" \
  SRCPKGDEST="$metadata_work/ollama" LOGDEST="$metadata_work/ollama" \
  makepkg --printsrcinfo)
grep -Eq '^[[:space:]]+conflicts = ollama-cuda-jetpack5$' <<< "$ollama_srcinfo" || {
  echo "Ollama fixture no longer exercises mutually exclusive scoped outputs" >&2
  exit 1
}
grep -Fq 'for package_name in "${expected_sorted[@]}"; do' \
  "$ROOT/build/github-release-prepare.sh" || {
  echo "Repository audit combines mutually exclusive outputs in one transaction" >&2
  exit 1
}
if ! grep -Fq 'audit_failures=0' "$ROOT/build/github-release-prepare.sh" ||
  ! grep -Fq 'repository archive audit failed for $audit_failures package(s)' \
    "$ROOT/build/github-release-prepare.sh"; then
  echo "Repository audit stops before reporting all invalid archives" >&2
  exit 1
fi
for package in tensaku tzupdate; do
  jq -e '.pkgrel.offset == 1 and .pkgrel.suffix == 1' \
    "$ROOT/pkgbuilds/$package/.omarchy/package.json" >/dev/null || {
    echo "AUR synchronization would regress the published pkgrel for $package" >&2
    exit 1
  }
done
jq -e '.pkgrel.offset == 1 and .pkgrel.suffix == 2' \
  "$ROOT/pkgbuilds/limine-mkinitcpio-hook/.omarchy/package.json" >/dev/null || {
  echo 'AUR synchronization would regress the published pkgrel for limine-mkinitcpio-hook' >&2
  exit 1
}

configured_fingerprint=$(tr -d '[:space:]' < "$ROOT/config/aarch64-signing-fingerprint")
key_home=$(mktemp -d)
chmod 700 "$key_home"
public_fingerprint=$(GNUPGHOME=$key_home gpg --batch --show-keys --with-colons \
  "$ROOT/pkgbuilds/omarchy-aarch64-keyring/omarchy-aarch64.gpg" 2>/dev/null |
  awk -F: '$1 == "fpr" { print $10; exit }')
rm -rf "$key_home"
[[ $configured_fingerprint == "$public_fingerprint" ]] || {
  echo "Configured signing fingerprint does not match the published keyring" >&2
  exit 1
}

grep -Fq 'runs-on: ubuntu-24.04-arm' "$workflow" || {
  echo "AArch64 publisher is not pinned to a native ARM runner" >&2
  exit 1
}
grep -A5 -F 'full_rebuild:' "$workflow" | grep -Fq 'default: false' || {
  echo "Manual AArch64 channel release does not default to an expensive full rebuild" >&2
  exit 1
}
grep -Fq -- '--no-baseline' "$workflow" || {
  echo "Workflow cannot initialize a zero-baseline repository" >&2
  exit 1
}
for channel in edge rc stable; do
  grep -Fq -- "- $channel" "$workflow" || {
    echo "Workflow does not expose the $channel channel" >&2
    exit 1
  }
done
for operation in bootstrap-rc advance-edge-rc advance-rc-stable; do
  grep -Fq -- "- $operation" "$workflow" || {
    echo "Workflow does not expose $operation" >&2
    exit 1
  }
done
grep -Fq 'Stable RC baseline staged; overlaying current forwardable edge packages before first publication.' \
  "$ROOT/bin/github-release-aarch64" || {
  echo "RC bootstrap does not atomically overlay forwardable edge corrections" >&2
  exit 1
}
grep -Fq 'replace only the unpublished copy' \
  "$ROOT/bin/github-release-aarch64" || {
  echo "Chained RC bootstrap does not distinguish unpublished and immutable assets" >&2
  exit 1
}
grep -Fq 'multiple staged versions found for package' \
  "$ROOT/bin/github-release-aarch64" || {
  echo "Chained RC bootstrap does not reject ambiguous staged package versions" >&2
  exit 1
}
grep -Fq 'OMARCHY_RC_PINS:' "$workflow" || {
  echo "RC branch builds do not enable the upstream pinned-package guard" >&2
  exit 1
}
grep -Fq 'REPOSITORY_CHANNEL="$CHANNEL"' "$ROOT/bin/github-release-aarch64" || {
  echo "Repository preparation does not receive the selected channel" >&2
  exit 1
}
grep -Fq -- '--channel "$CHANNEL"' "$ROOT/bin/github-release-aarch64" || {
  echo "Publisher does not receive the selected channel" >&2
  exit 1
}
grep -Fq 'a zero-baseline validation repository must never be published' \
  "$ROOT/bin/github-release-aarch64" || {
  echo "Full-rebuild output is not protected against publication" >&2
  exit 1
}
grep -Fq 'download_args+=(--pattern "$filename" --pattern "$filename.sig")' \
  "$ROOT/bin/github-release-aarch64" || {
    echo "Channel advancement does not batch GitHub Release downloads" >&2
    exit 1
  }
advance_metadata_function=$(sed -n '/^metadata_entry_map()/,/^}/p' \
  "$ROOT/bin/github-release-aarch64")
if grep -Fq 'makepkg' <<< "$advance_metadata_function"; then
  echo "Channel advancement requires Arch-only makepkg on the Ubuntu runner host" >&2
  exit 1
fi
grep -Fq 'source PKGBUILD' <<< "$advance_metadata_function" || {
  echo "Channel advancement does not derive package identities from PKGBUILD" >&2
  exit 1
}
for invariant in \
  'full validation must not configure a remote package fallback' \
  'full validation attempted to use a non-local archive' \
  'audit_args=(--arch aarch64 --reject-foreign --json)' \
  '/build/audit-package-architecture.sh "${audit_args[@]}" "$package"'; do
  grep -Fq -- "$invariant" "$ROOT/build/github-release-prepare.sh" || {
    echo "Repository preparation lost full-rebuild invariant: $invariant" >&2
    exit 1
  }
done
for invariant in \
  'repository_state=$(mktemp)' \
  'bsdtar -xOf "$database" '\''*/desc'\'' |' \
  'packages: $state_packages[0]'; do
  grep -Fq -- "$invariant" "$ROOT/build/github-release-prepare.sh" || {
    echo "Repository manifest lost complete package state: $invariant" >&2
    exit 1
  }
done
for evidence_field in expanded_bytes non_target_elf_count \
  reviewed_non_target_elf_count managed_pe_count nested_archive_count \
  foreign_executable_count reviewed_foreign_executable_count max_depth_seen; do
  grep -Fq -- "--argjson $evidence_field" \
    "$ROOT/build/github-release-prepare.sh" || {
    echo "Repository audit omits recursive evidence: $evidence_field" >&2
    exit 1
  }
done
grep -Fq 'audit_args+=(--allowlist "$output_allowlist")' \
  "$ROOT/build/github-release-prepare.sh" || {
  echo 'Repository audit does not apply package-output architecture policies' >&2
  exit 1
}
if "$ROOT/bin/github-release-aarch64" scope --channel edge \
  --tag aarch64-stable >"$work/managed-tag.out" 2>&1; then
  echo 'GitHub adapter accepted a stable tag for the edge channel' >&2
  exit 1
fi
grep -Fq "does not match managed channel tag 'aarch64-edge'" \
  "$work/managed-tag.out"
if sed -E '/^[[:space:]]*#/d' \
  "$workflow" "$ROOT/bin/github-release-aarch64" "$ROOT/build/github-release-prepare.sh" |
  grep -Eiq 'setup_qemu|multiarch/qemu|binfmt'; then
  echo "GitHub Release adapter must not enable emulation" >&2
  exit 1
fi
grep -Fq 'OMARCHY_REPOSITORY_SERVER' "$ROOT/bin/build" || {
  echo "Generic builder cannot fetch unchanged GitHub-hosted dependencies" >&2
  exit 1
}
grep -Fq 'OMARCHY_REPOSITORY_KEY="/pkgbuilds/omarchy-aarch64-keyring/omarchy-aarch64.gpg"' \
  "$ROOT/bin/github-release-aarch64" || {
  echo "Incremental builder does not receive the checked-in repository key" >&2
  exit 1
}
grep -Fq 'OMARCHY_REPOSITORY_KEY_FINGERPRINT="$(expected_fingerprint)"' \
  "$ROOT/bin/github-release-aarch64" || {
  echo "Incremental builder does not pin the repository key fingerprint" >&2
  exit 1
}
grep -Fq 'OMARCHY_REPOSITORY_SERVER' "$ROOT/build/build.sh" || {
  echo "Builder container does not configure the remote package fallback" >&2
  exit 1
}
remote_fallback_line=$(grep -nF 'echo "Server = $OMARCHY_REPOSITORY_SERVER"' \
  "$ROOT/build/build.sh" | cut -d: -f1)
local_repository_line=$(grep -nF 'echo "Server = file://$FINAL_OUTPUT_DIR"' \
  "$ROOT/build/build.sh" | cut -d: -f1)
[[ -n $remote_fallback_line && -n $local_repository_line &&
   $remote_fallback_line -lt $local_repository_line ]] || {
  echo "Sparse GitHub storage fallback must precede the incomplete local archive store" >&2
  exit 1
}
grep -Fq 'source "$BUILD_ROOT/helpers/message-helpers.sh"' \
  "$ROOT/bin/github-release-aarch64" || {
  echo "GitHub Release adapter does not load Docker helper logging functions" >&2
  exit 1
}
grep -Fq -- '-v "$BUILD_ROOT/helpers:/helpers:ro"' \
  "$ROOT/bin/github-release-aarch64" || {
  echo "Repository audit container cannot extract nested ASAR payloads" >&2
  exit 1
}

# GitHub rewrites ':' in Release asset names. Normalize epoch filenames before
# repo-add records them, without altering the signed package bytes.
epoch_dir="$work/epoch"
mkdir -p "$epoch_dir"
printf 'package\n' > "$epoch_dir/example-1:2.0-1-aarch64.pkg.tar.zst"
printf 'signature\n' > "$epoch_dir/example-1:2.0-1-aarch64.pkg.tar.zst.sig"
"$ROOT/bin/normalize-github-release-packages" "$epoch_dir" >/dev/null
[[ -f $epoch_dir/example-1_epoch_2.0-1-aarch64.pkg.tar.zst ]] || {
  echo "Epoch package filename was not normalized" >&2
  exit 1
}
[[ -f $epoch_dir/example-1_epoch_2.0-1-aarch64.pkg.tar.zst.sig ]] || {
  echo "Epoch package signature filename was not normalized" >&2
  exit 1
}

# Exercise the GitHub API boundary with a stateful stub. Unchanged archives
# must not be transferred, while packages precede the signed database switch.
repo="$work/repository"
stub_bin="$work/bin"
mkdir -p "$repo" "$stub_bin"
ln -s "$ROOT/test/fixtures/gh-release-stub" "$stub_bin/gh"
export GH_STUB_LOG="$work/gh.log"
export GH_STUB_ASSETS="$work/assets"
export GH_STUB_UPLOADS="$work/uploads"
: > "$GH_STUB_LOG"
: > "$GH_STUB_UPLOADS"

old_package=old-package-1.0-1-aarch64.pkg.tar.zst
new_package=new-package-2.0-1-aarch64.pkg.tar.zst
stale_package=stale-package-1.0-1-aarch64.pkg.tar.zst
old_hash=1111111111111111111111111111111111111111111111111111111111111111
old_sig_hash=2222222222222222222222222222222222222222222222222222222222222222
metadata=(
  omarchy-aarch64.gpg
  repository-build-audit.json
  repository-manifest.json
  omarchy.files.tar.zst.sig
  omarchy.files.tar.zst
  omarchy.files.sig
  omarchy.files
  omarchy.db.tar.zst.sig
  omarchy.db.tar.zst
  omarchy.db.sig
  omarchy.db
)

printf 'new package\n' > "$repo/$new_package"
printf 'new signature\n' > "$repo/$new_package.sig"
for asset in "${metadata[@]}"; do
  printf 'new %s\n' "$asset" > "$repo/$asset"
done
printf '{"schema":1,"architecture":"aarch64","channel":"stable"}\n' \
  > "$repo/repository-manifest.json"
{
  printf '%s  %s\n' "$old_hash" "$old_package"
  printf '%s  %s.sig\n' "$old_sig_hash" "$old_package"
  (cd "$repo" && sha256sum "$new_package" "$new_package.sig" "${metadata[@]}")
} > "$repo/SHA256SUMS"
{
  printf '%s  %s\n' "$old_hash" "$old_package"
  printf '%s  %s.sig\n' "$old_sig_hash" "$old_package"
} > "$repo/.baseline-SHA256SUMS"
{
  printf '%s\n' "$old_package" "$old_package.sig" "$stale_package" "$stale_package.sig"
  printf '%s\n' "${metadata[@]}"
} > "$GH_STUB_ASSETS"

PATH="$stub_bin:$PATH" GH_TOKEN=test \
  "$ROOT/bin/publish-github-release" \
    --repository example/repo --repo-dir "$repo" --tag aarch64-stable \
    --channel stable >/dev/null

grep -Fxq "upload $new_package" "$GH_STUB_LOG"
grep -Fxq "upload $new_package.sig" "$GH_STUB_LOG"
if grep -Fq "upload $old_package" "$GH_STUB_LOG" ||
  grep -Fq "upload $old_package.sig" "$GH_STUB_LOG"; then
  echo "Publisher retransferred an unchanged baseline package" >&2
  exit 1
fi
package_line=$(grep -n "^upload $new_package$" "$GH_STUB_LOG" | cut -d: -f1)
database_line=$(grep -n '^upload omarchy.db$' "$GH_STUB_LOG" | cut -d: -f1)
database_sig_line=$(grep -n '^upload omarchy.db.sig$' "$GH_STUB_LOG" | cut -d: -f1)
[[ $package_line -lt $database_sig_line && $database_sig_line -lt $database_line ]] || {
  echo "Publisher did not upload packages and signatures before the database switch" >&2
  exit 1
}
grep -Fxq "delete-asset $stale_package" "$GH_STUB_LOG"
grep -Fxq "delete-asset $stale_package.sig" "$GH_STUB_LOG"
! grep -Fq 'delete-release ' "$GH_STUB_LOG" || {
  echo "Adapter attempted to delete an unrelated GitHub Release" >&2
  exit 1
}
grep -E '^edit .*Omarchy AArch64 stable \(rolling\).*--latest' "$GH_STUB_LOG" >/dev/null || {
  echo "Stable publisher did not preserve the latest rolling Release" >&2
  exit 1
}

: > "$GH_STUB_LOG"
PATH="$stub_bin:$PATH" GH_TOKEN=test \
  "$ROOT/bin/publish-github-release" \
    --repository example/repo --repo-dir "$repo" --tag aarch64-stable \
    --channel stable >/dev/null
! grep -Eq '^upload .+\.pkg\.tar\.zst(\.sig)?$' "$GH_STUB_LOG" || {
  echo "Publisher retransferred an asset that GitHub already stored" >&2
  exit 1
}

# Edge and rc are explicit prerelease channels, never candidates for GitHub's
# /releases/latest/download endpoint used by stable clients.
printf '{"schema":1,"architecture":"aarch64","channel":"edge"}\n' \
  > "$repo/repository-manifest.json"
{
  printf '%s  %s\n' "$old_hash" "$old_package"
  printf '%s  %s.sig\n' "$old_sig_hash" "$old_package"
  (cd "$repo" && sha256sum "$new_package" "$new_package.sig" "${metadata[@]}")
} > "$repo/SHA256SUMS"
: > "$GH_STUB_LOG"
: > "$GH_STUB_UPLOADS"
PATH="$stub_bin:$PATH" GH_TOKEN=test \
  "$ROOT/bin/publish-github-release" \
    --repository example/repo --repo-dir "$repo" --tag aarch64-edge \
    --channel edge >/dev/null
grep -E '^edit .*Omarchy AArch64 edge \(rolling\).*--prerelease' "$GH_STUB_LOG" >/dev/null || {
  echo "Edge publisher did not mark the rolling Release as a prerelease" >&2
  exit 1
}
if grep -E '^edit .*--latest' "$GH_STUB_LOG" >/dev/null; then
  echo "Edge publisher attempted to replace the stable latest Release" >&2
  exit 1
fi
if PATH="$stub_bin:$PATH" GH_TOKEN=test \
  "$ROOT/bin/publish-github-release" \
    --repository example/repo --repo-dir "$repo" --tag aarch64-rc \
    --channel rc >"$work/channel-mismatch.out" 2>&1; then
  echo "Publisher accepted a repository manifest from the wrong channel" >&2
  exit 1
fi
grep -Fq "does not match 'rc'" "$work/channel-mismatch.out"

: > "$GH_STUB_LOG"
if PATH="$stub_bin:$PATH" GH_TOKEN=test \
  "$ROOT/bin/publish-github-release" \
    --repository example/repo --repo-dir "$repo" --tag aarch64-stable \
    --channel edge >"$work/tag-mismatch.out" 2>&1; then
  echo "Publisher accepted the stable tag for the edge channel" >&2
  exit 1
fi
grep -Fq "does not match managed channel tag 'aarch64-edge'" \
  "$work/tag-mismatch.out"
[[ ! -s $GH_STUB_LOG ]] || {
  echo "Publisher contacted GitHub before rejecting a cross-channel tag" >&2
  exit 1
}

echo "PASS: native AArch64 GitHub Release adapter preserves scope and atomic publication"
