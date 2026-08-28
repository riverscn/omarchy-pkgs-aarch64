#!/bin/bash

set -euo pipefail

ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
fixture="$ROOT/test/fixtures/gh-release-stub"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
repo="$work/repository"
stub_bin="$work/bin"
mkdir -p "$repo" "$stub_bin"
ln -s "$fixture" "$stub_bin/gh"

export GH_STUB_LOG="$work/gh.log"
export GH_STUB_ASSETS="$work/assets"
export GH_STUB_UPLOADS="$work/uploads"
: > "$GH_STUB_LOG"
: > "$GH_STUB_UPLOADS"

desired_state="$work/desired-state.json"
partial_state="$work/partial-state.json"
complete_state="$work/complete-state.json"
failure_report="$work/failed-packages"
jq -S -n '{schema: 1, architecture: "aarch64", channel: "stable", packages: []}' > "$desired_state"
printf '%s\n' ghostty cursor-bin ghostty > "$failure_report"
"$ROOT/bin/write-aarch64-release-state" \
  --version-set "$desired_state" --failure-report "$failure_report" --output "$partial_state" >/dev/null
jq -e '.failed_packages == ["cursor-bin", "ghostty"]' "$partial_state" >/dev/null || {
  echo "partial release state did not record sorted unique failures" >&2
  exit 1
}
cmp -s "$desired_state" "$partial_state" && {
  echo "partial release state would suppress the next retry" >&2
  exit 1
}
: > "$failure_report"
"$ROOT/bin/write-aarch64-release-state" \
  --version-set "$desired_state" --failure-report "$failure_report" --output "$complete_state"
cmp -s "$desired_state" "$complete_state" || {
  echo "complete release state differs from the desired plan" >&2
  exit 1
}

# Pacman writes epochs with ':' in archive filenames. GitHub artifact uploads
# reject those names individually, so the workflow transfers a tar wrapper.
transfer_source="$work/transfer-source"
transfer_restore="$work/transfer-restore"
mkdir -p "$transfer_source" "$transfer_restore"
touch "$transfer_source/asdcontrol-1:0.6.0-1-aarch64.pkg.tar.zst"
touch "$transfer_source/asdcontrol-1:0.6.0-1-aarch64.pkg.tar.zst.sig"
tar -cf "$work/aarch64-changed-packages.tar" -C "$transfer_source" .
tar -xf "$work/aarch64-changed-packages.tar" -C "$transfer_restore"
[[ -f "$transfer_restore/asdcontrol-1:0.6.0-1-aarch64.pkg.tar.zst" ]] || {
  echo "artifact transfer did not preserve a pacman epoch filename" >&2
  exit 1
}

# GitHub Releases silently rewrite ':' to '.', so normalize epoch filenames
# ourselves before repo-add records them. Package contents and versions stay
# untouched; only the externally hosted archive/signature names change.
"$ROOT/bin/normalize-github-release-packages" "$transfer_restore" >/dev/null
[[ -f "$transfer_restore/asdcontrol-1_epoch_0.6.0-1-aarch64.pkg.tar.zst" ]] || {
  echo "GitHub Release package filename was not normalized" >&2
  exit 1
}
[[ -f "$transfer_restore/asdcontrol-1_epoch_0.6.0-1-aarch64.pkg.tar.zst.sig" ]] || {
  echo "GitHub Release package signature filename was not normalized" >&2
  exit 1
}
compgen -G "$transfer_restore/*:*" >/dev/null && {
  echo "GitHub Release package normalization left a colon in an asset name" >&2
  exit 1
}

old_package=old-package-1.0-1-aarch64.pkg.tar.zst
new_package=new-package-2.0-1-aarch64.pkg.tar.zst
stale_package=stale-package-1.0-1-aarch64.pkg.tar.zst
old_hash=1111111111111111111111111111111111111111111111111111111111111111
old_sig_hash=2222222222222222222222222222222222222222222222222222222222222222

metadata=(
  omarchy-aarch64.gpg
  repository-version-set.json
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
  "$ROOT/bin/publish-github-release" --repository example/repo --repo-dir "$repo" --tag aarch64-stable >/dev/null

grep -Fxq "upload $new_package" "$GH_STUB_LOG" || { echo "new package was not uploaded" >&2; exit 1; }
grep -Fxq "upload $new_package.sig" "$GH_STUB_LOG" || { echo "new signature was not uploaded" >&2; exit 1; }
grep -Fq "upload $old_package" "$GH_STUB_LOG" && { echo "unchanged package was uploaded" >&2; exit 1; }
grep -Fq "upload $old_package.sig" "$GH_STUB_LOG" && { echo "unchanged signature was uploaded" >&2; exit 1; }

db_sig_line=$(grep -n '^upload omarchy.db.sig$' "$GH_STUB_LOG" | cut -d: -f1)
db_line=$(grep -n '^upload omarchy.db$' "$GH_STUB_LOG" | cut -d: -f1)
[[ -n $db_sig_line && -n $db_line && $db_sig_line -lt $db_line ]] || {
  echo "database signature was not uploaded before the database" >&2
  exit 1
}

grep -Fq -- '--draft=false --latest' "$GH_STUB_LOG" || { echo "rolling Release was not published/latest" >&2; exit 1; }
grep -Fxq "delete-asset $stale_package" "$GH_STUB_LOG" || { echo "stale package was not pruned" >&2; exit 1; }
grep -Fxq "delete-asset $stale_package.sig" "$GH_STUB_LOG" || { echo "stale signature was not pruned" >&2; exit 1; }
grep -Fxq 'delete-release old-snapshot' "$GH_STUB_LOG" || { echo "old Release was not pruned" >&2; exit 1; }

# An interrupted publication can leave all immutable package assets uploaded
# before the database switch. Their live GitHub digests must make the next run
# resume without transferring those packages again, even when the old signed
# SHA256SUMS still describes the previous repository state.
: > "$GH_STUB_LOG"
PATH="$stub_bin:$PATH" GH_TOKEN=test \
  "$ROOT/bin/publish-github-release" --repository example/repo --repo-dir "$repo" --tag aarch64-stable >/dev/null
grep -Eq '^upload .+\.pkg\.tar\.zst(\.sig)?$' "$GH_STUB_LOG" && {
  echo "an already uploaded package was transferred again during resume" >&2
  exit 1
}

echo "PASS: rolling publisher retains unchanged packages and atomically switches the signed database"
