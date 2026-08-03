#!/usr/bin/env bash
set -euo pipefail

# Puts all three supervised binaries in Hoplon/Resources/, which is what
# `xcodebuild` needs before it can produce a working .app.
#
# Prefers pinned release downloads; falls back to building from a sibling
# checkout when a release has no usable asset (today: memory-rs). Run this
# before every local build — Resources/ is gitignored, so a fresh clone has
# none of them, and a stale binary is the usual cause of a build that launches
# but can't start a service.

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

echo "════ panoply (MCP proxy) ════"
bash "$SCRIPTS/download_panoply_binary.sh" || {
  echo "!! release download failed — building from sibling checkout"
  bash "$SCRIPTS/build_panoply_binary.sh"
}

echo
echo "════ guardrail (tool-call repair proxy) ════"
bash "$SCRIPTS/download_guardrails_binary.sh"

echo
echo "════ memory-rs (long-term memory) ════"
bash "$SCRIPTS/download_memory_binary.sh" || {
  echo "!! release download failed — building from sibling checkout"
  bash "$SCRIPTS/build_memory_binary.sh"
}

echo
echo "════ codesearch (code intelligence) ════"
# Built from source, not downloaded: the app targets the post-extraction
# codesearch (memory moved to memory-rs) and no release carries that yet.
bash "$SCRIPTS/build_codesearch_binary.sh"

echo
echo "════ done ════"
ls -lh "$SCRIPTS/../Hoplon/Resources/"
