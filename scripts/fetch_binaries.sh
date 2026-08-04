#!/usr/bin/env bash
set -euo pipefail

# Puts all four supervised binaries in Hoplon/Resources/ (gitignored), which
# xcodebuild needs before it can produce a working .app. Each downloads from a
# pinned release and falls back to a sibling build only if the download fails.

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
bash "$SCRIPTS/download_codesearch_binary.sh" || {
  echo "!! release download failed — building from sibling checkout"
  bash "$SCRIPTS/build_codesearch_binary.sh"
}

echo
echo "════ done ════"
ls -lh "$SCRIPTS/../Hoplon/Resources/"
