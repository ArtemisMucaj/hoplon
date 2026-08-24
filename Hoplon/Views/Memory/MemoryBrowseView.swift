import SwiftUI

/// Long-term memory browser, modeled on the memory-rs TUI's Memory screen: a
/// two-pane layout — the memory virtual filesystem tree on the left, the
/// selected row's detail on the right. Browsing (no query) walks the tree;
/// typing a query switches the left pane to ranked search hits. Selecting a
/// node shows its L0 + L1 summary; drilling into a node's L0/L1/L2 level row
/// shows just that level.
struct MemoryBrowseView: View {
    @Environment(AppState.self) var state

    /// All browse state (tree, query, selection) lives on this app-scoped
    /// manager, so it survives leaving/returning to the screen (cache) and can't
    /// be wiped by a status-poll re-render.
    private var browse: MemoryBrowseManager { state.memoryManager.browse }

    var body: some View {
        @Bindable var browse = browse
        VStack(spacing: 0) {
            searchBar
            Divider()
            ResizableSplit(leftIdeal: 420, leftMin: 240, rightMin: 300) {
                MemoryTreePane()
            } right: {
                MemoryDetailPane()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(browse)
        .environment(state.memoryManager)
        // Load from cache on appear (only reloads if inputs changed); load stats
        // once. Reload when the query changes.
        .onAppear {
            browse.loadStatsIfNeeded()
            browse.ensureLoaded(query: browse.query)
        }
        .onChange(of: browse.query) { _, q in browse.ensureLoaded(query: q) }
    }

    private var searchBar: some View {
        @Bindable var browse = browse
        return HStack(spacing: 12) {
            SearchBar(text: $browse.query, prompt: "Search memories…")
            headerMetrics
        }
        .padding(12)
    }

    private var headerMetrics: some View {
        HStack(spacing: 16) {
            metric("Memories", browse.stats?.totalMemories)
            metric("Entities", browse.stats?.totalEntities)
            metric("Sessions", browse.stats?.totalSessions)
        }
    }

    private func metric(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.map { Format.count($0) } ?? "—")
                .font(.callout.weight(.semibold)).monospacedDigit()
            Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// What the detail (right) pane renders for a selected tree node. Kept separate
/// from the tree structure so the detail pane logic is unchanged.
struct MemoryTreeRow: Identifiable, Equatable {
    enum Target {
        case group(title: String)          // a synthetic grouping row (Sessions/Memories)
        case node(MemoryNode)              // a session/digest node (shows L0+L1)
        case level(node: MemoryNode, level: MemoryLevel)
        case memory(Memory)
        case entity(MemoryEntity)
    }
    let id: String
    let target: Target
    var score: Double?

    static func == (lhs: MemoryTreeRow, rhs: MemoryTreeRow) -> Bool { lhs.id == rhs.id }
}

/// A node in the memory tree. Recursive (`children`) so the native `List`
/// renders single-click disclosure triangles. `row` is the detail target when
/// this node is selected; a group with no meaningful detail still carries a
/// `.group` row so the right pane shows a hint.
struct MemoryTreeNode: Identifiable {
    let id: String
    let display: Display
    let row: MemoryTreeRow
    var children: [MemoryTreeNode]?
    var score: Double?

    /// How the row draws itself in the tree.
    enum Display {
        case group(title: String, icon: String, tint: Color, count: Int?)
        case node(MemoryNode)
        case level(MemoryLevel)
        case memory(Memory)
        case entity(MemoryEntity)
    }
}

/// The three memory levels (L0/L1/L2), matching the TUI.
enum MemoryLevel: String, CaseIterable, Identifiable {
    case abstract, overview, detail
    var id: String { rawValue }
    var tag: String {
        switch self {
        case .abstract: return "L0 · Abstract"
        case .overview: return "L1 · Overview"
        case .detail:   return "L2 · Detail"
        }
    }
}

// MARK: - Tree pane (left)

/// The left pane — a thin renderer over `MemoryBrowseManager`. All load state
/// lives on the manager (app-scoped, cached), so this pane holds no @State and
/// can be re-created freely without losing or restarting the load.
private struct MemoryTreePane: View {
    @Environment(MemoryBrowseManager.self) private var browse

    private var searching: Bool { !browse.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        if let error = browse.error {
            EmptyStateView(icon: "exclamationmark.triangle", title: "Couldn't browse memory", message: error)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if browse.nodes.isEmpty && browse.isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading memory…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if browse.nodes.isEmpty {
            EmptyStateView(
                icon: searching ? "sparkle.magnifyingglass" : "brain",
                title: searching ? "No matches" : "No memories",
                message: searching ? "Nothing matched this query." : "Import a session to populate memory."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Native hierarchical List: single-click disclosure triangles for
            // free. Selection is stored on the manager so it survives too.
            @Bindable var browse = browse
            List(browse.nodes, children: \.children, selection: $browse.selectedRowID) { node in
                MemoryNodeRow(node: node)
                    .tag(node.row.id)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Tree row view

/// One tree row, drawn from `node.display`. Disclosure triangles are supplied by
/// the native hierarchical `List`, so this only draws the glyph + label.
private struct MemoryNodeRow: View {
    let node: MemoryTreeNode

    var body: some View {
        HStack(spacing: 8) {
            switch node.display {
            case .group(let title, let icon, let tint, let count):
                glyph(icon, tint)
                Text(title).font(.callout.weight(.medium))
                if let count { CountPill(count) }
            case .node(let n):
                glyph("bubble.left.fill", .cyan)
                // The node's name/uri (a stable label), not its abstract — the
                // abstract belongs in the detail pane.
                Text(n.shortName).lineLimit(1).truncationMode(.middle)
            case .level(let level):
                glyph("arrow.turn.down.right", .secondary, small: true)
                Text(level.tag).font(.callout).foregroundStyle(.green)
            case .memory(let memory):
                glyph("circle.fill", .indigo, tiny: true)
                // Short title in the row; the statement is the tooltip and the
                // detail pane.
                Text(memory.title).lineLimit(1).truncationMode(.tail)
                    .help(memory.statement ?? "")
            case .entity(let entity):
                glyph(entity.icon, .teal, small: true)
                Text(entity.canonicalName).lineLimit(1).truncationMode(.tail)
                Text(entity.entityType)
                    .font(.caption2).foregroundStyle(.tertiary)
                if entity.memoryCount > 0 { CountPill(entity.memoryCount) }
            }
            Spacer()
            if let score = node.score {
                Text(String(format: "%.2f", score))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    /// A fixed-width, centered leading glyph so every row's label starts at the
    /// same x regardless of the icon's intrinsic width.
    @ViewBuilder
    private func glyph(_ name: String, _ tint: Color, small: Bool = false, tiny: Bool = false) -> some View {
        Image(systemName: name)
            .font(tiny ? .system(size: 6) : (small ? .caption2 : .body))
            .foregroundStyle(tint)
            .frame(width: 18, alignment: .center)
    }
}

/// A small count badge shown next to a group title.
private struct CountPill: View {
    let count: Int
    init(_ count: Int) { self.count = count }
    var body: some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

// MARK: - Detail pane (right)

/// The right pane: renders whatever the tree has selected. A node shows its
/// L0 + L1 summary; a level row shows just that level (lazy-loading L2 content
/// when the tree listing didn't carry it); an item shows its content.
struct MemoryDetailPane: View {
    @Environment(MemoryManager.self) private var manager
    @Environment(MemoryBrowseManager.self) private var browse

    var body: some View {
        Group {
            if let row = browse.selectedRow {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detail(for: row)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                EmptyStateView(icon: "sidebar.right", title: "No memory selected",
                               message: "Select a row to read it here.")
            }
        }
        // Both states fill the pane, so the split height doesn't jump between
        // "nothing selected" and reading a memory.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func detail(for row: MemoryTreeRow) -> some View {
        switch row.target {
        case .group(let title):
            Text(title).font(.title3.weight(.semibold))
            Text("Expand to browse — select a child to read it.").foregroundStyle(.secondary)
        case .node(let node):
            nodeSummary(node)
        case .level(let node, let level):
            LevelDetail(node: node, level: level).environment(manager)
        case .memory(let memory):
            MemoryDetail(memory: memory).environment(manager)
        case .entity(let entity):
            EntityDetail(entity: entity).environment(manager)
        }
    }

    /// A node's summary view: L0 + L1 only (drill into the L2 level row for the
    /// full body), matching the TUI.
    @ViewBuilder
    private func nodeSummary(_ node: MemoryNode) -> some View {
        // Use the node's label-aware short name (git remote for project
        // digests), not the raw URI slug — the slug is lossy and reads as noise.
        if node.uri != nil {
            Text(node.shortName).font(.headline)
                .textSelection(.enabled)
        }
        section("L0 · Abstract", node.level0Abstract ?? node.abstract ?? "")
        if let overview = node.level1Overview, !overview.trimmingCharacters(in: .whitespaces).isEmpty {
            section("L1 · Overview", overview)
        }
        // The hint only applies to nodes shown WITH an L2 level row (sessions,
        // resources). Project/digest rollups are leaves — their L2 is internal
        // bookkeeping — so never point at a row that isn't there.
        if node.kind != "project" && node.kind != "memory",
           !(node.level2Content ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Select “L2 · Detail” to read the full content.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func section(_ header: String, _ body: String) -> some View {
        let isEmpty = body.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(header).font(.subheadline.weight(.semibold)).foregroundStyle(.cyan)
                if !isEmpty {
                    CopyButton(text: { body }, help: "Copy \(header)")
                }
                Spacer(minLength: 0)
            }
            if isEmpty {
                Text("(empty)").font(.callout).foregroundStyle(.tertiary)
            } else {
                MarkdownText(body).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// One L0/L1/L2 level's body. L2 content is often absent from a tree listing,
/// so when a Detail level is selected and the node carries no content, fetch the
/// full node by URI on demand.
private struct LevelDetail: View {
    let node: MemoryNode
    let level: MemoryLevel
    @Environment(MemoryManager.self) private var manager

    @State private var resolved: MemoryNode?
    @State private var isLoading = false

    private var effectiveNode: MemoryNode { resolved ?? node }

    private var text: String {
        switch level {
        case .abstract: return effectiveNode.level0Abstract ?? effectiveNode.abstract ?? ""
        case .overview: return effectiveNode.level1Overview ?? ""
        case .detail:   return effectiveNode.level2Content ?? ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(level.tag).font(.subheadline.weight(.semibold)).foregroundStyle(.cyan)
                if !isLoading, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    CopyButton(text: { text }, help: "Copy \(level.tag)")
                }
                Spacer(minLength: 0)
            }
            if isLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
            } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("(empty)").font(.callout).foregroundStyle(.tertiary)
            } else if level == .detail {
                // Full body is often a raw transcript — monospace, selectable.
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            } else {
                MarkdownText(text).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: node.id) { await resolveIfNeeded() }
    }

    /// If the Detail level has no content in the listing, fetch the full node.
    private func resolveIfNeeded() async {
        guard level == .detail,
              (node.level2Content ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
              let uri = node.uri else { return }
        isLoading = true
        resolved = try? await manager.makeClient().node(uri: uri)
        isLoading = false
    }
}

/// The detail pane for one memory: the statement, its metadata, and the
/// entities it mentions.
///
/// A list row already carries the whole memory, but it is re-fetched by id on
/// selection — through the same `.task(id:)` shape `LevelDetail` uses — so the
/// pane shows the stored row rather than a possibly stale list entry.
private struct MemoryDetail: View {
    let memory: Memory
    @Environment(MemoryManager.self) private var manager

    @State private var resolved: Memory?
    @State private var isForgetting = false

    private var effective: Memory { resolved ?? memory }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let kind = effective.kind { Badge(text: kind, color: .indigo) }
                Spacer(minLength: 0)
                CopyButton(text: { effective.statement ?? "" }, help: "Copy statement")
                Button("Forget") { Task { await forget() } }
                    .controlSize(.small)
                    .disabled(isForgetting)
                    .help("Delete this memory. The store no longer keeps a "
                          + "retraction behind it, so this cannot be undone.")
            }

            Text(effective.statement ?? "(no statement)")
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            metadataRow

            entitiesSection
        }
        .task(id: memory.id) { await loadMemory() }
    }

    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: 10) {
            Label(effective.sourceKind.label, systemImage: "person.crop.circle")
            if let c = effective.confidence {
                Label(String(format: "%.2f", c), systemImage: "gauge.medium")
            }
            if let project = effective.project {
                Label(project, systemImage: "folder")
            } else {
                Label("global", systemImage: "globe")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// The entities this fact mentions. With the memory-to-memory edges gone,
    /// these are what relate one memory to another: two facts about the same
    /// entity are the store's only remaining notion of "related".
    @ViewBuilder
    private var entitiesSection: some View {
        let names = effective.entities
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Entities (\(names.count))")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.teal)
                // A ViewThatFits-free wrap: entity counts are small (a fact
                // mentions a handful at most), so a lazy grid that reflows with
                // the pane is simpler than measuring rows by hand.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    ForEach(names, id: \.self) { name in
                        Badge(text: name, color: .teal)
                    }
                }
            }
        }
    }

    private func forget() async {
        isForgetting = true
        defer { isForgetting = false }
        guard (try? await manager.makeClient().forget(memory.id)) == true else { return }
        // Reload through the browse manager so the tree drops the row too —
        // a detail pane that updates while the tree still lists the memory is
        // worse than not updating at all.
        manager.browse.refresh(query: manager.browse.query)
    }

    private func loadMemory() async {
        let client = manager.makeClient()
        guard let shown = try? await client.show(memory.id), shown.type == "memory",
              let m = shown.memory else { return }
        resolved = m
    }
}

/// The detail pane for one entity: what it is, the surface forms attribution
/// has learned, and the memories anchored to it.
private struct EntityDetail: View {
    let entity: MemoryEntity
    @Environment(MemoryManager.self) private var manager

    @State private var memories: [Memory] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: entity.icon).foregroundStyle(.teal)
                Text(entity.canonicalName).font(.title3.weight(.semibold))
                Badge(text: entity.entityType, color: .teal)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Known as").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(entity.names.joined(separator: " · "))
                    .font(.callout).textSelection(.enabled)
                if entity.names.count <= 1 {
                    // Worth stating rather than leaving it looking settled: one
                    // name means no variant has ever resolved here, so variants
                    // may still be landing as separate anchors.
                    Text("No variant has resolved to this yet.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(isLoading ? "Memories" : "Memories (\(memories.count))")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.cyan)
                    if isLoading { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                }
                if let error {
                    // Never report "nothing references this" on a failed load:
                    // an empty state and a broken one look identical to a
                    // reader, and only one of them is true.
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                } else if !isLoading && memories.isEmpty {
                    Text("Nothing references this entity.")
                        .font(.callout).foregroundStyle(.tertiary)
                }
                ForEach(memories) { memory in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(memory.statement ?? memory.id).font(.callout)
                        Text(memory.title).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: entity.id) { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            memories = try await manager.makeClient().entity(entity.id).memories
        } catch {
            memories = []
            self.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

/// A small borderless copy-to-clipboard button that flips to a checkmark for a
/// beat after copying. `text` is a closure so callers can resolve the body
/// lazily at click time.
struct CopyButton: View {
    let text: () -> String
    var help: String = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? .green : .secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
