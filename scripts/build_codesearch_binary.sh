#!/usr/bin/env bash
set -euo pipefail

# Local-dev alternative to download_codesearch_binary.sh: builds `codesearch`
# from a sibling checkout and drops it in Hoplon/Resources/.
#
# This is currently the path to use — the version the app targets (memory
# subsystem extracted into memory-rs, LLM stack on openai-rs) is not released
# yet, so the published assets are the wrong shape.
#
#   CODESEARCH_REPO=../codesearch   where to build from
#   CODESEARCH_BIN=/path/to/binary  reuse a prebuilt binary, skip the cargo build

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Hoplon/Resources"
CODESEARCH_REPO="${CODESEARCH_REPO:-$REPO_ROOT/../codesearch}"

mkdir -p "$OUT_DIR"

if [[ -n "${CODESEARCH_BIN:-}" ]]; then
  [[ -x "$CODESEARCH_BIN" ]] || { echo "ERROR: CODESEARCH_BIN=$CODESEARCH_BIN is not executable"; exit 1; }
  echo "==> Using prebuilt binary: $CODESEARCH_BIN"
  SRC="$CODESEARCH_BIN"
else
  command -v cargo >/dev/null 2>&1 || { echo "ERROR: cargo is not installed. See https://rustup.rs"; exit 1; }
  [[ -f "$CODESEARCH_REPO/Cargo.toml" ]] || {
    echo "ERROR: no codesearch checkout at $CODESEARCH_REPO"
    echo "       Clone it beside hoplon, or set CODESEARCH_REPO."
    exit 1
  }
  echo "==> Building codesearch (release) from $CODESEARCH_REPO"
  ( cd "$CODESEARCH_REPO" && cargo build --release )
  SRC="$CODESEARCH_REPO/target/release/codesearch"
fi

# The app launches `codesearch serve`; a checkout that predates it would produce
# a bundle that fails at runtime. Catch it here.
if ! "$SRC" serve --help >/dev/null 2>&1; then
  echo "ERROR: this codesearch build has no 'serve' subcommand."
  echo "       Update the checkout at $CODESEARCH_REPO."
  exit 1
fi

# The app expects the post-extraction build: memory lives in memory-rs now, so a
# binary that still serves /api/memory would double up with the Memory section.
if "$SRC" --help 2>&1 | grep -qiE '^\s+memory\b'; then
  echo "WARNING: this codesearch build still has a 'memory' command — it predates"
  echo "         the extraction into memory-rs. Hoplon drives memory through"
  echo "         memory-rs; the two will fight over the same data."
fi

install -m 0755 "$SRC" "$OUT_DIR/codesearch"
echo "==> Done. Binary at: $OUT_DIR/codesearch"
ls -lh "$OUT_DIR/codesearch"
