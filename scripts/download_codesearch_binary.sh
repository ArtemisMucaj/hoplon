#!/usr/bin/env bash
set -euo pipefail

# Downloads the prebuilt `codesearch` binary into Hoplon/Resources/.
# build_codesearch_binary.sh is the fallback if the download fails.
#
# v2.0.0+ is the post-extraction build (memory moved to memory-rs); the probes
# below fail closed if a pin points back at an older asset. Pinned to v2.5.0,
# the first release serving DELETE /api/llm/endpoints/{name} — what lets the
# LLM pane remove a configured endpoint instead of only adding and editing.
#
# Override the pin with:
#   CODESEARCH_VERSION=latest bash scripts/download_codesearch_binary.sh

CODESEARCH_VERSION="${CODESEARCH_VERSION:-v2.5.0}"
CODESEARCH_ASSET="${CODESEARCH_ASSET:-codesearch-macos-aarch64}"

source "$(dirname "$0")/lib/fetch_release_asset.sh"
fetch_release_asset "ArtemisMucaj/codesearch" "$CODESEARCH_VERSION" "$CODESEARCH_ASSET" "codesearch"

# Fail closed if the asset predates `serve` (a tag can match a pre-feature build).
OUT="$(cd "$(dirname "$0")/.." && pwd)/Hoplon/Resources/codesearch"
if ! "$OUT" serve --help >/dev/null 2>&1; then
  echo "ERROR: release asset has no 'serve' subcommand — the app cannot use it."
  echo "       Pin CODESEARCH_VERSION to a release with serve, or use"
  echo "       scripts/build_codesearch_binary.sh."
  exit 1
fi

# Fail closed if the asset predates the memory extraction — a `memory` command
# would serve /api/memory and fight memory-rs.
if "$OUT" --help 2>&1 | grep -qiE '^\s+memory\b'; then
  echo "ERROR: this release still has a 'memory' command (pre-extraction)."
  echo "       Pin CODESEARCH_VERSION to v2.0.1 or later."
  exit 1
fi
