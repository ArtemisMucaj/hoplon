#!/usr/bin/env bash
set -euo pipefail

# Downloads the prebuilt `memory-rs` binary
# (https://github.com/ArtemisMucaj/memory-rs) into Hoplon/Resources/ so Xcode
# can bundle it.
#
# The app launches `memory-rs serve --port PORT`, which runs BOTH a REST/JSON
# management API and an MCP streamable-HTTP endpoint at /mcp on the same port.
# MemoryManager (Services/) supervises the process and drives the REST API.
#
# NOTE: as of memory-rs v0.1.0 the release carries no built assets, so this
# script will fail. Use scripts/build_memory_binary.sh (builds from the sibling
# ../memory-rs checkout) until a release ships binaries.
#
# Override the pin with:
#   MEMORY_VERSION=latest bash scripts/download_memory_binary.sh

MEMORY_VERSION="${MEMORY_VERSION:-v0.1.0}"
MEMORY_ASSET="${MEMORY_ASSET:-memory-rs-macos-aarch64}"

source "$(dirname "$0")/lib/fetch_release_asset.sh"
fetch_release_asset "ArtemisMucaj/memory-rs" "$MEMORY_VERSION" "$MEMORY_ASSET" "memory-rs"

# Fail closed if the asset predates `serve` — release-please bumps Cargo.toml at
# release time, so a post-release merge ships in the *next* tag and a version
# string can match a binary that lacks the subcommand.
OUT="$(cd "$(dirname "$0")/.." && pwd)/Hoplon/Resources/memory-rs"
if ! "$OUT" serve --help >/dev/null 2>&1; then
  echo "ERROR: release asset has no 'serve' subcommand — the app cannot use it."
  echo "       Pin MEMORY_VERSION to a release that includes serve, or use"
  echo "       scripts/build_memory_binary.sh to build from a local checkout."
  exit 1
fi
