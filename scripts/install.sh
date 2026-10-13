#!/usr/bin/env bash
# Build macctl and put it on PATH.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO=$(pwd)
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}

bash scripts/build.sh
mkdir -p "$BIN_DIR"
ln -sf "$REPO/bin/macctl" "$BIN_DIR/macctl"
echo
echo "installed: $BIN_DIR/macctl -> $REPO/bin/macctl"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "WARNING: $BIN_DIR is not on your PATH" ;;
esac

# Window snapping is part of the default install; WINDOW_MANAGER=0 skips it.
if [ "${WINDOW_MANAGER:-1}" != 0 ]; then
  echo
  bash scripts/install-rectangle.sh
fi

"$REPO/bin/macctl" doctor || true
