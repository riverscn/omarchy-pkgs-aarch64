#!/bin/bash

set -euo pipefail
sed -i "s/^arch=.*/arch=('any')/" PKGBUILD
