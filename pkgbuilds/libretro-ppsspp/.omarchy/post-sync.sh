#!/bin/bash
set -euo pipefail

sed -i 's/arch=(x86_64)/arch=(x86_64 aarch64)/' PKGBUILD
cp .omarchy/libretro-ppsspp-linux-arm64-no-adrenotools.patch .
sed -i '/^  libretro-ppsspp-assets-path\.patch$/a\  libretro-ppsspp-linux-arm64-no-adrenotools.patch' PKGBUILD
sed -i "s|'b46c8f4a147f1b8fddb8664982c4568e9cac74afad65cb16adbccaba26b93baf0f59dd51693a422bd64782c4a95cf8e2ff55e848701b2fb1e1e785ca611d1dc6')|'b46c8f4a147f1b8fddb8664982c4568e9cac74afad65cb16adbccaba26b93baf0f59dd51693a422bd64782c4a95cf8e2ff55e848701b2fb1e1e785ca611d1dc6'\\n        'ae0a0b2153cbc21b2b8b253d132974cbb58560b941951dd574cfcacaaea9c4021e115e5594928261d46442b38715bf9fb850a39c57cb1e41980a26f7837da4cf')|" PKGBUILD
sed -i '/patch -Np1 -i ..\/libretro-ppsspp-assets-path.patch/a\  patch -Np1 -i ../libretro-ppsspp-linux-arm64-no-adrenotools.patch' PKGBUILD
sed -i '/^build() {/a\  local make_options=()\n  [[ $CARCH != aarch64 ]] || make_options+=(platform=arm64)' PKGBUILD
sed -i 's|make -C libretro-ppsspp/libretro$|make -C libretro-ppsspp/libretro "${make_options[@]}"|' PKGBUILD
