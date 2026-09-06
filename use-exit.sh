#!/usr/bin/env bash
# Back-compat wrapper. Prefer: bin/nord-exit or ~/bin/nord-exit
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/bin/nord-exit" "$@"
