#!/usr/bin/env bash
set -euo pipefail

# Vendors memory-rs's agent skills into Hoplon/Resources/ so the app can install
# them into ~/.agents/skills offline.
#
# Pinned to the SAME release as download_memory_binary.sh — see the note there
# and in download_codesearch_skills.sh about why the tag and commit travel
# together.
#
# Vendor from a local checkout instead (unreleased skill edits):
#   SKILLS_SOURCE_DIR=../memory-rs bash scripts/download_memory_skills.sh

MEMORY_SKILLS_TAG="${MEMORY_SKILLS_TAG:-v0.3.1}"
MEMORY_SKILLS_COMMIT="${MEMORY_SKILLS_COMMIT:-a05c78da6420188b6677efc7df6253dc1f5a834f}"

source "$(dirname "$0")/lib/fetch_skills.sh"
fetch_skills "ArtemisMucaj/memory-rs" \
  "$MEMORY_SKILLS_TAG" "$MEMORY_SKILLS_COMMIT" \
  "memory-rs-mcp" "memory-rs-cli"
