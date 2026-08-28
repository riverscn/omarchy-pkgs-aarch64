#!/bin/bash
set -euo pipefail

sed -i "s/arch=('x86_64')/arch=('x86_64' 'aarch64')/" PKGBUILD
sed -i '/^source=(/,/^rg.sh)$/c\source=(\n  "https://gitlab.archlinux.org/archlinux/packaging/packages/code/-/raw/main/code.sh"\n  "https://gitlab.archlinux.org/archlinux/packaging/packages/code/-/raw/main/code.mjs"\n  rg.sh\n)\nsource_x86_64=("cursor_${pkgver}_amd64.deb::https://downloads.cursor.com/production/${_commit}/linux/x64/deb/amd64/deb/cursor_${pkgver}_amd64.deb")\nsource_aarch64=("cursor_${pkgver}_arm64.deb::https://downloads.cursor.com/production/${_commit}/linux/arm64/deb/arm64/deb/cursor_${pkgver}_arm64.deb")' PKGBUILD
sed -i \
  -e "s/^sha512sums=('SKIP'/sha512sums=(/" \
  -e "s/^sha512sums\[0\]=\(.*\)$/sha512sums_x86_64=(\1)\nsha512sums_aarch64=('SKIP')/" \
  -e '/^noextract=/i _deb_arch=$([[ $CARCH == aarch64 ]] \&\& echo arm64 || echo amd64)' \
  -e 's/^noextract=.*/noextract=(cursor_${pkgver}_${_deb_arch}.deb)/' \
  PKGBUILD
