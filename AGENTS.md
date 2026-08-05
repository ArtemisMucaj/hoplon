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
| Code Intelligence | `codesearch` | [codesearch](https://github.com/ArtemisMucaj/codesearch) | `--mcp-port` + `--mgmt-port` | Semantic code search, call graphs, Leiden communities + couplings |

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
    CodesearchManager.swift     # codesearch lifecycle + rollup polling
    CodesearchClient.swift      #   async REST + SSE client for codesearch
    FeatureExplainManager.swift # app-scoped streamed call-flow explanations
    GraphLayout.swift           # force-directed layout for the community graph
    MemoryBrowseManager.swift   # app-scoped browse state (cached tree)
    SessionImportManager.swift  # discovered sessions + background-import status
    ProxyRegistration.swift     # the managed `memory` entry in servers.json
  Views/
    RootView.swift         # 2-column split; the always-on sidebar
    SettingsView.swift     # per-service panes (Memory + Code nest sub-panes); live
    MenuBarView.swift
    GuardrailsView.swift
    PresetsView.swift  ServerDetailView.swift
    Proxy/ProxyDetailView.swift
    Memory/                # MemoryDetailView (container), Overview, Browse,
                           #   SessionImport, NamespaceDetail, DreamSettings
    Code/                  # CodeDetailView (container), Overview,
                           #   NamespaceGraph, NamespaceInsight, Llm
    Components/            # DesignSystem.swift, SharedComponents.swift,
                           #   LlmUsagesSection + LlmProviderRow (both LLM panes)
  Resources/               # the four binaries — GITIGNORED, fetched by scripts/
scripts/                   # download (pinned release) + build (sibling checkout) per binary
```

## Build

**Binaries first, always.** `Resources/` is gitignored, so a fresh clone has
none of them and the app builds fine but can't start anything.

```bash
bash scripts/fetch_binaries.sh     # all four; download where possible, build where not
xcodebuild -project Hoplon.xcodeproj -scheme Hoplon -configuration Debug build
```

Per-binary, if you need one in particular:

```bash
bash scripts/download_panoply_binary.sh      # pinned release + SHA-256 verify
bash scripts/download_guardrails_binary.sh
bash scripts/download_codesearch_binary.sh   # pinned release (v2.0.0) + SHA-256 verify
bash scripts/download_memory_binary.sh       # pinned release (v0.2.4) + SHA-256 verify
bash scripts/build_memory_binary.sh          # builds from ../memory-rs (the fallback path)
bash scripts/build_codesearch_binary.sh      # builds from ../codesearch (the fallback path)
bash scripts/build_panoply_binary.sh         # builds from ../panoply
```

All four binaries now ship as pinned release assets, so `fetch_binaries.sh`
downloads each and falls back to a sibling build only if the download fails.
codesearch is pinned to v2.0.0 (the post-extraction build — memory moved to
memory-rs, LLM stack to openai-rs) and memory-rs to v0.2.4. Both download
scripts fail closed if a pin points at an asset that predates the feature the
app drives it with.

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
- **Sidebar/settings row ids must be unique across the whole `List`.** SwiftUI
  keys rows by `ForEach` id, not by section, so two rows sharing an id become
  ONE row — both highlight together and each shows the other's detail. This bit
  twice: `MemoryPane`/`CodePane` both had a `.llm` case whose `id` was the raw
  value, and the sidebar keys proxied servers, memory namespaces and code
  namespaces all by bare name (a repo and a memory namespace can both be
  "platform"). Prefix ids with the owning section — `SidebarRow` in RootView and
  the namespaced `id` on the two pane enums.
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

## Endpoints added to memory-rs for this app

The memory subsystem was extracted from codesearch with its CLI and TUI
surfaces, but not the serve-mode HTTP adapter codesearch had. The domain
capability was all present — the TUI drives it in-process — so what this app
needed was the missing HTTP layer. Added upstream in memory-rs:

| Route | Backs |
|---|---|
| `GET /api/sessions/discover` | the Sessions list (Claude/OpenCode/Zed, newest first) |
| `GET /api/sessions/transcript?source=&id=` | the transcript preview pane |
| `POST /api/sessions/import` | queue a background import (202) |
| `GET /api/sessions/import` | per-session status map for the row markers |
| `GET /api/dream` | the Dream settings pane's status |
| `PUT /api/dream/config` | live+persisted partial settings update |
| `POST /api/dream` | "Dream now" — background trigger, 202 |
| `GET`/`PUT`/`DELETE /api/llm/endpoints[/{name}]` | the Memory ▸ LLM pane |
| `POST /api/llm/active` | bind an endpoint to a role |
| `GET /api/llm/models` | model discovery for the picker |

Discovery is at `/api/sessions/discover`, not `/api/sessions`, because
memory-rs already serves *imported* sessions there — a different set (store
records vs on-disk transcripts).

`POST /api/dream` **changed meaning**: it used to run a cycle synchronously and
return the report; it now starts one in the background and returns 202. A full
consolidation is many minutes of LLM calls — far too long to hold an HTTP
connection. The synchronous path is still the CLI's `memory-rs dream`.

## The two namespace concepts

Memory and Code Intelligence both have "namespaces" and they are **unrelated
sets**: memory-rs namespaces group *projects* so recall spans a multi-repo
effort; codesearch namespaces group *indexed repositories*. `NavigationModel`
keeps them in separate fields (`selectedMemoryNamespace` /
`selectedCodeNamespace`) so drilling into one never cross-selects the other.

## LLM configuration is per-service, on purpose

Each service owns its own endpoints, in its own `config.json`, driven by its own
`/api/llm/*` — codesearch's was already there, memory-rs's was added for this.
Hoplon does **not** inject a shared `OPENAI_*` environment.

That's deliberate: memory and code intelligence often want different backends (a
small local model doing memory extraction, a hosted one answering code
questions), and env vars can't express that. They'd also lose silently — both
services resolve `config.json` named endpoint → `OPENAI_*` env → built-in
default, so any env the app injected would be ignored the moment a named
endpoint existed.

The `OPENAI_*` variables remain the fallback when nothing is registered.

Two wrinkles worth knowing:

- **memory-rs resolves chat and embeddings independently.** `active` is the
  shared default; `active_chat` / `active_embedding` override per role. That's
  what lets a remote chat model pair with local embeddings. codesearch has no
  such split.
- **The embedding dimension is pinned to memory's database on first open.**
  Switching to an embedding model of a different width is rejected at the next
  open, so `GET /api/llm/endpoints` reports the pinned model and the LLM pane
  warns before the store is stranded.

### Both LLM panes have the same shape

`/api/llm/usages` is the whole screen: a row per job, each bound to an explicit
(provider, model) pair, over a list of the registered servers.

- **Nothing is "the active endpoint" in the UI.** The servers still carry an
  `active` (and memory's `active_chat` / `active_embedding`), and that is what
  an unbound job resolves through — but a screen that shows it invites the user
  to set the default *and* the per-job override for the same decision. So the
  list below is inventory: no badge, no radio, no activate button. The only
  place the app writes `active` is silently, on the first endpoint registered,
  so inheritance has somewhere to land.
- **A job's picker always names a model, inherited or not.** The server reports
  what an inherited usage resolves to; the picker selects that, rather than an
  "Inherit" row with the resolved pair spelled out beside it in prose.
- **Model lists are collapsed.** Which model runs a job is settled by the
  pickers, so a server's models are reference material behind a disclosure —
  `LlmProviderRow`. They are still *fetched* eagerly, because the pickers need
  them.
- Job descriptions live in `.help()` tooltips. A settings pane is not a manual.

## Known gaps

- **No app icon.** `Assets.xcassets/AppIcon.appiconset` has the manifest but no
  images; the menu bar falls back to an SF Symbol shield (a *hoplon* is the
  shield a hoplite carried).
