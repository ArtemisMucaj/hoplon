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

    /// UI state kept here too so the search text and selection all
    /// survive navigating away and back (not just the loaded tree).
    var query = ""
    /// The selected row's id (resolved back to a row via `selectedRow`).
    var selectedRowID: String?

    /// The query the current `nodes` were built for, so the view can skip
    /// a redundant reload when nothing changed (the cache).
    private(set) var loadedQuery = ""
    /// Whether a browse (non-search) tree has ever been built, so a first visit
    /// loads but return visits reuse the cache.
    private(set) var hasLoaded = false

    @ObservationIgnored private let clientProvider: () -> MemoryClient
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(clientProvider: @escaping () -> MemoryClient) {
        self.clientProvider = clientProvider
    }

    /// Ensure the tree is loaded for `query`. Reuses the cache when the
    /// inputs are unchanged; otherwise (re)loads. Called on appear and on
    /// query changes.
    func ensureLoaded(query: String, force: Bool = false) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !force, hasLoaded, trimmed == loadedQuery, error == nil {
            return
        }
        reload(query: trimmed)
    }

    /// Force a fresh load for the current inputs (the Refresh button).
    func refresh(query: String) {
        reload(query: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Load the header counts once, cached.
    ///
    /// There is no `/api/stats` any more, so these are counted from the list
    /// endpoints — the same three counts `MemoryManager.refreshStats()` keeps
    /// for the Overview. Counted again here rather than read off the manager
    /// because the browser can be opened before the first poll lands, and a
    /// header that is blank until an unrelated timer fires reads as broken.
    func loadStatsIfNeeded() {
        guard stats == nil else { return }
        let client = clientProvider()
        Task {
            async let memories = try? await client.list()
            async let entities = try? await client.entities()
            async let sessions = try? await client.sessions()
            let (m, e, se) = await (memories, entities, sessions)
            // All three or none. Unlike `MemoryManager.refreshStats`, there is
            // no previous value to fall back on here, so a partial result would
            // publish a failed list as a confident "0" — a header reading
            // "0 MEMORIES" over a store full of them. The metric renders "—"
            // while `stats` is nil, which is the honest answer.
            guard let m, let e, let se else { return }
            stats = MemoryStats(totalMemories: m.count,
                                totalEntities: e.count,
                                totalSessions: se.count)
        }
    }

    /// Mark the cache stale *without* clearing what is on screen.
    ///
    /// Distinct from [`reset`]: that one blanks the tree, which is right when
    /// the service stops but wrong after an import — the user is usually
    /// looking at the pane, and emptying it mid-glance reads as data loss. This
    /// reloads in place if the browser is open, and otherwise leaves the next
    /// visit to refetch.
    func invalidate() {
        hasLoaded = false
        if !nodes.isEmpty || isLoading {
            reload(query: loadedQuery)
        }
    }

    /// Drop the cache (e.g. when the service stops) so the next visit reloads.
    func reset() {
        loadTask?.cancel()
        nodes = []; stats = nil; error = nil
        hasLoaded = false; loadedQuery = ""
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

    private func reload(query: String) {
        loadTask?.cancel()
        loadedQuery = query
        let client = clientProvider()
        loadTask = Task {
            if query.isEmpty {
                await loadBrowse(client: client)
            } else {
                await loadSearch(client: client, query: query)
            }
        }
    }

    /// Build the browse tree:
    /// - **Memories** — the whole-memory digest: selecting the group itself
    ///   shows its L0 Abstract + L1 Overview in the detail pane, and its
    ///   children are the memories themselves. There is no per-kind layer any
    ///   more: v0.4.0 collapsed the taxonomy to `fact`, so a subcategory level
    ///   would be one folder called "Facts" holding everything.
    /// - **Projects** — per-project digest nodes, when any exist.
    /// - **Resources** — ingested resource nodes, when any exist.
    /// - **Sessions** — each session node, its L0/L1/L2 nested beneath it.
    private func loadBrowse(client: MemoryClient) async {
        isLoading = true; error = nil
        // Only clear the spinner if this task still owns the load — a superseded
        // reload (fast query change) must not flip `isLoading` off while the
        // newer task is running, which flickered the spinner.
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            async let treeNodes = client.tree(uri: nil)
            async let memoryList = client.list()
            async let projectNodes = client.tree(uri: "memory://projects")
            async let resourceNodes = client.tree(uri: "memory://resources")
            // Advisory: a failing /api/entities must not take the whole tree
            // down with it.
            async let entityList = try? client.entities()
            let (rawNodes, memories, projects, resources) =
                try await (treeNodes, memoryList, projectNodes, resourceNodes)
            let entities = await entityList ?? []
            if Task.isCancelled { return }

            let digest = rawNodes.first { $0.kind == "memory" }
            let sessionNodes = rawNodes.filter { $0.kind != "memory" && !$0.isDirectory }

            // Order: Memories → Projects → Resources → Sessions.
            var groups: [MemoryTreeNode] = []

            // Memories: the group row IS the digest node, so selecting it shows
            // L0/L1 in the detail pane. Children are the memories directly.
            let memoryChildren: [MemoryTreeNode] = memories.map { Self.memoryNode($0) }
            if digest != nil || !memoryChildren.isEmpty {
                let memoryRow: MemoryTreeRow = digest.map {
                    MemoryTreeRow(id: "group:memories", target: .node($0), score: nil)
                } ?? MemoryTreeRow(id: "group:memories", target: .group(title: "Memories"), score: nil)
                groups.append(MemoryTreeNode(
                    id: "group:memories",
                    display: .group(title: "Memories", icon: "brain", tint: .yellow, count: memories.count),
                    row: memoryRow,
                    children: memoryChildren.isEmpty ? nil : memoryChildren
                ))
            }

            // Entities — the anchors memories hang off, and now the only thing
            // relating one memory to another. Placed before Projects because it
            // is part of the memory model rather than a scope over it.
            if !entities.isEmpty {
                groups.append(MemoryTreeNode(
                    id: "group:entities",
                    display: .group(title: "Entities", icon: "at", tint: .teal, count: entities.count),
                    row: MemoryTreeRow(id: "group:entities", target: .group(title: "Entities"), score: nil),
                    children: entities.map(Self.entityNode)
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

    private func loadSearch(client: MemoryClient, query: String) async {
        // Small debounce so live typing doesn't fire a request per keystroke.
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        isLoading = true; error = nil
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let response = try await client.search(query: query)
            if Task.isCancelled { return }
            nodes = response.results.map { Self.memoryNode($0, score: $0.score) }
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

    /// A node with its L0/L1/L2 rows beneath it.
    ///
    /// Only resources still carry all three levels in v0.4.0 — a session node
    /// is now just a `uri`/`kind`/`abstract` triple, so giving it level rows
    /// would hang three permanently empty children off every session.
    private static func nodeTree(_ node: MemoryNode) -> MemoryTreeNode {
        let levels = node.kind == "resource" ? levelChildren(for: node) : []
        return MemoryTreeNode(
            id: node.id,
            display: .node(node),
            row: MemoryTreeRow(id: node.id, target: .node(node), score: nil),
            children: levels.isEmpty ? nil : levels
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

    private static func memoryNode(_ memory: Memory, score: Double? = nil) -> MemoryTreeNode {
        MemoryTreeNode(
            id: "memory:\(memory.id)",
            display: .memory(memory),
            row: MemoryTreeRow(id: "memory:\(memory.id)", target: .memory(memory), score: score),
            children: nil,
            score: score
        )
    }

    private static func entityNode(_ entity: MemoryEntity) -> MemoryTreeNode {
        MemoryTreeNode(
            id: "entity:\(entity.id)",
            display: .entity(entity),
            row: MemoryTreeRow(id: "entity:\(entity.id)", target: .entity(entity), score: nil),
            children: nil
        )
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
