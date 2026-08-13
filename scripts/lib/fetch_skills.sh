#!/usr/bin/env bash
# Shared helper: vendor a service's agent skills out of its repo at the exact
# commit a release was cut from, and install them into the app's Resources dir
# so the built .app can write them to ~/.claude/skills with no network.
#
# Skills are NOT release assets — they live in the repo tree under
# `.claude/skills/<name>/SKILL.md`. So "pinned to the release" has to mean the
# release tag's commit, and that commit is what the caller pins.
#
# Fail-closed, in the spirit of fetch_release_asset.sh:
#   - the tag must still resolve to the pinned commit (a moved or re-cut tag
#     aborts rather than vendoring content the shipped binary never saw)
#   - every expected skill must be present, non-empty, and carry frontmatter
#     whose `name:` matches the directory it came from
#
# Usage: fetch_skills <repo> <tag> <commit-sha> <skill-name>...
#   repo        owner/name on GitHub
#   tag         release tag the binary is pinned to (v1.2.3)
#   commit-sha  full 40-char commit that tag must point at
#   skill-name  directory under .claude/skills to vendor (repeatable)
#
# Each skill is installed flat as `Resources/skill-<name>.md`, and recorded in
# `Resources/skills-manifest.json`. Flat because Xcode's synchronized group adds
# every file under Resources/ to Copy Bundle Resources individually — four files
# all named SKILL.md would collide in one directory.
#
# Set SKILLS_SOURCE_DIR to a local checkout's root to vendor from disk instead
# of downloading (the sibling-checkout fallback, and how the scripts are tested).

set -euo pipefail

fetch_skills() {
  local repo="$1" tag="$2" pinned_sha="$3"
  shift 3
  local skills=("$@")

  local repo_root out_dir tmp src_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  out_dir="$repo_root/Hoplon/Resources"
  mkdir -p "$out_dir"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  if [[ -n "${SKILLS_SOURCE_DIR:-}" ]]; then
    # Local checkout: trust the working tree, but say so loudly — nothing here
    # ties it to the release the bundled binary came from.
    [[ -d "$SKILLS_SOURCE_DIR/.claude/skills" ]] || {
      echo "ERROR: no .claude/skills in SKILLS_SOURCE_DIR=$SKILLS_SOURCE_DIR"
      return 1
    }
    echo "==> Vendoring $repo skills from $SKILLS_SOURCE_DIR (local checkout, NOT $tag)"
    src_root="$SKILLS_SOURCE_DIR"
    pinned_sha="$(git -C "$SKILLS_SOURCE_DIR" rev-parse HEAD 2>/dev/null || echo "local")"
    tag="local"
  else
    command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is not installed."; return 1; }
    command -v git  >/dev/null 2>&1 || { echo "ERROR: git is not installed."; return 1; }

    [[ "$pinned_sha" =~ ^[0-9a-f]{40}$ ]] || {
      echo "ERROR: '$pinned_sha' is not a full 40-character commit sha."
      return 1
    }

    # The tag must still point at the commit we pinned. Tags are mutable; a
    # re-cut release would otherwise silently hand us different skill text than
    # the binary in Resources/ was built from.
    echo "==> Resolving $repo $tag"
    local actual_sha
    actual_sha="$(git ls-remote "https://github.com/$repo" "refs/tags/$tag^{}" 2>/dev/null | awk '{print $1}' | head -n1)"
    [[ -n "$actual_sha" ]] || actual_sha="$(git ls-remote "https://github.com/$repo" "refs/tags/$tag" 2>/dev/null | awk '{print $1}' | head -n1)"
    if [[ -z "$actual_sha" ]]; then
      echo "ERROR: could not resolve $tag in $repo."
      return 1
    fi
    if [[ "$actual_sha" != "$pinned_sha" ]]; then
      echo "ERROR: $repo $tag points at $actual_sha, not the pinned $pinned_sha."
      echo "       The tag moved, or the pin is stale. Update the pin after"
      echo "       checking the skills at that commit."
      return 1
    fi
    echo "==> Tag verified at $pinned_sha"

    echo "==> Downloading $repo tree at $pinned_sha"
    if ! curl -fsSL "https://codeload.github.com/$repo/tar.gz/$pinned_sha" -o "$tmp/repo.tar.gz"; then
      echo "ERROR: could not download the $repo tree at $pinned_sha."
      return 1
    fi
    mkdir -p "$tmp/src"
    # The archive has one top-level <repo>-<sha> dir; strip it. Only the skills
    # are extracted — we ship documentation, not somebody's whole source tree.
    if ! tar xzf "$tmp/repo.tar.gz" -C "$tmp/src" --strip-components=1 --wildcards '*/.claude/skills/*' 2>/dev/null; then
      # bsdtar (macOS) has no --wildcards; the pattern works positionally there.
      tar xzf "$tmp/repo.tar.gz" -C "$tmp/src" --strip-components=1 '*/.claude/skills/*'
    fi
    src_root="$tmp/src"
  fi

  local name src dest sum
  local entries=()
  for name in "${skills[@]}"; do
    src="$src_root/.claude/skills/$name/SKILL.md"
    if [[ ! -s "$src" ]]; then
      echo "ERROR: $repo has no non-empty .claude/skills/$name/SKILL.md at $pinned_sha."
      echo "       The pin may predate this skill."
      return 1
    fi
    # A SKILL.md whose frontmatter name disagrees with its directory would
    # install under one name and announce itself as another.
    if ! awk 'NR<=20 && /^name:[[:space:]]*/ {print; exit}' "$src" | grep -q "name:[[:space:]]*$name\$"; then
      echo "ERROR: .claude/skills/$name/SKILL.md has no 'name: $name' in its frontmatter."
      return 1
    fi

    dest="$out_dir/skill-$name.md"
    install -m 0644 "$src" "$dest"
    if command -v shasum >/dev/null 2>&1; then
      sum="$(shasum -a 256 "$dest" | awk '{print $1}')"
    else
      sum="$(sha256sum "$dest" | awk '{print $1}')"
    fi
    echo "==> Vendored $name ($(wc -l <"$dest" | tr -d ' ') lines, sha256 ${sum:0:12}…)"
    entries+=("$name|$sum")
  done

  # Merge into the manifest rather than replacing it: each service's script
  # calls this helper for its own skills only.
  SKILLS_MANIFEST="$out_dir/skills-manifest.json" \
  SKILLS_REPO="$repo" SKILLS_TAG="$tag" SKILLS_COMMIT="$pinned_sha" \
  SKILLS_ENTRIES="$(printf '%s\n' "${entries[@]}")" \
  python3 - <<'PY'
import json, os, pathlib

path = pathlib.Path(os.environ["SKILLS_MANIFEST"])
manifest = {"skills": {}}
if path.exists():
    try:
        manifest = json.loads(path.read_text())
    except ValueError:
        pass  # corrupt manifest: rewrite it rather than failing the fetch
manifest.setdefault("skills", {})

for line in os.environ["SKILLS_ENTRIES"].splitlines():
    if not line.strip():
        continue
    name, sha256 = line.split("|", 1)
    manifest["skills"][name] = {
        "name": name,
        "file": f"skill-{name}.md",
        "repo": os.environ["SKILLS_REPO"],
        "tag": os.environ["SKILLS_TAG"],
        "commit": os.environ["SKILLS_COMMIT"],
        "sha256": sha256,
    }

path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
print(f"==> Manifest: {path} ({len(manifest['skills'])} skill(s))")
PY
}
