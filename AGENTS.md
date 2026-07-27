# AGENTS.md

## What this is

Hoplon is a native macOS control center for a local agent stack. It is **only**
the app — every capability it surfaces comes from a binary built in another
repo, which Hoplon downloads, bundles, supervises, and drives over that
binary's local HTTP API.

There is no business logic here. If a screen can't do something, the answer is
almost always "that service's API doesn't expose it yet", not "add it to Hoplon".

## The services

| Section | Binary | Repo | Ports | What it does |
|---|---|---|---|---|
| Proxy | `panoply` | [panoply](https://github.com/ArtemisMucaj/panoply) | `PORT` (MCP) + `PORT+1` (REST) | Aggregates every configured MCP server behind 3 tools (`load_tools` → `search_tools` → `call_tool`) |
| Guardrails | `guardrail` | [guardrails](https://github.com/ArtemisMucaj/guardrails) | `--listen` + `--admin-listen` | Transparent proxy repairing malformed tool calls from local OpenAI-compatible servers |
| Memory | `memory-rs` | [memory-rs](https://github.com/ArtemisMucaj/memory-rs) | one port: REST **and** MCP at `/mcp` | Long-term memory over imported assistant sessions; hybrid recall |
| Code Intelligence | — | [codesearch](https://github.com/ArtemisMucaj/codesearch) | — | **Not wired up.** Placeholder section while codesearch is reworked upstream |

Memory being a single port is the one thing that breaks the pattern — every
other service takes two. `memory-rs serve --port N` mounts the MCP
streamable-HTTP service onto the same listener as the REST API.

## Layout

```
Hoplon.xcodeproj/          # file-system-synchronized group: no pbxproj edits to add files
Hoplon/
  HoplonApp.swift          # @main, AppDelegate (service lifecycle), MenuBarExtra
  Models/
    AppState.swift         # the one @Observable source of truth; settings, proxy REST calls
    NavigationModel.swift  # sidebar selection ↔ section/sub-tab projection
    MemoryModels.swift     # memory-rs DTOs (lenient, raw-JSON-backed)
    ServerConfig.swift     # servers.json shape
    GuardrailsStats.swift  # admin /stats + /info shapes
    Preset.swift
  Services/                # one supervisor per binary + the clients they hand out
    ProxyManager.swift     #   panoply lifecycle (+ the shared shell-env capture)
    GuardrailsManager.swift
    MemoryManager.swift    #   memory-rs lifecycle; owns browse + import sub-managers
    MemoryClient.swift     #   async REST client for memory-rs
    MemoryBrowseManager.swift   # app-scoped browse state (cached tree)
    SessionImportManager.swift  # app-scoped import/dream state
    ProxyRegistration.swift     # the managed `memory` entry in servers.json
  Views/
    RootView.swift         # 2-column split; the always-on sidebar
    SettingsView.swift     # per-service panes; changes apply live
    MenuBarView.swift
    GuardrailsView.swift
    PresetsView.swift  ServerDetailView.swift
    Proxy/ProxyDetailView.swift
    Memory/                # MemoryDetailView (container), Overview, Browse, Import, NamespaceDetail
    Components/            # DesignSystem.swift, SharedComponents.swift
  Resources/               # the three binaries — GITIGNORED, fetched by scripts/
scripts/                   # download (pinned release) + build (sibling checkout) per binary
```

## Build

**Binaries first, always.** `Resources/` is gitignored, so a fresh clone has
none of them and the app builds fine but can't start anything.

```bash
bash scripts/fetch_binaries.sh     # all three; download where possible, build where not
xcodebuild -project Hoplon.xcodeproj -scheme Hoplon -configuration Debug build
```

Per-binary, if you need one in particular:

```bash
bash scripts/download_panoply_binary.sh      # pinned release + SHA-256 verify
bash scripts/download_guardrails_binary.sh
bash scripts/download_memory_binary.sh       # currently FAILS — see below
bash scripts/build_memory_binary.sh          # builds from ../memory-rs (the working path)
bash scripts/build_panoply_binary.sh         # builds from ../panoply
```

**memory-rs has no release assets.** Its v0.1.0 tag exists but the build job
published nothing, so `download_memory_binary.sh` fails by design (fail-closed:
it will not install an unverified or missing binary). Use
`build_memory_binary.sh` until a release ships assets; `fetch_binaries.sh`
already falls back to it automatically.

The download scripts are deliberately paranoid — they refuse non-macOS assets,
abort on a missing checksum manifest, and probe the binary for the subcommand
the app actually launches it with (`serve`, `--http`). A release tag can match
a binary that predates the feature, because release-please bumps the manifest
at release time and a post-release merge ships in the *next* tag.

## Conventions that matter

- **The Xcode project uses a file-system-synchronized root group.** Drop a
  `.swift` file anywhere under `Hoplon/` and it compiles; drop a binary in
  `Resources/` and it's bundled. Never hand-edit `project.pbxproj` to add files.
- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** is on. Every type is MainActor
  by default, which makes plain `Codable` DTOs MainActor-isolated and produces
  "conformance cannot be used in nonisolated context" warnings (errors in Swift 6)
  the moment `JSONDecoder` touches them off the main actor. Mark pure DTOs
  `nonisolated struct`. The build is warning-clean; keep it that way.
- **Managers own state, views render it.** Browse trees, in-flight imports and
  dream cycles live on `MemoryManager`'s sub-managers, never in `@State`. The
  5s status poll re-renders the detail column, and view-owned load state gets
  wiped by it — that was a real bug in the app this one descends from.
- **Re-entrancy guards are set synchronously.** Every `startBundled()` sets
  `isStarting = true` before any `await`/dispatch. Deferring it lets a second
  call in the same runloop tick spawn a duplicate process that fails to bind and
  flaps the service to "stopped".
- **Process groups, not processes.** `stop()` sends `SIGTERM` to `-pgid` so
  stdio MCP backends panoply spawned don't outlive it.
- **Startup failures get a reason.** Each manager tails its service's log and
  maps the two common ones (DuckDB lock conflict, port in use) to actionable
  text. "It stopped itself" with no explanation is not acceptable UI.

## The managed `memory` proxy entry

When Memory is enabled and "Serve through the proxy" is on, Hoplon writes a
`memory` server into the proxy's `servers.json` pointing at
`http://127.0.0.1:<memoryPort>/mcp`, so agents reach memory tools through the
one proxy endpoint.

`servers.json` is a file the user also owns, so `ProxyRegistration` only ever
touches the entry it created — tagged `[managed by Hoplon]` in its description.
A hand-written `memory` server is left alone (the UI says so, rather than
letting the toggle look broken), and turning the toggle off removes only what
Hoplon added.

## Known gaps

- **No session picker.** memory-rs knows how to discover Claude Code / OpenCode
  / Zed sessions, but only exposes that through the dream harvest — there's no
  REST or MCP endpoint for it. So Import offers a dream cycle (bulk, server-side
  discovery) and a file picker (one transcript). A `GET /api/sessions/discover`
  upstream would let a richer picker slot in.
- **Code Intelligence is inert** until codesearch's rework lands.
- **No app icon.** `Assets.xcassets/AppIcon.appiconset` has the manifest but no
  images; the menu bar falls back to an SF Symbol shield (a *hoplon* is the
  shield a hoplite carried).
