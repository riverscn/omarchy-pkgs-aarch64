#!/bin/bash
set -euo pipefail

sed -i '/^[[:space:]]*pandoc-cli$/d' PKGBUILD
sed -i '/^[[:space:]]*zig)$/a\makedepends_x86_64=(pandoc-cli)' PKGBUILD
sed -i '/^build() {/,/^}/ { /^[[:space:]]*cd "$_archive"$/a\	local docs_option=-Demit-docs\n\t[[ $CARCH != aarch64 ]] || docs_option=-Demit-docs=false
}' PKGBUILD
sed -i 's/^[[:space:]]*-Demit-docs \\/\t\t"$docs_option" \\/' PKGBUILD
