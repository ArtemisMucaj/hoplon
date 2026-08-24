#!/usr/bin/env bash
set -euo pipefail

# Downloads the prebuilt `memory-rs` binary into Hoplon/Resources/.
# build_memory_binary.sh is the fallback if the download fails.
#
# v0.4.0 simplifies the memory model to facts + entities. This is a BREAKING
# upgrade and the app was migrated to match it:
#   - GET /api/stats and GET /api/conflicts are gone. The Memory overview now
#     counts memories/entities/sessions client-side.
#   - MemoryKind collapsed to `fact` alone, and /api/memory and /api/search no
#     longer take `kind` or `status` params.
#   - The edge/provenance graph is gone; a memory is a flat fact.
#   - DELETE /api/memory/{id} is now a hard delete returning {deleted: true},
#     not the old retraction returning {retracted: …}.
#
# It also CANNOT open a v0.3.x memory.duckdb — it exits at startup asking for
# the database to be deleted and the sessions re-imported. Going back to
# v0.3.x means the app's memory client no longer matches the server, so the
# guard below pins the direction rather than allowing either.
#
# Override the pin with:
#   MEMORY_VERSION=latest bash scripts/download_memory_binary.sh

MEMORY_VERSION="${MEMORY_VERSION:-v0.4.0}"
MEMORY_ASSET="${MEMORY_ASSET:-memory-rs-macos-aarch64}"

source "$(dirname "$0")/lib/fetch_release_asset.sh"
fetch_release_asset "ArtemisMucaj/memory-rs" "$MEMORY_VERSION" "$MEMORY_ASSET" "memory-rs"

# Fail closed if the asset predates `serve` (a tag can match a pre-feature build).
OUT="$(cd "$(dirname "$0")/.." && pwd)/Hoplon/Resources/memory-rs"
if ! "$OUT" serve --help >/dev/null 2>&1; then
  echo "ERROR: release asset has no 'serve' subcommand — the app cannot use it."
  echo "       Pin MEMORY_VERSION to a release that includes serve, or use"
  echo "       scripts/build_memory_binary.sh to build from a local checkout."
  exit 1
fi

# Fail closed if the asset predates the v0.4.0 model change, so a pin or a
# `latest` that resolves backwards cannot install a server the migrated app
# can no longer drive. Probe the served routes rather than the tag: a tag says
# nothing about which handlers were compiled in.
#
# The probe runs against a THROWAWAY --data-dir: v0.4.0 refuses to open a
# v0.3.x memory.duckdb, so probing the real data dir would report on the
# user's database instead of on this binary.
if "$OUT" serve --help >/dev/null 2>&1; then
  PROBE_PORT="${MEMORY_PROBE_PORT:-38731}"
  PROBE_DIR="$(mktemp -d)"
  "$OUT" --data-dir "$PROBE_DIR" serve --port "$PROBE_PORT" \
    >"$PROBE_DIR/serve.log" 2>&1 &
  PROBE_PID=$!

  PROBE_UP=0
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:$PROBE_PORT/health" >/dev/null 2>&1; then
      PROBE_UP=1; break
    fi
    kill -0 "$PROBE_PID" 2>/dev/null || break   # exited early; stop waiting
    sleep 0.5
  done

  PROBE_CODE=000
  if [[ "$PROBE_UP" == "1" ]]; then
    PROBE_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:$PROBE_PORT/api/stats" 2>/dev/null || echo 000)"
  fi
  kill "$PROBE_PID" 2>/dev/null || true
  wait "$PROBE_PID" 2>/dev/null || true

  if [[ "$PROBE_UP" != "1" ]]; then
    # Never pass on silence: a server that will not start on a clean data dir
    # is broken for the app too.
    echo "ERROR: this memory-rs build did not serve /health on a clean data dir."
    echo "       The app could not run it either. Server output:"
    sed 's/^/         /' "$PROBE_DIR/serve.log" | head -n 10
    rm -rf "$PROBE_DIR"
    exit 1
  fi

  rm -rf "$PROBE_DIR"

  # /api/stats EXISTING means this is a pre-v0.4.0 build: the app no longer
  # reads it, no longer sends `kind`/`status`, and expects {deleted: true}
  # from DELETE. Serving the old API to the migrated app is the failure.
  if [[ "$PROBE_CODE" != "404" ]]; then
    echo "ERROR: this memory-rs build still serves /api/stats (pre-v0.4.0)."
    echo "       The app was migrated to the v0.4.0 facts+entities model and"
    echo "       cannot drive the older API. Pin MEMORY_VERSION to v0.4.0 or"
    echo "       later."
    exit 1
  fi
fi
