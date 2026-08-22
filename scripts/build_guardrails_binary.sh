#!/usr/bin/env bash
set -euo pipefail

# Local-dev alternative to download_guardrails_binary.sh: builds `guardrail`
# from a sibling checkout and drops it in Hoplon/Resources/.
#
# The pinned release is the normal path; this is the fallback when the download
# fails, or when you need unreleased work from a local checkout. Brings
# guardrails in line with the other Rust services, which all have one.
#
#   GUARDRAILS_REPO=../guardrails   where to build from
#   GUARDRAILS_BIN=/path/to/binary  reuse a prebuilt binary, skip the cargo build

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Hoplon/Resources"
GUARDRAILS_REPO="${GUARDRAILS_REPO:-$REPO_ROOT/../guardrails}"

mkdir -p "$OUT_DIR"

if [[ -n "${GUARDRAILS_BIN:-}" ]]; then
  [[ -x "$GUARDRAILS_BIN" ]] || { echo "ERROR: GUARDRAILS_BIN=$GUARDRAILS_BIN is not executable"; exit 1; }
  echo "==> Using prebuilt binary: $GUARDRAILS_BIN"
  SRC="$GUARDRAILS_BIN"
else
  command -v cargo >/dev/null 2>&1 || { echo "ERROR: cargo is not installed. See https://rustup.rs"; exit 1; }
  [[ -f "$GUARDRAILS_REPO/Cargo.toml" ]] || {
    echo "ERROR: no guardrails checkout at $GUARDRAILS_REPO"
    echo "       Clone it beside hoplon, or set GUARDRAILS_REPO."
    exit 1
  }
  echo "==> Building guardrail (release) from $GUARDRAILS_REPO"
  ( cd "$GUARDRAILS_REPO" && cargo build --release -p guardrail )
  SRC="$GUARDRAILS_REPO/target/release/guardrail"
fi

install -m 0755 "$SRC" "$OUT_DIR/guardrail"
echo "==> Done. Binary at: $OUT_DIR/guardrail"
ls -lh "$OUT_DIR/guardrail"
