#!/usr/bin/env bash
set -euo pipefail

# Local-dev alternative to download_memory_binary.sh: builds `memory-rs` from a
# sibling checkout and drops it in Hoplon/Resources/.
#
# This is currently the ONLY working path — memory-rs v0.1.0 published a release
# without built assets.
#
#   MEMORY_REPO=../memory-rs   where to build from
#   MEMORY_BIN=/path/to/binary reuse a prebuilt binary, skip the cargo build

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Hoplon/Resources"
MEMORY_REPO="${MEMORY_REPO:-$REPO_ROOT/../memory-rs}"

mkdir -p "$OUT_DIR"

if [[ -n "${MEMORY_BIN:-}" ]]; then
  [[ -x "$MEMORY_BIN" ]] || { echo "ERROR: MEMORY_BIN=$MEMORY_BIN is not executable"; exit 1; }
  echo "==> Using prebuilt binary: $MEMORY_BIN"
  SRC="$MEMORY_BIN"
else
  command -v cargo >/dev/null 2>&1 || { echo "ERROR: cargo is not installed. See https://rustup.rs"; exit 1; }
  [[ -f "$MEMORY_REPO/Cargo.toml" ]] || {
    echo "ERROR: no memory-rs checkout at $MEMORY_REPO"
    echo "       Clone it beside hoplon, or set MEMORY_REPO."
    exit 1
  }
  echo "==> Building memory-rs (release) from $MEMORY_REPO"
  ( cd "$MEMORY_REPO" && cargo build --release )
  SRC="$MEMORY_REPO/target/release/memory-rs"
fi

# The app launches `memory-rs serve`; a checkout that predates that command
# would produce a bundle that fails at runtime. Catch it here.
if ! "$SRC" serve --help >/dev/null 2>&1; then
  echo "ERROR: this memory-rs build has no 'serve' subcommand."
  echo "       Update the checkout at $MEMORY_REPO."
  exit 1
fi

install -m 0755 "$SRC" "$OUT_DIR/memory-rs"
echo "==> Done. Binary at: $OUT_DIR/memory-rs"
ls -lh "$OUT_DIR/memory-rs"
