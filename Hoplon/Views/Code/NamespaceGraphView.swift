import SwiftUI

/// A native force-directed rendering of codesearch's community graph
/// (`GET /api/graph`), the counterpart of the `visualize` CLI's vis-network
/// HTML. Nodes are files (file level) or symbols (symbol level), colored by
/// Leiden community and sized by degree; edges connect coupled nodes. A
/// File/Symbol segmented control switches levels. The layout is simulated in a
/// lightweight spring model (`GraphLayout`) and drawn in a `Canvas`; pan by
/// dragging the background, zoom with the magnify gesture, and hover/click a
/// node to inspect it.
struct NamespaceGraphView: View {
    /// The namespace this view shows. `serve` is bound to a single namespace at
    /// a time, so the view points serve at this one (restarting it if needed)
    /// before loading — otherwise every namespace would render the default
    /// namespace's graph.
    let namespace: String
    /// Repositories in this namespace. The default graph is namespace-wide
    /// (every repo, cross-repo edges); the repo picker filters that graph in
    /// place rather than refetching per repository.
    let repos: [Repository]

    @Environment(AppState.self) private var state

    /// How to color nodes: by Leiden community (default) or by source repository
    /// (only meaningful in the global graph, where nodes are qualified `repo:`).
    enum ColorMode: String, CaseIterable, Identifiable {
        case community, repository
        var id: String { rawValue }
        var label: String { self == .community ? "Community" : "Repository" }
    }

    @State private var level: CommunityLevel = .file
    /// Node coloring; community by default.
    @State private var colorMode: ColorMode = .community
    /// Selected repository. `nil` = All repositories → the namespace-wide global
    /// graph. Otherwise the view shows *that repository's own* Leiden communities
    /// (its per-repo graph, with its own couplings) — a refetch, not a filter.
    /// Holds a repo id (the picker maps name→id) so the fetch is unambiguous.
    @State private var selectedRepo: String?
    @State private var graph: CodeGraph?
    @State private var layout = GraphLayout()
    /// Gate: the graph is revealed only once a full stabilization window has
    /// passed (the loader stays up for the whole window), so it never appears
    /// mid-layout. Reset on every new graph / relayout.
    @State private var graphRevealed = false
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hoveredNode: Int?
    /// A pinned community (from a click) — stays highlighted after the mouse
    /// leaves, until you click empty space or another community. Drives the
    /// inspector. Hover still previews when nothing is selected.
    @State private var selectedCommunity: Int?
    /// Coupling report for the repo (fetched eagerly with the graph), bridged to
    /// graph communities by member path. Nil until loaded.
    @State private var couplings: CouplingReport?
    /// The full graph as fetched (unreduced) — kept so changing detail doesn't
    /// require a refetch.
    @State private var fullGraph: CodeGraph?
    /// Render budget: collapse only the largest communities until the drawn node
    /// count fits, keeping small/medium communities expanded. Higher = more
    /// detail (and slower). The graph shown (`graph`) is `fullGraph` reduced to
    /// this budget. Kept modest so dense repos don't explode into hundreds of
    /// bubbles; slide up for detail.
    @State private var detailBudget: Double = 140

    // Viewport transform (independent of the simulation's world coordinates).
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    /// Last known canvas size — so "Fit" and search-centering can recompute the
    /// transform against the current viewport.
    @State private var canvasSize: CGSize = .zero

    /// Search query for locating a file/symbol in the graph; a live substring
    /// filter over the full graph's node ids/labels.
    @State private var searchText: String = ""
    @State private var showSearchResults = false

    /// The repository labels present in the loaded global graph, for the picker.
    /// Cached (see `repoOrder`) — computing it scans every node, so it must NEVER
    /// be recomputed in the per-node/per-frame draw path (that froze + OOM-crashed
    /// the app on a 12k-node symbol graph when coloring by repository).
    private var graphRepos: [String] { repoOrder }

    /// Cached, computed once per loaded graph: the distinct repositories (busiest
    /// first) and each repo's stable index (drives its color). Recomputed only in
    /// `refreshRepoCache()` when `fullGraph` changes, not on every draw.
    @State private var repoOrder: [String] = []
    @State private var repoIndexByName: [String: Int] = [:]

    /// Whether the loaded graph is namespace-wide (any node carries a repository).
    private var isGlobal: Bool { !repoOrder.isEmpty }

    /// Recompute the cached repo ordering + index from a freshly loaded graph.
    /// This is the ONLY place that scans the full node set for repositories; the
    /// draw path reads the cache. Called once per load.
    private func refreshRepoCache(_ g: CodeGraph?) {
        repoOrder = g?.repositories ?? []
        repoIndexByName = Dictionary(
            uniqueKeysWithValues: repoOrder.enumerated().map { ($1, $0) }
        )
    }

    /// Sentinel tag for the "All repositories" picker entry (an empty string
    /// can't be a real repo label).
    private let allReposTag = "\u{0}all"

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            graphArea
        }
        .task(id: taskKey) { await load() }
        // Re-reduce (no refetch) when the detail budget moves.
        .onChange(of: detailBudget) { _, _ in applyDetail() }
    }

    /// Reduce the fetched full graph to the current detail budget and publish it.
    private func applyDetail() {
        guard let full = fullGraph else { return }
        let reduced = full.levelOfDetail(budget: Int(detailBudget))
        // Publish only a real change: `.task(id: graph)` won't refire on an
        // equal value, so pre-hiding for one would leave the canvas hidden with
        // no reveal task coming.
        guard reduced != graph else { return }
        // Same pre-hide as `load()`: the reveal task fires only after the new
        // graph has rendered a frame, so hide before publishing.
        graphRevealed = false
        graph = reduced
    }

    /// Refetch whenever the namespace, level, or selected repository changes.
    /// "All repositories" (nil) fetches the namespace-wide global graph; a
    /// selected repo fetches that repo's own per-repository graph. The detail
    /// budget reshapes the already-fetched graph in place — no refetch.
    private var taskKey: String { "\(namespace)|\(level.rawValue)|\(selectedRepo ?? "*")" }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Level", selection: $level) {
                Text("Files").tag(CommunityLevel.file)
                Text("Symbols").tag(CommunityLevel.symbol)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Switch between the file-dependency graph and the symbol call graph")

            // Repository picker — "All repositories" shows the namespace-wide
            // global graph; picking one shows *that repository's own* Leiden
            // communities (a refetch of its per-repo graph). Available whenever
            // the namespace holds more than one repo.
            if repos.count > 1 {
                Picker("Repository", selection: Binding(
                    get: { selectedRepo ?? allReposTag },
                    set: { sel in selectedRepo = (sel == allReposTag) ? nil : sel }
                )) {
                    Text("All repositories").tag(allReposTag)
                    Divider()
                    ForEach(repos) { repo in Text(repo.name).tag(repo.id) }
                }
                // Cap the width so a long repo name can't blow the control bar
                // out past the detail pane (which then clips the sidebar).
                .frame(maxWidth: 190)
                .help("All repositories shows the whole namespace; a repository shows its own Leiden communities")
            }

            // Node coloring: by community (default) or by repository. Coloring by
            // repo only makes sense in the multi-repo global (all-repos) graph.
            if selectedRepo == nil, isGlobal, graphRepos.count > 1 {
                Picker("Color", selection: $colorMode) {
                    ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Color nodes by Leiden community or by source repository")
            }

            Spacer()

            if let full = fullGraph, let graph {
                let collapsed = graph.nodes.filter(\.isMeta).count
                // Lead with the repo count in the global graph so its
                // namespace-wide scope is legible at a glance.
                let repoPrefix = isGlobal && graphRepos.count > 1 ? "\(graphRepos.count) repos · " : ""
                Text(collapsed > 0
                     ? "\(repoPrefix)\(Format.count(full.nodes.count)) \(level.noun)s · \(collapsed) grouped"
                     : "\(repoPrefix)\(Format.count(graph.nodes.count)) \(level.noun)s · \(graph.communities.count) communities")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    // Single line, truncating from the tail — and first to shrink
                    // under compression — so it never wraps char-by-char into the
                    // vertical-text glitch when the window is narrow.
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }

            // Detail budget: slide right to expand more communities (more detail,
            // slower); left to collapse big ones into bubbles.
            HStack(spacing: 6) {
                Image(systemName: "circle.grid.2x2").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $detailBudget, in: 80...1200, step: 20) { }
                    .frame(width: 120)
                    .help("Detail: how many nodes to draw before collapsing the largest communities")
                Image(systemName: "circle.grid.3x3.fill").font(.caption2).foregroundStyle(.secondary)
            }

            searchField

            Button { resetViewport() } label: {
                Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Fit the whole graph in view")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    /// Live substring search over the loaded graph's nodes. Picking a result pins
    /// that node's community and centers on it — the only practical way to locate
    /// a specific file/symbol in a large graph.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.secondary)
            TextField("Find file / symbol…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                // Flexible (not fixed 160): the search field is the widest
                // optional control, so let it shrink first when the toolbar is
                // tight rather than push the row past the window edge.
                .frame(minWidth: 90, idealWidth: 160)
                .onChange(of: searchText) { _, v in showSearchResults = !v.isEmpty }
            if !searchText.isEmpty {
                Button { searchText = ""; showSearchResults = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption2)
                }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .popover(isPresented: $showSearchResults, arrowEdge: .bottom) {
            searchResults
        }
    }

    /// Up to 12 nodes matching the query, ranked so exact/prefix matches lead.
    private var searchMatches: [CodeGraphNode] {
        guard let full = fullGraph, !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        return full.nodes
            .filter { $0.id.lowercased().contains(q) || $0.label.lowercased().contains(q) }
            .sorted { a, b in
                func rank(_ n: CodeGraphNode) -> Int {
                    let l = n.label.lowercased()
                    if l == q { return 0 }; if l.hasPrefix(q) { return 1 }; return 2
                }
                return (rank(a), a.label.count) < (rank(b), b.label.count)
            }
            .prefix(12).map { $0 }
    }

    @ViewBuilder
    private var searchResults: some View {
        let matches = searchMatches
        VStack(alignment: .leading, spacing: 0) {
            if matches.isEmpty {
                Text("No matches").font(.caption).foregroundStyle(.secondary).padding(10)
            } else {
                ForEach(matches) { node in
                    Button { locate(node) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(communityColor(node.community, of: (fullGraph?.communities.count ?? 1)))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.label).font(.callout).lineLimit(1)
                                Text(node.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        }
        .frame(width: 300)
        .padding(.vertical, 4)
    }

    /// Pin the matched node's community and center the viewport on it. The node
    /// may be collapsed into a meta-bubble — center on that bubble's position.
    private func locate(_ node: CodeGraphNode) {
        selectedCommunity = node.community
        showSearchResults = false
        // Find where it is in the drawn graph: the node itself if expanded, else
        // the meta-bubble for its community.
        guard let g = graph else { return }
        if let idx = g.nodes.firstIndex(where: { $0.id == node.id })
            ?? g.nodes.firstIndex(where: { $0.community == node.community }) {
            center(on: idx)
        }
    }

    // MARK: - Graph area

    @ViewBuilder
    private var graphArea: some View {
        ZStack {
            if isLoading {
                ProgressView("Building \(level.noun) graph…").controlSize(.large)
            } else if let loadError {
                EmptyStateView(icon: "exclamationmark.triangle", title: "Couldn't load the graph", message: loadError)
            } else if let graph, !graph.nodes.isEmpty {
                // Keep the canvas mounted so the force layout runs, but hide it
                // entirely behind the loader for the full stabilization window —
                // the graph only appears once settled, never mid-wander.
                canvas(for: graph)
                    .opacity(graphRevealed ? 1 : 0)
                    .animation(.easeIn(duration: 0.4), value: graphRevealed)
                    .overlay {
                        if !graphRevealed {
                            VStack(spacing: 10) {
                                ProgressView().controlSize(.large)
                                Text("Stabilizing \(level.noun) graph…")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
            } else {
                EmptyStateView(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "No \(level.noun) graph",
                    message: "Nothing indexed at this level, or the graph is empty."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func canvas(for graph: CodeGraph) -> some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let t = viewportTransform(in: size)
                drawEdges(graph, ctx: &ctx, transform: t)
                drawNodes(graph, ctx: &ctx, transform: t)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .contentShape(Rectangle())
            .gesture(panGesture)
            .gesture(zoomGesture)
            // Click a node to pin its community (toggles off if already pinned);
            // click empty space to clear the selection.
            .onTapGesture(coordinateSpace: .local) { p in
                if let i = nearestNode(to: p, in: geo.size, graph: graph) {
                    let c = graph.nodes[i].community
                    selectedCommunity = (selectedCommunity == c) ? nil : c
                } else {
                    selectedCommunity = nil
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoveredNode = nearestNode(to: p, in: geo.size, graph: graph)
                case .ended: hoveredNode = nil
                }
            }
            .overlay(alignment: .topLeading) { if graphRevealed { inspector(graph) } }
            .overlay(alignment: .bottomLeading) { if graphRevealed { legend(graph) } }
            .onAppear { canvasSize = geo.size }
            .onDisappear { layout.stop() }
            .onChange(of: geo.size) { _, s in canvasSize = s }
            // Start the layout and run the reveal in ONE place, keyed on the
            // graph, so a namespace/repo/level/detail change starts the layout
            // exactly once. (Previously `.onAppear` and `.onChange(of:graph)`
            // both called `layout.start`, double-starting it — which reset node
            // positions mid-draw so edges briefly vanished, and flashed the
            // loader twice.)
            .task(id: graph) {
                canvasSize = geo.size
                // Fresh graph: drop the old viewport so it starts centered.
                zoom = 1; pan = .zero
                layout.start(graph: graph, viewport: geo.size)
                await stabilizeThenReveal(for: graph)
            }
        }
    }

    /// Hide the graph only through its initial chaotic burst, then reveal it
    /// while it's still gently drifting into place — so you watch it settle on
    /// screen rather than waiting for a frozen graph to pop in. The burst is
    /// proportional to what's simulating: a dozen bubbles calm near-instantly,
    /// a thousand-node hairball thrashes for seconds. Sized on the DRAWN
    /// (detail-reduced) graph, since that's what the layout runs on.
    private func stabilizeThenReveal(for graph: CodeGraph) async {
        graphRevealed = false
        // ~2ms per node + ~0.5ms per edge on top of a 400ms floor; capped at 3s
        // so the biggest graphs never feel stuck behind the loader.
        let work = 2 * graph.nodes.count + graph.edges.count / 2
        let ms = min(3000, 400 + work)
        try? await Task.sleep(for: .milliseconds(ms))
        graphRevealed = true
    }

    // MARK: - Drawing

    /// The community currently in focus for the highlight + inspector: the
    /// pinned selection if any, else the hovered node's community. A click pins;
    /// hover only previews while nothing is pinned.
    private func focusedCommunity(_ graph: CodeGraph) -> Int? {
        if let sel = selectedCommunity { return sel }
        guard let i = hoveredNode, i < graph.nodes.count else { return nil }
        return graph.nodes[i].community
    }

    /// Communities the hovered one connects to across a crossing edge — the ones
    /// at the far end of the dotted lines. Kept lit (secondary) on hover so you
    /// see who the community interacts with, not just the community itself.
    private func neighborCommunities(_ graph: CodeGraph, of hot: Int) -> Set<Int> {
        var neighbors = Set<Int>()
        for e in graph.edges where e.source < graph.nodes.count && e.target < graph.nodes.count {
            let sc = graph.nodes[e.source].community, tc = graph.nodes[e.target].community
            if sc == hot && tc != hot { neighbors.insert(tc) }
            else if tc == hot && sc != hot { neighbors.insert(sc) }
        }
        return neighbors
    }

    /// Base bow of an edge away from its straight chord, as a fraction of its
    /// length. Each edge's actual bow varies around this (see `addEdgeCurve`).
    private let edgeCurvature: CGFloat = 0.30

    /// Append `a → b` as a wandering curve rather than a straight segment, so
    /// dense graphs read as organic strands instead of a wire diagram. `seed`
    /// (any stable per-edge value) picks the undulation count (1–3), bow
    /// strength, and starting side — hashed, not positional, so curves never
    /// flicker while the layout settles or the view pans/zooms.
    private func addEdgeCurve(_ path: inout Path, from a: CGPoint, to b: CGPoint, seed: Int) {
        let h = UInt32(truncatingIfNeeded: seed &* 2654435761)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(1, (dx * dx + dy * dy).squareRoot())
        let px = -dy / len, py = dx / len  // unit perpendicular to the chord
        // More wiggles get a smaller amplitude each, so a triple-S edge wanders
        // without overshooting into its neighbors.
        let wiggles = 1 + Int((h >> 4) % 3)
        let amp = edgeCurvature * len * (0.6 + 0.8 * CGFloat(h % 1000) / 1000)
            / CGFloat(wiggles).squareRoot()
        var side: CGFloat = (h & 1) == 0 ? 1 : -1

        // One off-chord control point per undulation, alternating sides, joined
        // as a quadratic spline (joins at control-point midpoints) so the
        // tangent stays continuous — wiggly, never kinked. A single undulation
        // degenerates to the plain one-arc bow.
        var controls: [CGPoint] = []
        for i in 0..<wiggles {
            let t = (2 * CGFloat(i) + 1) / (2 * CGFloat(wiggles))
            controls.append(CGPoint(x: a.x + dx * t + px * amp * side,
                                    y: a.y + dy * t + py * amp * side))
            side = -side
        }
        path.move(to: a)
        for i in 0..<(controls.count - 1) {
            let mid = CGPoint(x: (controls[i].x + controls[i + 1].x) / 2,
                              y: (controls[i].y + controls[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: controls[i])
        }
        path.addQuadCurve(to: b, control: controls[controls.count - 1])
    }

    private func drawEdges(_ graph: CodeGraph, ctx: inout GraphicsContext, transform t: CGAffineTransform) {
        let hot = focusedCommunity(graph)

        // No hover: two flat passes. Links that connect communities — an edge
        // touching a collapsed community bubble, or joining two different
        // communities — are drawn stronger so the inter-community structure
        // reads at a glance; fine intra-community wiring stays subtle.
        guard let hot else {
            var faint = Path(), strong = Path()
            for e in graph.edges {
                guard e.source < layout.positions.count, e.target < layout.positions.count,
                      e.source < graph.nodes.count, e.target < graph.nodes.count else { continue }
                let a = layout.positions[e.source].applying(t)
                let b = layout.positions[e.target].applying(t)
                let sN = graph.nodes[e.source], tN = graph.nodes[e.target]
                let linksCommunities = sN.isMeta || tN.isMeta || sN.community != tN.community
                let seed = e.source &* 31 &+ e.target
                if linksCommunities { addEdgeCurve(&strong, from: a, to: b, seed: seed) }
                else { addEdgeCurve(&faint, from: a, to: b, seed: seed) }
            }
            ctx.stroke(faint, with: .color(.secondary.opacity(0.10)), lineWidth: 0.6)
            ctx.stroke(strong, with: .color(.secondary.opacity(0.30)), lineWidth: 1.0)
            return
        }

        // Hovering: classify each edge relative to the hovered community.
        //  - internal (both endpoints inside): solid, so the community's own
        //    wiring reads as a cohesive block.
        //  - crossing (exactly one endpoint inside): DASHED, marking an external
        //    relationship out of the community.
        //  - unrelated (neither): faded far back.
        // Edges are never recolored — the community highlight lives on the dots.
        var unrelated = Path(), internalE = Path(), crossing = Path()
        for e in graph.edges {
            guard e.source < layout.positions.count, e.target < layout.positions.count,
                  e.source < graph.nodes.count, e.target < graph.nodes.count else { continue }
            let a = layout.positions[e.source].applying(t)
            let b = layout.positions[e.target].applying(t)
            let sIn = graph.nodes[e.source].community == hot
            let tIn = graph.nodes[e.target].community == hot
            let seed = e.source &* 31 &+ e.target
            if sIn && tIn { addEdgeCurve(&internalE, from: a, to: b, seed: seed) }
            else if sIn || tIn { addEdgeCurve(&crossing, from: a, to: b, seed: seed) }
            else { addEdgeCurve(&unrelated, from: a, to: b, seed: seed) }
        }
        ctx.stroke(unrelated, with: .color(.secondary.opacity(0.04)), lineWidth: 0.6)
        ctx.stroke(internalE, with: .color(.secondary.opacity(0.35)), lineWidth: 0.8)
        ctx.stroke(crossing, with: .color(.secondary.opacity(0.40)),
                   style: StrokeStyle(lineWidth: 0.9, dash: [4, 3]))
    }

    /// Only ever label this many nodes at once — beyond a handful the labels
    /// collide into an unreadable pile. Everything else is hover-to-read.
    private let maxLabels = 10

    /// Node indices worth a persistent label: the largest meta-bubbles and the
    /// highest-degree real nodes, capped at `maxLabels`. Hash-only community
    /// names (`s-…` / `c-…`) are skipped — they read as noise; hover shows them.
    private func labeledNodeIndices(_ graph: CodeGraph) -> Set<Int> {
        let ranked = graph.nodes.enumerated()
            .filter { !isHashName($0.element.label) }
            .sorted { lhs, rhs in
                // Rank by member count (meta) then degree, so the biggest structures win.
                (lhs.element.memberCount, lhs.element.degree) > (rhs.element.memberCount, rhs.element.degree)
            }
            .prefix(maxLabels)
            .map(\.offset)
        return Set(ranked)
    }

    /// A community label that's just its opaque id (`s-bc71820cb658`) carries no
    /// meaning — the LLM hasn't named it — so it shouldn't clutter the canvas.
    private func isHashName(_ s: String) -> Bool {
        (s.hasPrefix("s-") || s.hasPrefix("c-") || s.hasPrefix("community-")) &&
        !s.contains(" ") && !s.contains(".")
    }

    private func drawNodes(_ graph: CodeGraph, ctx: inout GraphicsContext, transform t: CGAffineTransform) {
        let maxDeg = max(1, graph.nodes.map(\.degree).max() ?? 1)
        let maxMembers = max(1, graph.nodes.map(\.memberCount).max() ?? 1)
        let z = max(0.5, min(zoomLive, 2.5))
        let toLabel = labeledNodeIndices(graph)
        let hot = focusedCommunity(graph)
        // Communities the hovered one interacts with (far ends of the dotted
        // edges) — kept partly lit so the interaction is visible.
        let neighbors = hot.map { neighborCommunities(graph, of: $0) } ?? []
        for (i, node) in graph.nodes.enumerated() {
            guard i < layout.positions.count else { continue }
            let p = layout.positions[i].applying(t)
            // Collapsed community bubbles are sized by member count and drawn
            // larger with a ring so they read as an aggregate; real nodes by degree.
            let r: CGFloat = node.isMeta
                ? (8 + 16 * CGFloat(node.memberCount) / CGFloat(maxMembers)) * z
                : (3 + 7 * CGFloat(node.degree) / CGFloat(maxDeg)) * z
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            let color = nodeColor(node, in: graph)
            let isHover = hoveredNode == i
            // Three tiers on hover, with a clear hierarchy: the hovered community
            // full, the communities it interacts with distinctly muted (so they
            // read as secondary, not co-equal), everything else faded far back.
            let tierOpacity: Double = {
                guard let hot else { return 1 }
                if node.community == hot { return 1 }
                if neighbors.contains(node.community) { return 0.4 }
                return 0.08
            }()
            let fill: Color = isHover ? .white : color.opacity(node.isMeta ? 0.55 : 1)
            ctx.opacity = tierOpacity
            ctx.fill(Circle().path(in: rect), with: .color(fill))
            ctx.stroke(Circle().path(in: rect), with: .color(color), lineWidth: node.isMeta ? 2.5 : (isHover ? 2 : 0.8))
            ctx.opacity = 1
            // Persistent labels only for the top-ranked nodes (or the hovered one),
            // so labels never pile up. Meta-bubbles show their member count. While
            // hovering, label the hovered community's members AND the neighbors it
            // interacts with, so you can read who's connected.
            let labelWhileHovering = hot != nil &&
                (node.community == hot || neighbors.contains(node.community)) &&
                (node.isMeta || node.degree >= maxDeg / 8)
            if isHover || toLabel.contains(i) || labelWhileHovering {
                let base = isHashName(node.label) ? (node.isMeta ? "community" : node.id) : node.label
                // In the global graph, prefix a hovered real node with its repo
                // (`repo · File.php`) so you can read which repository it's in
                // even while coloring by community.
                let named = (isHover && !node.isMeta), repo = node.repository
                let labeled = (named && repo != nil) ? "\(repo!) · \(base)" : base
                let text = node.isMeta ? "\(base) · \(node.memberCount)" : labeled
                ctx.draw(
                    Text(text).font(.system(size: node.isMeta ? 10 : 9).weight(node.isMeta ? .semibold : .regular))
                        .foregroundStyle(.primary),
                    at: CGPoint(x: p.x, y: p.y - r - 6)
                )
            }
        }
    }

    // MARK: - Overlays

    /// A readable name for a community index (falls back to "Community N" when
    /// the LLM hasn't named it).
    private func communityName(_ graph: CodeGraph, _ index: Int) -> String {
        if let c = graph.communities.first(where: { $0.index == index }), !isHashName(c.name), !c.name.isEmpty {
            return c.name
        }
        return "Community \(index)"
    }

    /// The coupling entry for a community, bridged by member path: a coupling
    /// `community_id` has no direct link to the graph's integer index, but its
    /// members share file/symbol ids with the graph nodes. Crucially the members
    /// come from `fullGraph` (real file/symbol ids), NOT the reduced graph — a
    /// *collapsed* community is a single meta-node whose id is `community-N`, so
    /// matching against the reduced graph would never find the real paths.
    /// Community indices are preserved by `levelOfDetail`, so the index keys both.
    private func couplingFor(community index: Int) -> CommunityCoupling? {
        guard let report = couplings, let source = fullGraph else { return nil }
        let members = Set(source.nodes.filter { $0.community == index }.map(\.id))
        guard !members.isEmpty else { return nil }
        return report.communities.first { cc in
            cc.couplers.contains { $0.elements.contains { members.contains($0) } }
                || cc.subBlockA.contains { members.contains($0) }
                || cc.subBlockB.contains { members.contains($0) }
        }
    }

    /// The top-left inspector: shows the focused (pinned or hovered) community —
    /// its name/size, the communities it's linked to, and its couplings.
    @ViewBuilder
    private func inspector(_ graph: CodeGraph) -> some View {
        if let focus = focusedCommunity(graph) {
            let members = graph.nodes.filter { $0.community == focus }
            let sizeOf: (Int) -> Int = { c in graph.nodes.reduce(0) { $1.community == c ? $0 + 1 : $0 } }
            let neighbors = neighborCommunities(graph, of: focus).sorted { sizeOf($0) > sizeOf($1) }
            let coupling = couplingFor(community: focus)
            VStack(alignment: .leading, spacing: 8) {
                // Header — swatch + name, and a pin/close affordance when pinned.
                HStack(spacing: 6) {
                    Circle().fill(communityColor(focus, of: graph.communities.count)).frame(width: 10, height: 10)
                    Text(communityName(graph, focus)).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if selectedCommunity != nil {
                        Button { selectedCommunity = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Deselect")
                    }
                }
                Text("\(members.count) \(level.noun)s shown\(selectedCommunity == nil ? " · click to pin" : "")")
                    .font(.caption2).foregroundStyle(.secondary)

                // Linked communities — the ones across the dotted edges.
                if !neighbors.isEmpty {
                    Divider()
                    Text("Linked to \(neighbors.count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(neighbors.prefix(6), id: \.self) { nc in
                            Button {
                                selectedCommunity = nc
                            } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(communityColor(nc, of: graph.communities.count)).frame(width: 7, height: 7)
                                    Text(communityName(graph, nc)).font(.caption2).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if neighbors.count > 6 {
                            Text("+\(neighbors.count - 6) more").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }

                // Which repositories this community spans — the key insight of
                // the namespace-wide graph. A community that spans >1 repo is a
                // cross-repository coupling (shared code, a leaky boundary).
                let span = communityRepoSpan(focus)
                if !span.isEmpty {
                    Divider()
                    HStack(spacing: 4) {
                        Text(span.count > 1 ? "Spans \(span.count) repositories" : "Within 1 repository")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        if span.count > 1 {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 8)).foregroundStyle(.orange)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(span, id: \.repo) { entry in
                            // Jump to that repository's own communities.
                            Button { selectRepo(named: entry.repo) } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(repoColor(entry.repo)).frame(width: 7, height: 7)
                                    Text(entry.repo).font(.caption2).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("\(entry.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right.circle").font(.system(size: 8)).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show \(entry.repo)'s own Leiden communities")
                        }
                    }
                }

                // Couplings — the element(s) whose removal would split this
                // community. Namespace-wide, so a coupler is often the shared
                // file/symbol welding two repositories together.
                let coupling = couplingFor(community: focus)
                Divider()
                if couplings == nil {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Analyzing couplings…").font(.caption2).foregroundStyle(.secondary) }
                } else if let coupling, !coupling.couplers.isEmpty {
                    Text("Couplings").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Fragile — removing these splits it into two groups (\(coupling.subBlockA.count) & \(coupling.subBlockB.count)):")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(coupling.couplers.prefix(4).enumerated()), id: \.offset) { _, el in
                        HStack(spacing: 6) {
                            Image(systemName: el.kind == "edge" ? "arrow.left.and.right" : "circle.fill")
                                .font(.system(size: 7)).foregroundStyle(.orange)
                            Text(el.elements.map { couplerLabel($0) }.joined(separator: " ↔ "))
                                .font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 2)
                            Text(String(format: "%.0f%%", el.couplingStrength * 100))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.orange)
                        }
                    }
                } else {
                    Text("No couplings — cohesive community").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: 300, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
    }

    @ViewBuilder
    private func legend(_ graph: CodeGraph) -> some View {
        if colorMode == .repository, isGlobal {
            repoLegend(graph)
        } else {
            communityLegend(graph)
        }
    }

    @ViewBuilder
    private func communityLegend(_ graph: CodeGraph) -> some View {
        // Only the largest communities — a full legend would swamp the canvas.
        let top = graph.communities.sorted { $0.size > $1.size }.prefix(6)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(top)) { c in
                    HStack(spacing: 6) {
                        Circle().fill(communityColor(c.index, of: graph.communities.count)).frame(width: 8, height: 8)
                        Text(c.name).font(.caption2).lineLimit(1)
                        Text("\(c.size)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(12)
        }
    }

    /// Repo legend for the global graph's "color by repository" mode: one swatch
    /// per repository with its node count. Clicking a row filters to that repo
    /// (toggling off if already focused) — the same effect as the toolbar picker.
    @ViewBuilder
    private func repoLegend(_ graph: CodeGraph) -> some View {
        let counts = Dictionary(grouping: graph.nodes.compactMap(\.repository), by: { $0 })
            .mapValues(\.count)
        if !graphRepos.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(graphRepos, id: \.self) { repo in
                    // Click a repo to open its own communities.
                    Button { selectRepo(named: repo) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(repoColor(repo)).frame(width: 8, height: 8)
                            Text(repo).font(.caption2).lineLimit(1)
                            Text("\(counts[repo] ?? 0)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(repo)'s own Leiden communities")
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(12)
        }
    }

    // MARK: - Viewport

    private var zoomLive: CGFloat { zoom * pinch }

    private func viewportTransform(in size: CGSize) -> CGAffineTransform {
        // Layout works in a centered world; map it to the viewport with pan+zoom.
        let dx = pan.width + dragTranslation.width + size.width / 2
        let dy = pan.height + dragTranslation.height + size.height / 2
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: zoomLive, y: zoomLive)
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, s, _ in s = value.translation }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, s, _ in s = value.magnification }
            .onEnded { value in zoom = min(4, max(0.2, zoom * value.magnification)) }
    }

    /// Fit the whole graph: center on its bounding box and scale so it fills the
    /// canvas with margin. The simulation's centroid drifts from origin, so a
    /// plain zoom=1/pan=0 doesn't actually center it — compute the real bounds.
    private func resetViewport() {
        let pts = layout.positions
        guard !pts.isEmpty, canvasSize.width > 0 else {
            withAnimation(.easeOut(duration: 0.2)) { zoom = 1; pan = .zero }
            return
        }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let w = max(1, maxX - minX), h = max(1, maxY - minY)
        let margin: CGFloat = 0.85
        let fitZoom = min(4, max(0.2, min(canvasSize.width / w, canvasSize.height / h) * margin))
        withAnimation(.easeOut(duration: 0.25)) {
            zoom = fitZoom
            // viewportTransform centers world-origin at canvas center; offset the
            // graph centroid back to the middle.
            pan = CGSize(width: -cx * fitZoom, height: -cy * fitZoom)
        }
    }

    /// Center the viewport on a specific node (used by search), keeping zoom.
    private func center(on nodeIndex: Int) {
        guard nodeIndex < layout.positions.count, canvasSize.width > 0 else { return }
        let p = layout.positions[nodeIndex]
        withAnimation(.easeOut(duration: 0.3)) {
            zoom = max(zoom, 1.2)
            pan = CGSize(width: -p.x * zoom, height: -p.y * zoom)
        }
    }

    /// Hit-test: the closest node within a small screen radius, or nil.
    private func nearestNode(to point: CGPoint, in size: CGSize, graph: CodeGraph) -> Int? {
        let t = viewportTransform(in: size)
        var best: Int?
        var bestDist: CGFloat = 14  // px threshold
        for i in graph.nodes.indices where i < layout.positions.count {
            let p = layout.positions[i].applying(t)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    // MARK: - Colors

    /// A stable, well-spread hue per community index (golden-angle spacing),
    /// mirroring how the CLI varies color per community.
    private func communityColor(_ index: Int, of count: Int) -> Color {
        let hue = (Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.62, brightness: 0.85)
    }

    /// Short display for a coupler element id. In the global file graph an id is
    /// `repo:path`, so show `repo · basename` to keep the repository visible;
    /// otherwise (symbol FQNs, per-repo paths) show the trailing component.
    private func couplerLabel(_ id: String) -> String {
        if let colon = id.firstIndex(of: ":") {
            let repo = String(id[..<colon])
            let rest = String(id[id.index(after: colon)...])
            if !repo.isEmpty && !repo.contains("/") {
                return "\(repo) · \((rest as NSString).lastPathComponent)"
            }
        }
        return (id as NSString).lastPathComponent
    }

    /// The repositories a community spans, with each repo's member count,
    /// ordered by count desc. Computed from the FULL graph (real `repo:` node
    /// ids), not the reduced one — a collapsed community is a single meta-bubble
    /// whose id carries no repo. A span of >1 repo is a cross-repository
    /// community; a span of 1 stays within a single repo.
    private func communityRepoSpan(_ index: Int) -> [(repo: String, count: Int)] {
        guard let full = fullGraph else { return [] }
        var counts: [String: Int] = [:]
        for n in full.nodes where n.community == index {
            if let r = n.repository { counts[r, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { (repo: $0.key, count: $0.value) }
    }

    /// The fill color for a node under the current color mode: by community (the
    /// default, keyed on the community index) or by repository (keyed on the
    /// node's `repo:` prefix in the global graph). Meta-bubbles and un-prefixed
    /// nodes fall back to community color even in repo mode, since they aren't
    /// tied to one repository.
    private func nodeColor(_ node: CodeGraphNode, in graph: CodeGraph) -> Color {
        if colorMode == .repository, let repo = node.repository {
            return repoColor(repo)
        }
        return communityColor(node.community, of: graph.communities.count)
    }

    /// A stable, well-spread color per repository label. Indexed by the repo's
    /// cached position (O(1) lookup — this runs once per drawn node per frame, so
    /// it must not scan). Busiest repos get the most separated hues (matching the
    /// legend). Slightly higher saturation than community colors so a handful of
    /// repos read as bold, distinct bands.
    private func repoColor(_ repo: String) -> Color {
        let idx = repoIndexByName[repo] ?? 0
        let hue = (Double(idx) * 0.61803398875).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.72, brightness: 0.9)
    }

    // MARK: - Loading

    /// Select a repository by its display name (as it appears on graph nodes) so
    /// the view refetches that repo's own communities. Falls back to no-op if the
    /// name doesn't resolve to a known repository id.
    private func selectRepo(named name: String) {
        if let id = repos.first(where: { $0.name == name })?.id {
            selectedRepo = id
        }
    }

    private func load() async {
        guard state.codesearchManager.isRunning else { return }
        isLoading = true
        loadError = nil
        selectedCommunity = nil
        couplings = nil
        // Hide the canvas BEFORE the new graph publishes: the canvas remounts a
        // frame or two before its reveal task runs, and a stale `true` here
        // flashed the unsettled graph between the fetch loader and the
        // stabilizing loader.
        graphRevealed = false
        defer { isLoading = false }

        // "All repositories" → the namespace-wide global graph (one Leiden run
        // over every repo, cross-repo edges included). A selected repo → that
        // repository's own per-repo graph and its own communities.
        let global = selectedRepo == nil
        do {
            // Fetch the FULL graph (aggregate=false), then collapse only the
            // largest communities client-side to hit the detail budget — so
            // small/medium communities stay expanded and legible.
            let g = try await state.codesearchManager.makeClient()
                .graph(level: level, repository: selectedRepo, global: global,
                       namespace: global ? namespace : nil, aggregate: false)
            fullGraph = g
            refreshRepoCache(g)   // scan the node set ONCE, here — never in draw
            graph = g.levelOfDetail(budget: Int(detailBudget))
        } catch {
            loadError = error.localizedDescription
            fullGraph = nil
            graph = nil
            refreshRepoCache(nil)
        }
        // Couplings match the scope: namespace-wide for "All repositories" (a
        // coupler is the shared element welding two repos together), or the
        // selected repository's own. Loaded in the background (slowest endpoint)
        // so the graph is interactive immediately.
        let wantKey = taskKey
        Task {
            let report = try? await state.codesearchManager.makeClient()
                .couplings(level: level, repository: selectedRepo, global: global,
                           namespace: global ? namespace : nil)
            if taskKey == wantKey { couplings = report }
        }
    }
}
