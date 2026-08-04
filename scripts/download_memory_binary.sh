#!/usr/bin/env bash
set -euo pipefail

# Downloads the prebuilt `memory-rs` binary into Hoplon/Resources/.
# build_memory_binary.sh is the fallback if the download fails.
#
# Override the pin with:
#   MEMORY_VERSION=latest bash scripts/download_memory_binary.sh

MEMORY_VERSION="${MEMORY_VERSION:-v0.2.1}"
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
