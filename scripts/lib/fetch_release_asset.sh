#!/usr/bin/env bash
# Shared helper: download one macOS binary from a GitHub Release, verify its
# SHA-256 against the release's checksums manifest, and install it into the
# app's Resources dir.
#
# Sourced by the per-service download scripts. It is deliberately fail-closed:
# a missing manifest or a missing entry for the asset aborts rather than
# installing an unverified executable into a bundle we ship.
#
# Usage: fetch_release_asset <repo> <version> <asset> <install-name>
#   repo         owner/name on GitHub
#   version      a tag (v1.2.3) or the literal "latest"
#   asset        release asset filename (must be a macOS build)
#   install-name filename to install as, under Hoplon/Resources/

set -euo pipefail

fetch_release_asset() {
  local repo="$1" version="$2" asset="$3" install_name="$4"

  command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is not installed."; return 1; }

  # These binaries only ever run inside the macOS .app, so a non-macOS asset
  # would ship a bundle that fails at launch. Reject it here, not at runtime.
  case "$asset" in
    *macos-*|*darwin-*) ;;
    *)
      echo "ERROR: asset '$asset' is not a macOS build."
      echo "       It gets bundled into Hoplon.app; pick a *-macos-* asset."
      return 1
      ;;
  esac

  local repo_root out_dir base tmp
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  out_dir="$repo_root/Hoplon/Resources"
  mkdir -p "$out_dir"

  if [[ "$version" == "latest" ]]; then
    base="https://github.com/$repo/releases/latest/download"
    echo "==> Using latest $repo release"
  else
    base="https://github.com/$repo/releases/download/$version"
    echo "==> Using $repo release $version"
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  echo "==> Downloading $asset"
  if ! curl -fsSL "$base/$asset" -o "$tmp/bin"; then
    echo "ERROR: could not download $asset from $base"
    echo "       The release may exist without built assets yet."
    return 1
  fi

  if ! curl -fsSL "$base/checksums-sha256.txt" -o "$tmp/checksums.txt"; then
    echo "ERROR: could not download checksums-sha256.txt for this release."
    echo "       Refusing to install an unverified binary."
    return 1
  fi

  local expected actual
  expected="$(awk -v a="$asset" '$2 == a || $2 == "*"a {print $1}' "$tmp/checksums.txt" | head -n1)"
  if [[ -z "$expected" ]]; then
    echo "ERROR: no checksum entry for $asset in the release manifest."
    echo "       Refusing to install an unverified binary."
    return 1
  fi

  if command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$tmp/bin" | awk '{print $1}')"
  else
    actual="$(sha256sum "$tmp/bin" | awk '{print $1}')"
  fi

  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: checksum mismatch for $asset"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    return 1
  fi
  echo "==> Checksum verified ($actual)"

  chmod +x "$tmp/bin"
  install -m 0755 "$tmp/bin" "$out_dir/$install_name"

  echo "==> Done. Binary at: $out_dir/$install_name"
  ls -lh "$out_dir/$install_name"
}
