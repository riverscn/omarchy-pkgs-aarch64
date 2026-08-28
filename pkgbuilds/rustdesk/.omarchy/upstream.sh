#!/bin/bash

set -euo pipefail

releases=$(curl -fsSL --retry 3 \
  'https://api.github.com/repos/rustdesk/rustdesk/releases?per_page=100')

release=$(jq -c '
  [
    .[]
    | select(.draft == false and .prerelease == false)
    | (.tag_name | sub("^v"; "")) as $version
    | .assets[]?
    | select(.name == "rustdesk-\($version)-aarch64.deb")
    | select((.digest // "") | startswith("sha256:"))
    | {
        pkgver: $version,
        published_at: .created_at,
        sha256sums: {aarch64: [(.digest | sub("^sha256:"; ""))]}
      }
  ]
  | first // empty
' <<<"$releases")

[[ -n $release ]] || {
  echo 'No stable RustDesk release with a verified AArch64 Debian package was found' >&2
  exit 1
}

printf '%s\n' "$release"
