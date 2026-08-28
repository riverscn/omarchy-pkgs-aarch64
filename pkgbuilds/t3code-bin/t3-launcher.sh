#!/bin/bash
set -euo pipefail

export ELECTRON_RUN_AS_NODE=1
exec /usr/lib/t3code/t3code \
  /usr/lib/t3code/resources/app.asar/apps/server/dist/bin.mjs "$@"
