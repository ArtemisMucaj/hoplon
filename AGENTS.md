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
| Guardrails | `guardrail` | [guardrails](https://github.com/ArtemisMucaj/guardrails) | `--listen` + `--admin-listen` | Transparent proxy repairing malformed tool calls; routes to several providers and records token usage |
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
    GuardrailsStats.swift  # admin /stats + /activity + /info shapes
    GuardrailsPeriod.swift # the window every Guardrails figure is computed over
    GuardrailsProviders.swift # management API (/providers) shapes
    SkillModels.swift      # vendored-skill manifest + install marker
    Preset.swift
  Services/                # one supervisor per binary + the clients they hand out
    ProxyManager.swift     #   panoply lifecycle (+ the shared shell-env capture)
    GuardrailsManager.swift
    GuardrailsClient.swift        #   async client for /providers + Copilot login
    GuardrailsProvidersManager.swift # app-scoped provider/login state
    MemoryManager.swift    #   memory-rs lifecycle; owns browse + import sub-managers
    MemoryClient.swift     #   async REST client for memory-rs
    CodesearchManager.swift     # codesearch lifecycle + rollup polling
    CodesearchClient.swift      #   async REST + SSE client for codesearch
    FeatureExplainManager.swift # app-scoped streamed call-flow explanations
    GraphLayout.swift           # force-directed layout for the community graph
    MemoryBrowseManager.swift   # app-scoped browse state (cached tree)
    SessionImportManager.swift  # discovered sessions + background-import status
    ProxyRegistration.swift     # the managed `memory`/`codesearch` servers.json entries
    CliLinkManager.swift        # ~/.local/bin symlinks for the bundled CLIs
    SkillInstallManager.swift   # ~/.agents/skills installs, one variant per service
  Views/
    RootView.swift         # 2-column split; the always-on sidebar
    SettingsView.swift     # per-service panes (Memory + Code nest sub-panes); live
    MenuBarView.swift
    GuardrailsView.swift
    Guardrails/            # GuardrailsProvidersPane (settings ▸ Providers)
    PresetsView.swift  ServerDetailView.swift
    Proxy/ProxyDetailView.swift
    Memory/                # MemoryDetailView (container), Overview, Browse,
                           #   SessionImport, NamespaceDetail, DreamSettings
    Code/                  # CodeDetailView (container), Overview,
                           #   NamespaceGraph, NamespaceInsight, Llm
    Components/            # DesignSystem.swift, SharedComponents.swift,
                           #   LlmUsagesSection + LlmProviderRow (both LLM panes)
  Resources/               # the four binaries + the four vendored skills —
                           #   GITIGNORED, fetched by scripts/
scripts/                   # download (pinned release) + build (sibling checkout) per binary,
                           #   plus the skill vendoring (pinned release commit)
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
bash scripts/download_codesearch_binary.sh   # pinned release (v2.2.0) + SHA-256 verify
bash scripts/download_memory_binary.sh       # pinned release (v0.3.0) + SHA-256 verify
bash scripts/build_memory_binary.sh          # builds from ../memory-rs (the fallback path)
bash scripts/build_codesearch_binary.sh      # builds from ../codesearch (the fallback path)
bash scripts/build_panoply_binary.sh         # builds from ../panoply
bash scripts/download_codesearch_skills.sh   # pinned release COMMIT, vendored into Resources/
bash scripts/download_memory_skills.sh
```

All four binaries now ship as pinned release assets, so `fetch_binaries.sh`
downloads each and falls back to a sibling build only if the download fails.
codesearch is pinned to v2.2.0 (the post-extraction build — memory moved to
memory-rs, LLM stack to openai-rs) and memory-rs to v0.3.0. Both download
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

## Guardrails configuration lives in the proxy, not in the app

`~/.guardrails/config.json` is the source of truth for which providers exist and
which of their models are served. CLI flags only *seed* it on first run; once
the file exists it wins, so the app drives configuration through the management
API (`GET/POST/PATCH/DELETE /providers` on the admin port) rather than by
rebuilding launch arguments.

That is why Settings ▸ Guardrails ▸ Providers mutates over HTTP and re-renders
from the snapshot each call returns: the change applies to the live registry and
is persisted together, so no restart is needed and the UI cannot drift from what
the proxy is doing. The Backend URL field on the Process pane says plainly that
it only seeds the first run.

Conversation grouping is not configurable. guardrails v0.12.0 removed
`--match-conversations` and made it unconditional: Chat Completions is
stateless, so every turn resends the transcript, and counting each resent prefix
again reports the sum of the turns rather than the conversation. The figures
stay marked approximate (`~`, `inferred_conversations`) because the edges are
inferred from message prefixes.

`--copilot` is the one exception that must stay a flag: Copilot needs an OAuth
credential and GitHub's client-identity headers, which no `--backend URL` can
express, so the process has to start knowing about it. Authorization itself is
the device flow on the Providers pane, and the login routes 404 without the flag
— which the pane treats as "not configured" rather than an error.

## The Guardrails screen is windowed

Every figure on the screen is computed over one period, sent as `?since=`/
`?until=` on `/stats`. The contribution graph is the exception: it always spans
`graphDays` regardless of the selection, because it is the control the period is
*picked with* — scoping it to the current selection would leave nothing to click.

The period lives on `GuardrailsManager`, not in view `@State`, for the usual
reason (the 5s poll re-renders the pane and would wipe it).

Two things the server is deliberate about, which the UI preserves:

- **`usage` absent means *not measured*,** not zero. A backend that reports no
  usage still counts as a request; `usage_requests` beside `requests` is what
  separates the two.
- **Deduplicated token figures are marked `~` when approximate.** The proxy
  reports `inferred_conversations` when it inferred conversation edges from
  message prefixes rather than being told them, and presenting a heuristic as
  exact would overstate it.

Days are **UTC**, because that is what the proxy stamps rows in. The graph does
not relabel them locally: shifting the label without shifting the buckets would
misattribute traffic near midnight.

## The managed `memory` and `codesearch` proxy entries

When Memory (or Code Intelligence) is enabled and its "Serve through the MCP
proxy" toggle is on, Hoplon writes a `memory` / `codesearch` server into the
proxy's `servers.json` pointing at that service's MCP endpoint
(`http://127.0.0.1:<memoryPort>/mcp`,
`http://127.0.0.1:<codesearchMcpPort>/mcp`), so agents reach both services'
tools through the one proxy endpoint. Both toggles default ON and both live in
the service's Settings ▸ Process pane under "Agent access".

`servers.json` is a file the user also owns, so `ProxyRegistration` only ever
touches the entry it created — tagged `[managed by Hoplon]` in its description.
A hand-written server of the same name is left alone (the UI says so, rather
than letting the toggle look broken), and turning the toggle off removes only
what Hoplon added.

`ProxyRegistration` is one instance per service (`.memory`, `.codesearch`), and
`AppState.syncMemoryProxyRegistration()` / `syncCodesearchProxyRegistration()`
reconcile them. Each is called from its toggle, the service's start/stop, a port
change (the endpoint embeds the port, so it goes stale otherwise) and once
during init — property observers don't fire there, so a managed entry left over
from a previous run would linger pointing at a dead port.

## Agent skills are vendored, not written here

Settings ▸ CLI & Skills installs the skills that document memory-rs and
codesearch into `~/.agents/skills`. Same rule as everything else in this repo:
the content is upstream's, the app only ships and places it.

`scripts/lib/fetch_skills.sh` vendors `.claude/skills/<name>/SKILL.md` out of
each service's repo into `Hoplon/Resources/skill-<name>.md`, plus a
`skills-manifest.json` recording repo, tag, commit and SHA-256 per skill. The app
installs from its own bundle, so installing needs no network. (Upstream keeps them
under `.claude/skills` — that's the *source* path, and it is not where they land.)

**`~/.agents/skills` is the install target, deliberately not `~/.claude/skills`.**
A skill is plain markdown with frontmatter; nothing about it is specific to one
agent runner, and hard-coding one harness's directory would make the button
useless to the others. panoply already mounts `~/.agents/skills` alongside
`~/.claude/skills` and serves what it finds as MCP resources to any client that
connects with `?skills=true` (see `ProxyDetailView`'s Resources section) — so an
install here reaches every client behind the proxy, plus any harness reading
`.agents` natively. Note the consequence: Claude Code discovers `~/.claude/skills`
on its own, so it picks these up through the proxy rather than from disk.

**Pinned to a commit, not a tag.** Skills are not release assets — they live in
the repo tree — so "the release's skills" has to mean the commit the release tag
pointed at. The scripts pin that commit and abort if the tag has since moved,
because a re-cut tag would otherwise vendor skill text describing a binary that
isn't the one in `Resources/`. Keep `*_SKILLS_TAG` in step with the matching
binary pin; the skill and the binary it documents must come from one release.

**Files are flat in Resources/.** `skill-codesearch-mcp.md`, not
`Skills/codesearch-mcp/SKILL.md`: the synchronized root group adds every file
under `Resources/` to Copy Bundle Resources individually, so four files all named
`SKILL.md` would collide in `Contents/Resources`. A CI step asserts the flat names
are in the built `.app` — the app installs from them, so a silent drop would ship
a Skills section with nothing to install.

**One variant per service, enforced.** Each service publishes an `-mcp` and a
`-cli` skill covering the same capability through different surfaces. Both
installed at once gives the agent two overlapping playbooks for one service, and
it will reach for `codesearch index` in a session where only the MCP tools are
connected. So the picker is three-way (None / MCP / CLI) and selecting one variant
removes the other. The choice is per-service: memory over MCP while codesearch
runs from the CLI is a legitimate setup.

**Only ever touch what we installed.** Every install drops a `.hoplon-skill.json`
marker in the skill directory — the same convention as `[managed by Hoplon]` in
`servers.json`. A hand-authored `~/.agents/skills/codesearch-mcp` is left alone
and reported in the UI instead of being overwritten, and removal deletes only
`SKILL.md` and the marker, keeping the directory if the user has added anything
else to it. The marker also carries what was installed, so a bundle whose skill
has moved on shows "update available" rather than silently drifting.

`codesearch-cli` ships an `install.sh` beside its `SKILL.md` upstream; it is not
vendored. It downloads its own copy of the binary into `INSTALL_DIR`, which would
fight the symlink the pane above it manages, and the SKILL.md line that references
it is a repo-relative path that can't resolve from `~/.agents/skills` anyway. The
`SKILL.md` itself is installed verbatim — what is installed is exactly what the
release shipped.

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

Both are now created **empty** and filled afterward, which is the same shape in
each section: name it, then add projects/repositories from its detail page. For
Code Intelligence that meant a codesearch API addition — the app used to derive
the namespace list by grouping `/api/repositories` by namespace, which cannot
represent a namespace with nothing in it, so creating one had to be a side
effect of indexing a folder. Three codesearch endpoints back the current UI:

| Route | Backs |
|---|---|
| `GET /api/namespaces` | the namespace list, **including empty ones** |
| `POST /api/namespaces` | "New Namespace" (already existed) |
| `DELETE /api/namespaces/{name}` | the trash button on a namespace page |

`CodesearchManager.namespaces` holds the `GET` result and the views union it
with the groups the repositories imply — the union matters because the server
list has no entry for the "—" bucket of unscoped repositories, and the
repository grouping has no entry for an empty namespace.

**The delete cascades.** It removes every repository in the namespace along with
its chunks, embeddings, call graph and cached analyses, so the app confirms with
an `NSAlert` naming the repository count before sending it. An empty namespace
also has no graph to draw, so `CodeDetailView` routes a sidebar selection for one
to the overview's namespace page (which carries "Index Project") instead of
`NamespaceGraphView`.

**The two sections deliberately share one shape**, so neither teaches a flow the
other breaks: a `New Namespace` sheet (same title, same `Create` button), a grid
of clickable squares, and a detail page whose header is back-chevron → name →
primary action → trash. Only the confirmation text differs, because the two
deletes are not the same operation — a memory namespace groups projects, so
removing it destroys nothing, while a code namespace owns its index. The same
trash icon meaning "you lose a grouping" in one section and "you lose hours of
indexing" in the other would be a trap.

## Errors are summarised, not dumped

`ErrorCard` (in `DesignSystem.swift`) renders a service failure as its first line
plus **Show more**, with the full text copyable and the expanded view bounded to
220pt. This exists because a failed index can carry a Node out-of-memory dump —
a GC log plus a native stack trace, hundreds of lines — and rendering that raw
turned the whole pane into a wall of red with the real cause lost inside it.
Prefer it over a bare `Text(error)` for anything a service produced.

## Community naming picks the smallest model

`CodesearchManager.autodetectLlmEndpointIfNeeded` registers a local
OpenAI-compatible server on first run, and then binds the `label_communities`
usage to the **smallest** model that server advertises (parsed from the `<n>b` in
the model id) rather than letting it inherit the active one.

Naming is one LLM call per community — dozens on a real repository — so it wants
the fastest model available. Left to inherit, it lands on the same large model as
everything else, and on a shared local server it also queues behind whatever else
is using it (memory-rs's dream cycle, for one). The size parse is a heuristic: an
id with no parseable size is skipped, and the binding is left alone if none can
be read.

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

- **No dedicated menu bar icon.** The app icon itself is done —
  `Assets.xcassets/AppIcon.appiconset` has all ten macOS sizes and compiles to
  `AppIcon.icns`, so the Dock, Finder and About box are covered. What's missing
  is the separate `MenuBarIcon` asset: `menuBarIcon(dimmed:)` in `HoplonApp.swift`
  looks one up by that name and falls back to an SF Symbol
  `shield`/`shield.fill` when it's absent, which is what currently renders. The
  menu bar needs its own art anyway — a 16pt template image that inverts with
  the menu bar's appearance, not a downscaled full-colour icon. (A *hoplon* is
  the round shield a hoplite carried, hence the glyph.)
