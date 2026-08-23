#!/usr/bin/env bash
set -euo pipefail

# Downloads the prebuilt `panoply` binary
# (https://github.com/ArtemisMucaj/panoply) into Hoplon/Resources/ so Xcode can
# bundle it.
#
# Panoply is the MCP proxy: `panoply --http PORT` serves the MCP endpoint at
# /mcp and a REST management API on PORT+1. ProxyManager (Services/) supervises
# the process and drives that API.
#
# The version is pinned so the bundled binary is reproducible. Override with:
#   PANOPLY_VERSION=latest bash scripts/download_panoply_binary.sh

PANOPLY_VERSION="${PANOPLY_VERSION:-v0.2.0}"
PANOPLY_ASSET="${PANOPLY_ASSET:-panoply-macos-aarch64}"

source "$(dirname "$0")/lib/fetch_release_asset.sh"
fetch_release_asset "ArtemisMucaj/panoply" "$PANOPLY_VERSION" "$PANOPLY_ASSET" "panoply"

# Fail closed if the asset predates `--http` — a release tag can match while the
# binary lacks the flag the app launches it with.
OUT="$(cd "$(dirname "$0")/.." && pwd)/Hoplon/Resources/panoply"
if ! "$OUT" --help 2>&1 | grep -q -- "--http"; then
  echo "ERROR: this panoply build has no --http flag; the app cannot use it."
  echo "       Pin PANOPLY_VERSION to a release that includes it, or use"
  echo "       scripts/build_panoply_binary.sh to build from a local checkout."
  exit 1
fi
