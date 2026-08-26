#!/bin/bash

set -euo pipefail

repository=${REPOSITORY_DIR:-/repository}
: "${GPG_PRIVATE_KEY:?GPG_PRIVATE_KEY is required}"
: "${GPG_PASSPHRASE:?GPG_PASSPHRASE is required}"

key_home=$(mktemp -d)
trap 'rm -rf "$key_home"' EXIT
chmod 700 "$key_home"
export GNUPGHOME=$key_home

printf '%s' "$GPG_PRIVATE_KEY" | gpg --batch --import >/dev/null 2>&1
key_id=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "sec" { print $5; exit }')
[[ -n $key_id ]] || { echo "ERROR: no secret signing key was imported" >&2; exit 1; }

for database in omarchy.db.tar.zst omarchy.files.tar.zst; do
  path="$repository/$database"
  [[ -f $path ]] || { echo "ERROR: missing repository database: $path" >&2; exit 1; }
  # Incremental releases seed the previous signed database from GitHub. The
  # bind-mounted signature belongs to the host runner, while this container
  # deliberately signs as its unprivileged builder user. Remove the obsolete
  # signature through the writable repository directory before creating the
  # signature for the newly generated database.
  rm -f -- "$path.sig"
  gpg --batch --yes --pinentry-mode loopback \
    --passphrase "$GPG_PASSPHRASE" \
    --local-user "$key_id" \
    --detach-sign "$path"
done
