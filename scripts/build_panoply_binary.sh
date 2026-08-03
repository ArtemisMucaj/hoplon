#!/usr/bin/env bash
set -euo pipefail

# Local-dev alternative to download_panoply_binary.sh: builds the `panoply`
# PyInstaller binary from a sibling checkout and drops it in Hoplon/Resources/.
#
#   PANOPLY_REPO=../panoply     where to build from
#   PANOPLY_BIN=/path/to/binary reuse a prebuilt binary, skip the PyInstaller run

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Hoplon/Resources"
PANOPLY_REPO="${PANOPLY_REPO:-$REPO_ROOT/../panoply}"

mkdir -p "$OUT_DIR"

if [[ -n "${PANOPLY_BIN:-}" ]]; then
  [[ -x "$PANOPLY_BIN" ]] || { echo "ERROR: PANOPLY_BIN=$PANOPLY_BIN is not executable"; exit 1; }
  echo "==> Using prebuilt binary: $PANOPLY_BIN"
  SRC="$PANOPLY_BIN"
else
  [[ -f "$PANOPLY_REPO/scripts/build_panoply_binary.sh" ]] || {
    echo "ERROR: no panoply checkout at $PANOPLY_REPO"
    echo "       Clone it beside hoplon, or set PANOPLY_REPO."
    exit 1
  }
  echo "==> Building panoply (PyInstaller) from $PANOPLY_REPO"
  ( cd "$PANOPLY_REPO" && bash scripts/build_panoply_binary.sh )
  SRC="$PANOPLY_REPO/dist/panoply"
fi

install -m 0755 "$SRC" "$OUT_DIR/panoply"
echo "==> Done. Binary at: $OUT_DIR/panoply"
ls -lh "$OUT_DIR/panoply"
