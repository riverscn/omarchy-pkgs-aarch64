#!/bin/bash
set -euo pipefail

sed -i \
  -e 's/^pkgname=zed-bin$/pkgname=zed/' \
  -e 's/^provides=.*/provides=("zed-bin=$pkgver")/' \
  -e "s/^conflicts=.*/conflicts=('zed-bin' 'zed-git' 'zed-preview-bin')/" \
  PKGBUILD
