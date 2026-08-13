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
echo "════ agent skills (memory-rs + codesearch) ════"
# Vendored from each service's repo at the pinned release's commit, so the app
# can install them into ~/.agents/skills with no network. Not fatal: a bundle
# without them still runs, the Skills section just reports them missing.
bash "$SCRIPTS/download_memory_skills.sh" || {
  echo "!! skill download failed — falling back to a sibling checkout"
  SKILLS_SOURCE_DIR="${MEMORY_REPO:-$SCRIPTS/../../memory-rs}" \
    bash "$SCRIPTS/download_memory_skills.sh" || echo "!! no memory-rs skills bundled"
}
bash "$SCRIPTS/download_codesearch_skills.sh" || {
  echo "!! skill download failed — falling back to a sibling checkout"
  SKILLS_SOURCE_DIR="${CODESEARCH_REPO:-$SCRIPTS/../../codesearch}" \
    bash "$SCRIPTS/download_codesearch_skills.sh" || echo "!! no codesearch skills bundled"
}

echo
echo "════ done ════"
ls -lh "$SCRIPTS/../Hoplon/Resources/"
