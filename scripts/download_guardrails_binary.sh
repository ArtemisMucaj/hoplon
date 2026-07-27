#!/usr/bin/env bash
set -euo pipefail

# Downloads the prebuilt `guardrail` binary
# (https://github.com/ArtemisMucaj/guardrails) into Hoplon/Resources/ so Xcode
# can bundle it.
#
# Guardrails is a transparent proxy for OpenAI-compatible chat-completions
# servers that repairs malformed tool calls. The app launches it with --listen,
# --admin-listen and --backend; GuardrailsManager (Services/) supervises the
# process and polls the admin server's /healthz, /info and /stats.
#
# The version is pinned so the bundled binary is reproducible. Override with:
#   GUARDRAILS_VERSION=latest bash scripts/download_guardrails_binary.sh

GUARDRAILS_VERSION="${GUARDRAILS_VERSION:-v0.8.1}"
GUARDRAILS_ASSET="${GUARDRAILS_ASSET:-guardrail-macos-aarch64}"

source "$(dirname "$0")/lib/fetch_release_asset.sh"
fetch_release_asset "ArtemisMucaj/guardrails" "$GUARDRAILS_VERSION" "$GUARDRAILS_ASSET" "guardrail"
