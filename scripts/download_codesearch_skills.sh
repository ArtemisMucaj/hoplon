#!/usr/bin/env bash
set -euo pipefail

# Vendors codesearch's agent skills into Hoplon/Resources/ so the app can install
# them into ~/.agents/skills offline.
#
# Pinned to the SAME release as download_codesearch_binary.sh: a skill that
# documents commands the bundled binary doesn't have is worse than no skill. Keep
# CODESEARCH_SKILLS_TAG in step with CODESEARCH_VERSION there, and the commit in
# step with the tag — the helper aborts if the tag no longer points at it.
#
# Vendor from a local checkout instead (unreleased skill edits):
#   SKILLS_SOURCE_DIR=../codesearch bash scripts/download_codesearch_skills.sh

CODESEARCH_SKILLS_TAG="${CODESEARCH_SKILLS_TAG:-v2.2.0}"
CODESEARCH_SKILLS_COMMIT="${CODESEARCH_SKILLS_COMMIT:-88b6231347880a1ba3677eece8befe29e0505495}"

source "$(dirname "$0")/lib/fetch_skills.sh"
fetch_skills "ArtemisMucaj/codesearch" \
  "$CODESEARCH_SKILLS_TAG" "$CODESEARCH_SKILLS_COMMIT" \
  "codesearch-mcp" "codesearch-cli"
