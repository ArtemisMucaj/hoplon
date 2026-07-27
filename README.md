# Hoplon

A native macOS control center for a local agent stack.

Three services run on your machine to make a coding agent better — an MCP proxy
that keeps 200 tools from eating the context window, a repair proxy that fixes
what local models get wrong about tool calls, and a long-term memory store.
Each is a separate binary with its own flags, ports and log file. Hoplon runs
all of them, shows you what they're doing, and gives you one place to change it.

*A hoplon is the round shield a hoplite carried.*

## What it supervises

| | Binary | What it does |
|---|---|---|
| **Proxy** | [`panoply`](https://github.com/ArtemisMucaj/panoply) | Aggregates every MCP server you've configured behind 3 tools. Connect 10 servers and 300 tools; the agent still sees 3. |
| **Guardrails** | [`guardrail`](https://github.com/ArtemisMucaj/guardrails) | Sits between your client and a local OpenAI-compatible server, repairing malformed tool calls instead of letting them fail. |
| **Memory** | [`memory-rs`](https://github.com/ArtemisMucaj/memory-rs) | Imports finished assistant sessions, extracts durable memories, recalls them by hybrid search. |

Code Intelligence ([`codesearch`](https://github.com/ArtemisMucaj/codesearch))
has a placeholder section — it's being reworked upstream and isn't wired up yet.

## What it gives you

- **One window.** Every service's status, endpoints and settings in an always-on
  sidebar, plus a menu bar item with start/stop for each.
- **Live settings.** Change a port and the affected service restarts itself.
  Cross-service port collisions are flagged as you type.
- **A memory browser.** The virtual filesystem (L0 abstract → L1 overview → L2
  full content), hybrid search, and the per-kind breakdown of what's stored.
- **Namespaces.** Group projects so recall spans a multi-repo effort instead of
  stopping at one repository, and search scoped to that group.
- **Session import.** Run a dream cycle to harvest every finished session and
  consolidate the store, or point at a single transcript.
- **Memory wired into the proxy.** Optionally keeps a `memory` entry in the
  proxy's config so agents reach memory tools through the one endpoint. It only
  manages the entry it created — your own config is left alone.

## Build

The three binaries are gitignored, so fetch them before building:

```bash
bash scripts/fetch_binaries.sh
xcodebuild -project Hoplon.xcodeproj -scheme Hoplon -configuration Debug build
```

Downloads are pinned to a release and SHA-256 verified against its manifest.
memory-rs currently has no published assets, so `fetch_binaries.sh` builds it
from a sibling `../memory-rs` checkout — clone it beside this repo, or set
`MEMORY_REPO`.

Requires Xcode 26.2+ and macOS 26.2+.

## Where things live

Each service keeps its own data and logs:

- `~/.panoply/` — `servers.json`, presets, proxy log
- `~/.memory-rs/` — `memory.duckdb`, config, serve log

See [AGENTS.md](AGENTS.md) for architecture and conventions.
