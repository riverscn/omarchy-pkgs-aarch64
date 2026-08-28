#!/bin/bash
set -euo pipefail

sed -i 's/arch=(x86_64)/arch=(x86_64 aarch64)/' PKGBUILD
sed -i '/git+https:\/\/github.com\/libretro\/libretro-common.git/a\  git+https://github.com/bylaws/libadrenotools.git' PKGBUILD
sed -i "/'b46c8f4a147f1b8fddb8664982c4568e9cac74afad65cb16adbccaba26b93baf0f59dd51693a422bd64782c4a95cf8e2ff55e848701b2fb1e1e785ca611d1dc6'/i\\        'SKIP'" PKGBUILD
sed -i 's/ext\/{aemu_postoffice,armips,cpu_features,libchdr,/ext\/{aemu_postoffice,armips,cpu_features,libadrenotools,libchdr,/' PKGBUILD
sed -i '/^build() {/a\  local make_options=()\n  [[ $CARCH != aarch64 ]] || make_options+=(platform=arm64)' PKGBUILD
sed -i 's|make -C libretro-ppsspp/libretro$|make -C libretro-ppsspp/libretro "${make_options[@]}"|' PKGBUILD
