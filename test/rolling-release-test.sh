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

echo "PASS: rolling publisher retains unchanged packages and atomically switches the signed database"
