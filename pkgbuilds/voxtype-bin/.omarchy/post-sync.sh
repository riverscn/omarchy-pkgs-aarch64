#!/bin/bash
set -euo pipefail

sed -i \
  -e 's/^pkgname=voxtype$/pkgname=voxtype-bin/' \
  -e 's/^pkgdesc=.*/pkgdesc="Push-to-talk voice-to-text for Linux (native AArch64 build)"/' \
  PKGBUILD

sed -i "/^pkgdesc=/a provides=('voxtype')\nconflicts=('voxtype')" PKGBUILD
