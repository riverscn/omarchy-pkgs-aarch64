#!/bin/bash
set -euo pipefail

sed -i \
  -e 's/^pkgname=voxtype$/pkgname=voxtype-bin/' \
  -e 's/^pkgdesc=.*/pkgdesc="Push-to-talk voice-to-text for Linux (native AArch64 build)"/' \
  PKGBUILD

sed -i "/^pkgdesc=/a provides=('voxtype')\nconflicts=('voxtype')" PKGBUILD
sed -i 's|"$pkgname-$pkgver.tar.gz.asc::https://github.com/peteonrails/voxtype/releases/download/v$pkgver/$pkgname-$pkgver.tar.gz.asc"|"voxtype-$pkgver.tar.gz.asc::https://github.com/peteonrails/voxtype/releases/download/v$pkgver/voxtype-$pkgver.tar.gz.asc"|' PKGBUILD
