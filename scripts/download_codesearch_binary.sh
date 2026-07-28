#!/usr/bin/env bash
set -euo pipefail

# Downloads the prebuilt `codesearch` binary
# (https://github.com/ArtemisMucaj/codesearch) into Hoplon/Resources/ so Xcode
# can bundle it.
#
# The app launches `codesearch serve`, which runs BOTH an MCP HTTP server
# (--mcp-port, default 8677) and a REST/JSON management API (--mgmt-port,
# default 8676). CodesearchManager (Services/) supervises the process and drives
# the management API.
#
# NOTE: the app targets the post-extraction codesearch — memory moved out into
# memory-rs, and the LLM stack moved onto openai-rs. That work isn't released
# yet, so the published assets are the wrong shape and this script will install
# a binary whose /api/memory routes collide with the Memory section. Until a
# release ships it, use scripts/build_codesearch_binary.sh.
#
# Override the pin with:
#   CODESEARCH_VERSION=latest bash scripts/download_codesearch_binary.sh

CODESEARCH_VERSION="${CODESEARCH_VERSION:-v1.10.0}"
CODESEARCH_ASSET="${CODESEARCH_ASSET:-codesearch-macos-aarch64}"

source "$(dirname "$0")/lib/fetch_release_asset.sh"
fetch_release_asset "ArtemisMucaj/codesearch" "$CODESEARCH_VERSION" "$CODESEARCH_ASSET" "codesearch"

# Fail closed if the release predates `serve` — release-please bumps Cargo.toml
# at release time, so a post-release merge ships in the *next* tag and a version
# string can match a binary that lacks the subcommand.
OUT="$(cd "$(dirname "$0")/.." && pwd)/Hoplon/Resources/codesearch"
if ! "$OUT" serve --help >/dev/null 2>&1; then
  echo "ERROR: release asset has no 'serve' subcommand — the app cannot use it."
  echo "       Pin CODESEARCH_VERSION to a release that includes serve, or use"
  echo "       scripts/build_codesearch_binary.sh to build from a current checkout."
  exit 1
fi

if "$OUT" --help 2>&1 | grep -qiE '^\s+memory\b'; then
  echo "WARNING: this release still has a 'memory' command — it predates the"
  echo "         extraction into memory-rs. Hoplon drives memory through"
  echo "         memory-rs; the two will fight over the same data."
fi
