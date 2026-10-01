#!/usr/bin/env bash
# Subprocess fixtures only: no screen reading, input, or installed macctl calls.
# Requires Python 3.10+ and Node 22.6+ with native TypeScript stripping.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 -c 'import sys; assert sys.version_info >= (3, 10), "client tests require Python 3.10+"'
if ! command -v node >/dev/null || ! node --experimental-strip-types --version >/dev/null 2>&1; then
  echo 'client tests require Node 22.6+ with --experimental-strip-types' >&2
  exit 1
fi
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Clients -p 'test_python.py' -v
node --experimental-strip-types --test Tests/Clients/typescript.test.mjs
