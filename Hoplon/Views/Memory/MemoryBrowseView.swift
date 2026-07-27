import SwiftUI

/// Long-term memory browser, modeled on the memory-rs TUI's Memory screen: a
/// two-pane layout — the memory virtual filesystem tree on the left, the
/// selected row's detail on the right. Browsing (no query) walks the tree;
/// typing a query switches the left pane to ranked search hits. Selecting a
/// node shows its L0 + L1 summary; drilling into a node's L0/L1/L2 level row
/// shows just that level.
struct MemoryBrowseView: View {
    @Environment(AppState.self) var state

    /// All browse state (tree, query, kind, selection) lives on this app-scoped
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
        // once. Reload when query/kind change.
        .onAppear {
            browse.loadStatsIfNeeded()
            browse.ensureLoaded(query: browse.query, kind: browse.kind)
        }
        .onChange(of: browse.query) { _, q in browse.ensureLoaded(query: q, kind: browse.kind) }
        .onChange(of: browse.kind) { _, k in browse.ensureLoaded(query: browse.query, kind: k) }
    }

    private var searchBar: some View {
        @Bindable var browse = browse
        return HStack(spacing: 12) {
            SearchBar(text: $browse.query, prompt: "Search memories…", accessory: {
                accessory
            })
            headerMetrics
        }
        .padding(12)
    }

    @ViewBuilder
    private var accessory: some View {
        @Bindable var browse = browse
        Picker("Kind", selection: $browse.kind) {
            Text("All kinds").tag(MemoryKind?.none)
            ForEach(MemoryKind.allCases) { k in Text(k.label).tag(MemoryKind?.some(k)) }
        }
        .labelsHidden()
        .frame(maxWidth: 150)
    }

    private var headerMetrics: some View {
        HStack(spacing: 16) {
            metric("Items", browse.stats?.totalItems)
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
        case group(title: String)          // a synthetic grouping row (Sessions/Memories/a kind)
        case node(MemoryNode)              // a session/digest node (shows L0+L1)
        case level(node: MemoryNode, level: MemoryLevel)
        case item(MemoryItem)
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
        case item(MemoryItem)
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
            case .item(let item):
                glyph("circle.fill", .indigo, tiny: true)
                Text(item.name ?? item.body ?? "(memory)").lineLimit(1).truncationMode(.tail)
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
        case .item(let item):
            itemDetail(item)
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

    @ViewBuilder
    private func itemDetail(_ item: MemoryItem) -> some View {
        let body = item.body ?? ""
        HStack(spacing: 8) {
            if let kind = item.kind { Badge(text: kind, color: .indigo) }
            if let name = item.name { Text(name).font(.title3.weight(.semibold)) }
            if !body.isEmpty {
                CopyButton(text: { body }, help: "Copy \(item.name ?? "memory")")
            }
            Spacer(minLength: 0)
        }
        if let project = item.project {
            Text(project).font(.caption).foregroundStyle(.secondary)
        }
        if !body.isEmpty {
            MarkdownText(body).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("This memory has no readable body.").foregroundStyle(.secondary)
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
