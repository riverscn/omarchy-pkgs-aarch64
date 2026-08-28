#!/bin/bash
set -euo pipefail

sed -i 's/arch=(x86_64)/arch=(x86_64 aarch64)/' PKGBUILD
sed -i '/^build() {/a\  local make_options=()\n  [[ $CARCH != aarch64 ]] || make_options+=(platform=arm64)' PKGBUILD
sed -i 's|make -C libretro-ppsspp/libretro$|make -C libretro-ppsspp/libretro "${make_options[@]}"|' PKGBUILD
