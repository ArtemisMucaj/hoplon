import Foundation
import Observation
import SwiftUI

/// App-scoped state for the memory browser.
///
/// Lives on `MemoryManager` (not in the SwiftUI view) so the built tree + stats
/// **survive navigating away and back** — the view reads a cache instead of
/// reloading every time — and so a status-poll re-render can never wipe the
/// in-flight load (which was the "No memories" twitch: the view owned the state
/// and got re-created every 5s).
///
/// Building the tree from the raw API responses lives here so the view is a
/// thin renderer over `nodes`.
@Observable
@MainActor
final class MemoryBrowseManager {
    /// The current tree (browse groups, or flat search hits).
    var nodes: [MemoryTreeNode] = []
    var stats: MemoryStats?
    var isLoading = false
    var error: String?

    /// UI state kept here too so the search text, kind filter, and selection all
    /// survive navigating away and back (not just the loaded tree).
    var query = ""
    var kind: MemoryKind?
    /// The selected row's id (resolved back to a row via `selectedRow`).
    var selectedRowID: String?

    /// The query + kind the current `nodes` were built for, so the view can skip
    /// a redundant reload when nothing changed (the cache).
    private(set) var loadedQuery = ""
    private(set) var loadedKind: MemoryKind?
    /// Whether a browse (non-search) tree has ever been built, so a first visit
    /// loads but return visits reuse the cache.
    private(set) var hasLoaded = false

    @ObservationIgnored private let clientProvider: () -> MemoryClient
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(clientProvider: @escaping () -> MemoryClient) {
        self.clientProvider = clientProvider
    }

    /// Ensure the tree is loaded for `(query, kind)`. Reuses the cache when the
    /// inputs are unchanged; otherwise (re)loads. Called on appear and on
    /// query/kind changes.
    func ensureLoaded(query: String, kind: MemoryKind?, force: Bool = false) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !force, hasLoaded, trimmed == loadedQuery, kind == loadedKind, error == nil {
            return
        }
        reload(query: trimmed, kind: kind)
    }

    /// Force a fresh load for the current inputs (the Refresh button).
    func refresh(query: String, kind: MemoryKind?) {
        reload(query: query.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)
    }

    /// Load memory stats once (for the header), cached.
    func loadStatsIfNeeded() {
        guard stats == nil else { return }
        Task { stats = try? await clientProvider().stats() }
    }

    /// Drop the cache (e.g. when the service stops) so the next visit reloads.
    func reset() {
        loadTask?.cancel()
        nodes = []; stats = nil; error = nil
        hasLoaded = false; loadedQuery = ""; loadedKind = nil
        selectedRowID = nil
    }

    /// The currently selected detail row, resolved from `selectedRowID`.
    var selectedRow: MemoryTreeRow? {
        guard let id = selectedRowID else { return nil }
        func search(_ list: [MemoryTreeNode]) -> MemoryTreeRow? {
            for n in list {
                if n.row.id == id { return n.row }
                if let kids = n.children, let hit = search(kids) { return hit }
            }
            return nil
        }
        return search(nodes)
    }

    // MARK: - Loading

    private func reload(query: String, kind: MemoryKind?) {
        loadTask?.cancel()
        loadedQuery = query
        loadedKind = kind
        let client = clientProvider()
        loadTask = Task {
            if query.isEmpty {
                await loadBrowse(client: client, kind: kind)
            } else {
                await loadSearch(client: client, query: query, kind: kind)
            }
        }
    }

    /// Build the browse tree:
    /// - **Memories** — the whole-memory digest: selecting the group itself
    ///   shows its L0 Abstract + L1 Overview in the detail pane, and its
    ///   children are the per-kind subcategories (Facts, Skills, …).
    /// - **Projects** — per-project digest nodes, when any exist.
    /// - **Resources** — ingested resource nodes, when any exist.
    /// - **Sessions** — each session node, its L0/L1/L2 nested beneath it.
    private func loadBrowse(client: MemoryClient, kind: MemoryKind?) async {
        isLoading = true; error = nil
        // Only clear the spinner if this task still owns the load — a superseded
        // reload (fast kind/query change) must not flip `isLoading` off while the
        // newer task is running, which flickered the spinner.
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            async let treeNodes = client.tree(uri: nil)
            async let itemList = client.list(kind: kind)
            async let projectNodes = client.tree(uri: "memory://projects")
            async let resourceNodes = client.tree(uri: "memory://resources")
            let (rawNodes, items, projects, resources) =
                try await (treeNodes, itemList, projectNodes, resourceNodes)
            if Task.isCancelled { return }

            let digest = rawNodes.first { $0.kind == "memory" }
            let sessionNodes = rawNodes.filter { $0.kind != "memory" && !$0.isDirectory }

            // Order: Memories → Projects → Resources → Sessions.
            var groups: [MemoryTreeNode] = []

            // Memories: the group row IS the digest node, so selecting it shows
            // L0/L1 in the detail pane. Children are the per-kind subcategories.
            var memoryChildren: [MemoryTreeNode] = []
            let byKind = Dictionary(grouping: items) { MemoryKind(rawValue: $0.kind ?? "") }
            for kindCase in MemoryKind.allCases {
                guard let kindItems = byKind[kindCase], !kindItems.isEmpty else { continue }
                memoryChildren.append(MemoryTreeNode(
                    id: "kind:\(kindCase.rawValue)",
                    display: .group(title: kindCase.label, icon: kindCase.icon, tint: .indigo, count: kindItems.count),
                    row: MemoryTreeRow(id: "kind:\(kindCase.rawValue)", target: .group(title: kindCase.label), score: nil),
                    children: kindItems.map { Self.itemNode($0) }
                ))
            }
            if digest != nil || !memoryChildren.isEmpty {
                let memoryRow: MemoryTreeRow = digest.map {
                    MemoryTreeRow(id: "group:memories", target: .node($0), score: nil)
                } ?? MemoryTreeRow(id: "group:memories", target: .group(title: "Memories"), score: nil)
                groups.append(MemoryTreeNode(
                    id: "group:memories",
                    display: .group(title: "Memories", icon: "brain", tint: .yellow, count: items.count),
                    row: memoryRow,
                    children: memoryChildren.isEmpty ? nil : memoryChildren
                ))
            }

            // Projects — per-project digest nodes. Leaves: selecting one shows
            // its L0/L1 in the detail pane (its L2 is internal bookkeeping).
            if !projects.isEmpty {
                groups.append(MemoryTreeNode(
                    id: "group:projects",
                    display: .group(title: "Projects", icon: "square.stack.3d.up", tint: .orange, count: projects.count),
                    row: MemoryTreeRow(id: "group:projects", target: .group(title: "Projects"), score: nil),
                    children: projects.map(Self.nodeLeaf)
                ))
            }

            // Resources — ingested docs/sites (only when present).
            if !resources.isEmpty {
                groups.append(MemoryTreeNode(
                    id: "group:resources",
                    display: .group(title: "Resources", icon: "books.vertical", tint: .purple, count: resources.count),
                    row: MemoryTreeRow(id: "group:resources", target: .group(title: "Resources"), score: nil),
                    children: resources.map(Self.nodeTree)
                ))
            }

            // Sessions last.
            if !sessionNodes.isEmpty {
                groups.append(MemoryTreeNode(
                    id: "group:sessions",
                    display: .group(title: "Sessions", icon: "bubble.left.and.text.bubble.right",
                                    tint: .cyan, count: sessionNodes.count),
                    row: MemoryTreeRow(id: "group:sessions", target: .group(title: "Sessions"), score: nil),
                    children: sessionNodes.map(Self.nodeTree)
                ))
            }

            if Task.isCancelled { return }
            nodes = groups
            hasLoaded = true
        } catch {
            if Task.isCancelled || Self.isCancellation(error) { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            hasLoaded = true
        }
    }

    private func loadSearch(client: MemoryClient, query: String, kind: MemoryKind?) async {
        // Small debounce so live typing doesn't fire a request per keystroke.
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        isLoading = true; error = nil
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let response = try await client.search(query: query, kind: kind)
            if Task.isCancelled { return }
            nodes = response.results.map { Self.itemNode($0, score: $0.score) }
            hasLoaded = true
        } catch {
            if Task.isCancelled || Self.isCancellation(error) { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            hasLoaded = true
        }
    }

    // MARK: - Node builders

    private static func levelChildren(for node: MemoryNode) -> [MemoryTreeNode] {
        guard let uri = node.uri else { return [] }
        return MemoryLevel.allCases.map { level in
            MemoryTreeNode(
                id: "\(uri)#\(level.rawValue)",
                display: .level(level),
                row: MemoryTreeRow(id: "\(uri)#\(level.rawValue)",
                                   target: .level(node: node, level: level), score: nil),
                children: nil
            )
        }
    }

    private static func nodeTree(_ node: MemoryNode) -> MemoryTreeNode {
        MemoryTreeNode(
            id: node.id,
            display: .node(node),
            row: MemoryTreeRow(id: node.id, target: .node(node), score: nil),
            children: levelChildren(for: node)
        )
    }

    /// A node with no expandable levels — selecting it shows its L0/L1 summary in
    /// the detail pane. Used for project digests, whose L2 is just bookkeeping.
    private static func nodeLeaf(_ node: MemoryNode) -> MemoryTreeNode {
        MemoryTreeNode(
            id: node.id,
            display: .node(node),
            row: MemoryTreeRow(id: node.id, target: .node(node), score: nil),
            children: nil
        )
    }

    private static func itemNode(_ item: MemoryItem, score: Double? = nil) -> MemoryTreeNode {
        MemoryTreeNode(
            id: "item:\(item.id)",
            display: .item(item),
            row: MemoryTreeRow(id: "item:\(item.id)", target: .item(item), score: score),
            children: nil,
            score: score
        )
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
