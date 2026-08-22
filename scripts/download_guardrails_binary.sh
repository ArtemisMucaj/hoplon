#!/usr/bin/env bash
set -euo pipefail

# Downloads the prebuilt `guardrail` binary
# (https://github.com/ArtemisMucaj/guardrails) into Hoplon/Resources/ so Xcode
# can bundle it.
#
# Guardrails is a transparent proxy for OpenAI-compatible chat-completions
# servers that repairs malformed tool calls. The app launches it with --listen,
# --admin-listen and --backend; GuardrailsManager (Services/) supervises the
# process and polls the admin server's /healthz, /info, /stats and /activity.
#
# v0.11.0 is the first release carrying the windowed metrics the Guardrails
# screen drives: ?since=/?until= on /stats, and GET /activity for the
# contribution graph. An older pin builds an app whose graph is always empty.
#
# v0.12.0 removed --match-conversations, making the grouping unconditional. The
# app must not pass that flag any more: an unknown flag is a startup error, not
# something clap ignores, so the pin and the launch arguments move together.
#
# The version is pinned so the bundled binary is reproducible. Override with:
#   GUARDRAILS_VERSION=latest bash scripts/download_guardrails_binary.sh

GUARDRAILS_VERSION="${GUARDRAILS_VERSION:-v0.12.0}"
GUARDRAILS_ASSET="${GUARDRAILS_ASSET:-guardrail-macos-aarch64}"

source "$(dirname "$0")/lib/fetch_release_asset.sh"
fetch_release_asset "ArtemisMucaj/guardrails" "$GUARDRAILS_VERSION" "$GUARDRAILS_ASSET" "guardrail"
