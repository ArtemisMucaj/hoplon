import Foundation

// Codable models for the `codesearch serve` management API. Decoding is
// deliberately lenient — many nested domain shapes are `additionalProperties:
// true`, so we model the documented top-level fields and fall back to defaults
// for anything missing, mirroring the pattern in GuardrailsStats.swift.
//
// The memory / dream / session-import shapes that used to live here moved to
// memory-rs; see MemoryModels.swift and SessionModels.swift. The `lenient`
// decoding helper is declared once in SessionModels.swift.
// MARK: - Meta

/// `GET /health` → `{ "status": "ok", "version": "1.3.0" }`.
struct CodesearchHealth: Codable, Equatable {
    var status: String
    var version: String
}

/// `GET /api/stats` — index-wide rollup.
struct CodesearchStats: Codable, Equatable {
    var repositories: Int
    var totalFiles: Int
    var totalChunks: Int
    var dataDir: String
    var namespace: String?

    enum CodingKeys: String, CodingKey {
        case repositories
        case totalFiles = "total_files"
        case totalChunks = "total_chunks"
        case dataDir = "data_dir"
        case namespace
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repositories = (try? c.decode(Int.self, forKey: .repositories)) ?? 0
        totalFiles   = (try? c.decode(Int.self, forKey: .totalFiles)) ?? 0
        totalChunks  = (try? c.decode(Int.self, forKey: .totalChunks)) ?? 0
        dataDir      = (try? c.decode(String.self, forKey: .dataDir)) ?? ""
        namespace    = try? c.decode(String.self, forKey: .namespace)
    }
}

// MARK: - Repositories

struct LanguageStat: Codable, Equatable {
    var fileCount: Int
    enum CodingKeys: String, CodingKey { case fileCount = "file_count" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileCount = (try? c.decode(Int.self, forKey: .fileCount)) ?? 0
    }
}

struct Repository: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var path: String
    var fileCount: Int
    var chunkCount: Int
    var store: String
    var namespace: String?
    var languages: [String: LanguageStat]

    enum CodingKeys: String, CodingKey {
        case id, name, path, store, namespace, languages
        case fileCount = "file_count"
        case chunkCount = "chunk_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name       = (try? c.decode(String.self, forKey: .name)) ?? "(unnamed)"
        path       = (try? c.decode(String.self, forKey: .path)) ?? ""
        store      = (try? c.decode(String.self, forKey: .store)) ?? ""
        namespace  = try? c.decode(String.self, forKey: .namespace)
        fileCount  = (try? c.decode(Int.self, forKey: .fileCount)) ?? 0
        chunkCount = (try? c.decode(Int.self, forKey: .chunkCount)) ?? 0
        languages  = (try? c.decode([String: LanguageStat].self, forKey: .languages)) ?? [:]
    }

    /// Languages sorted by descending file count, for compact display.
    var sortedLanguages: [(language: String, fileCount: Int)] {
        languages
            .map { (language: $0.key, fileCount: $0.value.fileCount) }
            .sorted { $0.fileCount > $1.fileCount }
    }
}

struct RepositoriesResponse: Codable {
    var repositories: [Repository]
}

/// `GET /api/repositories/{id}` — a repository plus a best-effort Markdown
/// architecture overview (empty when the repo has no call graph). The overview
/// is merged into the same object as the repository fields, so decode both from
/// one container.
struct RepositoryDetail: Codable, Equatable {
    var repository: Repository
    var architectureOverview: String

    private enum OverviewKey: String, CodingKey { case architectureOverview = "architecture_overview" }

    init(from decoder: Decoder) throws {
        repository = try Repository(from: decoder)
        let c = try decoder.container(keyedBy: OverviewKey.self)
        architectureOverview = (try? c.decode(String.self, forKey: .architectureOverview)) ?? ""
    }
}

// MARK: - Search

struct SearchRequest: Codable {
    var query: String
    var limit: Int = 10
    var minScore: Double?
    var languages: [String]?
    var repositories: [String]?
    var textSearch: Bool = true

    enum CodingKeys: String, CodingKey {
        case query, limit, languages, repositories
        case minScore = "min_score"
        case textSearch = "text_search"
    }
}

struct SearchResponse: Codable {
    var count: Int
    var results: [SearchHit]
}

struct SearchHit: Codable, Equatable, Identifiable {
    var filePath: String
    var startLine: Int
    var endLine: Int
    var score: Double
    var language: String
    var nodeType: String
    var symbolName: String?
    var content: String

    var id: String { "\(filePath):\(startLine)-\(endLine)" }

    enum CodingKeys: String, CodingKey {
        case score, language, content
        case filePath = "file_path"
        case startLine = "start_line"
        case endLine = "end_line"
        case nodeType = "node_type"
        case symbolName = "symbol_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filePath   = (try? c.decode(String.self, forKey: .filePath)) ?? ""
        startLine  = (try? c.decode(Int.self, forKey: .startLine)) ?? 0
        endLine    = (try? c.decode(Int.self, forKey: .endLine)) ?? 0
        score      = (try? c.decode(Double.self, forKey: .score)) ?? 0
        language   = (try? c.decode(String.self, forKey: .language)) ?? ""
        nodeType   = (try? c.decode(String.self, forKey: .nodeType)) ?? ""
        symbolName = try? c.decode(String.self, forKey: .symbolName)
        content    = (try? c.decode(String.self, forKey: .content)) ?? ""
    }

    /// Just the file name, for compact headers.
    var fileName: String { (filePath as NSString).lastPathComponent }
    var lineRange: String { startLine == endLine ? "\(startLine)" : "\(startLine)–\(endLine)" }
}

// MARK: - Copilot device-flow login

/// `GET`/`POST /api/llm/copilot/login` — the state of a GitHub Copilot device
/// flow. The server drives it: the app starts it, shows the code, opens the
/// browser, and polls until authorized/failed.
struct CopilotLoginStatus: Decodable, Equatable {
    enum State: String { case idle, pending, authorized, failed }

    var state: State
    /// Present while `pending`: the code the user types at `verificationUri`.
    var userCode: String?
    var verificationUri: String?
    /// Present on `failed`.
    var error: String?

    enum CodingKeys: String, CodingKey {
        case status, error
        case userCode = "user_code"
        case verificationUri = "verification_uri"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decode(String.self, forKey: .status)) ?? "idle"
        state = State(rawValue: raw) ?? .idle
        userCode = try? c.decode(String.self, forKey: .userCode)
        verificationUri = try? c.decode(String.self, forKey: .verificationUri)
        error = try? c.decode(String.self, forKey: .error)
    }
}

// MARK: - Communities (clusters / symbol-clusters)

/// Which graph a community/coupling analysis ran on. Mirrors the server's
/// `GraphLevel` (`file` | `symbol`).
enum CommunityLevel: String, CaseIterable, Identifiable, Codable {
    case file, symbol
    var id: String { rawValue }
    var label: String { self == .file ? "Files" : "Symbols" }
    /// Noun for the nodes at this level, for counts ("12 files" / "12 symbols").
    var noun: String { rawValue }
}

extension String {
    /// LLM community names read like prose titles ("Migration And Api Setup").
    /// Tighten the connective to "&" for display, so pills and legends stay
    /// short and the name reads as one unit. Decode-time only — ids and raw
    /// API payloads are untouched.
    var tightenedCommunityName: String {
        replacingOccurrences(of: " And ", with: " & ")
    }
}

/// One Leiden community — a file-dependency cluster (`GET /api/clusters`) or a
/// symbol call-graph community (`GET /api/symbol-clusters`). Both endpoints
/// return the same per-community shape, so one model covers both.
struct Community: Codable, Equatable, Identifiable {
    var id: String
    /// LLM-generated human-readable name; `nil` until the server has generated
    /// one (or when no LLM is configured). Show `label` instead of unwrapping.
    var displayName: String?
    var dominantLanguage: String
    var size: Int
    /// `internal_edges / (internal_edges + external_edges)` — 1.0 is fully
    /// self-contained.
    var cohesion: Double
    /// File paths (file level) or fully-qualified symbol names (symbol level).
    var members: [String]

    enum CodingKeys: String, CodingKey {
        case id, size, cohesion, members
        case displayName = "display_name"
        case dominantLanguage = "dominant_language"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = c.lenient(String.self, .id, or: UUID().uuidString)
        displayName      = (try? c.decode(String.self, forKey: .displayName))?.tightenedCommunityName
        dominantLanguage = c.lenient(String.self, .dominantLanguage, or: "")
        size             = c.lenient(Int.self, .size, or: 0)
        cohesion         = c.lenient(Double.self, .cohesion, or: 0)
        members          = c.lenient([String].self, .members, or: [])
    }

    /// The user-facing name: the LLM display name when generated, else the
    /// stable id — mirroring the server's `community_label`.
    var label: String { displayName ?? id }
}

/// Both cluster endpoints, normalized: `clusters`/`communities` and
/// `total_files`/`total_symbols` fold into common fields so one view renders
/// either level.
struct CommunityGraph: Codable, Equatable {
    var communities: [Community]
    var totalNodes: Int
    var totalEdges: Int

    enum CodingKeys: String, CodingKey {
        case clusters, communities
        case totalFiles = "total_files"
        case totalSymbols = "total_symbols"
        case totalEdges = "total_edges"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        communities = (try? c.decode([Community].self, forKey: .clusters))
            ?? (try? c.decode([Community].self, forKey: .communities)) ?? []
        totalNodes = (try? c.decode(Int.self, forKey: .totalFiles))
            ?? (try? c.decode(Int.self, forKey: .totalSymbols)) ?? 0
        totalEdges = (try? c.decode(Int.self, forKey: .totalEdges)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(communities, forKey: .communities)
        try c.encode(totalNodes, forKey: .totalSymbols)
        try c.encode(totalEdges, forKey: .totalEdges)
    }
}

// MARK: - Render-ready community graph (GET /api/graph)

/// The render-ready graph the server builds for the `visualize` output: nodes
/// grouped into Leiden communities, connected by weighted edges. Unlike
/// `CommunityGraph` (membership only) this carries the edge adjacency, so the
/// app can draw the force-directed graph itself. Mirrors the server's
/// `GraphView`.
struct CodeGraph: Codable, Equatable {
    var repositoryId: String
    var level: CommunityLevel
    var nodes: [CodeGraphNode]
    var edges: [CodeGraphEdge]
    var communities: [CodeGraphCommunity]

    enum CodingKeys: String, CodingKey {
        case level, nodes, edges, communities
        case repositoryId = "repository_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repositoryId = c.lenient(String.self, .repositoryId, or: "")
        level        = (try? c.decode(CommunityLevel.self, forKey: .level)) ?? .file
        nodes        = c.lenient([CodeGraphNode].self, .nodes, or: [])
        edges        = c.lenient([CodeGraphEdge].self, .edges, or: [])
        communities  = c.lenient([CodeGraphCommunity].self, .communities, or: [])
    }

    init(repositoryId: String, level: CommunityLevel, nodes: [CodeGraphNode], edges: [CodeGraphEdge], communities: [CodeGraphCommunity]) {
        self.repositoryId = repositoryId; self.level = level
        self.nodes = nodes; self.edges = edges; self.communities = communities
    }

    /// A level-of-detail view: collapse the **largest** communities (biggest
    /// contributors to a hairball) into single meta-bubbles until the total
    /// drawn node count drops to `budget`, keeping small/medium communities
    /// expanded so their structure stays visible. Node→node edges survive;
    /// edges touching a collapsed community are rewired to its meta-node and
    /// deduped (weights summed). Returns `self` unchanged when already under
    /// budget.
    func levelOfDetail(budget: Int) -> CodeGraph {
        guard nodes.count > budget else { return self }

        // Members per community, largest first — collapse from the top until the
        // projected node count fits: (kept individual nodes) + (1 per collapsed).
        var membersByCommunity: [Int: [Int]] = [:]  // community → node indices
        for (i, n) in nodes.enumerated() { membersByCommunity[n.community, default: []].append(i) }
        let bySize = membersByCommunity.sorted { $0.value.count > $1.value.count }

        var collapsed = Set<Int>()          // community indices we fold into a bubble
        var projected = nodes.count
        for (community, members) in bySize {
            if projected <= budget { break }
            guard members.count > 1 else { continue }  // singletons can't shrink
            collapsed.insert(community)
            projected -= (members.count - 1)           // members → 1 bubble
        }
        // If a repo is so fragmented that collapsing every multi-member community
        // still overshoots (hundreds of tiny communities), collapse *all* of them
        // so the view is bubbles + loose singletons, not a wall of nodes. Below
        // the community count we can't reduce further without merging communities.
        guard !collapsed.isEmpty else { return self }

        // Build the reduced node set: expanded members keep their identity; each
        // collapsed community contributes one meta-node. Track index remapping.
        let communityMeta = Dictionary(uniqueKeysWithValues: communities.map { ($0.index, $0) })
        var newNodes: [CodeGraphNode] = []
        var remap = [Int](repeating: -1, count: nodes.count)   // old node idx → new idx
        var metaIndexForCommunity: [Int: Int] = [:]            // community → new idx

        for community in collapsed {
            let members = membersByCommunity[community] ?? []
            let meta = communityMeta[community]
            let newIdx = newNodes.count
            metaIndexForCommunity[community] = newIdx
            for m in members { remap[m] = newIdx }
            newNodes.append(CodeGraphNode(
                id: "community-\(community)",
                label: meta?.name ?? "community \(community)",
                community: community,
                degree: members.reduce(0) { $0 + nodes[$1].degree },
                language: nodes[members.first ?? 0].language,
                memberCount: members.count
            ))
        }
        for (i, n) in nodes.enumerated() where !collapsed.contains(n.community) {
            remap[i] = newNodes.count
            newNodes.append(n)
        }

        // Rewire + dedupe edges by remapped endpoints (skip self-loops created by
        // collapsing both endpoints of an intra-community edge).
        var edgeWeights: [String: (Int, Int, Double)] = [:]
        for e in edges {
            guard e.source < remap.count, e.target < remap.count else { continue }
            let a = remap[e.source], b = remap[e.target]
            guard a >= 0, b >= 0, a != b else { continue }
            let key = a < b ? "\(a)-\(b)" : "\(b)-\(a)"
            let prior = edgeWeights[key]?.2 ?? 0
            edgeWeights[key] = (min(a, b), max(a, b), prior + e.weight)
        }
        let newEdges = edgeWeights.values.map { CodeGraphEdge(source: $0.0, target: $0.1, weight: $0.2) }

        return CodeGraph(repositoryId: repositoryId, level: level, nodes: newNodes, edges: newEdges, communities: communities)
    }

    /// Distinct repository labels present in a namespace-wide (global) graph,
    /// ordered by node count (largest first) so the busiest repos lead the
    /// picker and get the most distinguishable colors. Empty for a per-repo
    /// graph (no node carries a `repo:` prefix).
    var repositories: [String] {
        var counts: [String: Int] = [:]
        for n in nodes { if let r = n.repository { counts[r, default: 0] += 1 } }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map(\.key)
    }

    /// Whether this graph is namespace-wide — any node carries a repository
    /// (from the server's field on symbol nodes, or a `repo:path` id on files).
    var isGlobal: Bool { nodes.contains { $0.repository != nil } }
}

/// One graph node: a file (file level) or symbol (symbol level), colored by its
/// community and sized by `degree`.
struct CodeGraphNode: Codable, Equatable, Identifiable {
    /// Stable identifier — the file path or symbol FQN. Unique within a graph,
    /// so it doubles as the SwiftUI id.
    var id: String
    var label: String
    /// Community index this node belongs to (keys into `CodeGraph.communities`).
    var community: Int
    var degree: Int
    var language: String
    /// >1 when this node is a **collapsed community bubble** (a client-side
    /// meta-node standing in for that many members); 1 for a real node.
    var memberCount: Int = 1

    var isMeta: Bool { memberCount > 1 }

    /// Owning repository, sent explicitly by the server for **symbol** nodes in
    /// the namespace-wide graph (their ids are bare, globally-unique FQNs — which
    /// commonly contain `:` / `#`, so parsing a prefix would slice the symbol
    /// name, not a repo). `nil` on the file graph and per-repo graphs.
    private var repositoryField: String?

    /// The source repository (a git-project name) of a node in the
    /// namespace-wide graph. Prefers the server-provided field (symbol graph);
    /// falls back to the `repo:path` id prefix for **file** nodes, whose ids are
    /// repository-qualified. `nil` for per-repo graphs and meta-bubbles (which
    /// span a community, not one repo).
    var repository: String? {
        if let repositoryField { return repositoryField }
        // File-graph fallback: ids are `repo:path`. Only treat the prefix as a
        // repo when the id looks like a path (contains a `/`), so a symbol FQN
        // like `Foo::bar` or `pkg/Auth#m().` is never mis-sliced into a "repo".
        guard !isMeta, let sep = id.firstIndex(of: ":") else { return nil }
        let prefix = String(id[..<sep]), rest = String(id[id.index(after: sep)...])
        guard !prefix.isEmpty, !prefix.contains("/"), rest.contains("/") else { return nil }
        return prefix
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = c.lenient(String.self, .id, or: UUID().uuidString)
        label     = c.lenient(String.self, .label, or: "")
        community = c.lenient(Int.self, .community, or: 0)
        degree    = c.lenient(Int.self, .degree, or: 0)
        language  = c.lenient(String.self, .language, or: "")
        repositoryField = try? c.decodeIfPresent(String.self, forKey: .repository)
        memberCount = 1
    }

    /// Memberwise init, used to synthesize collapsed community meta-nodes.
    init(id: String, label: String, community: Int, degree: Int, language: String, memberCount: Int = 1) {
        self.id = id; self.label = label; self.community = community
        self.degree = degree; self.language = language; self.memberCount = memberCount
        self.repositoryField = nil
    }

    // Custom encode to satisfy `Codable` alongside the custom `init(from:)`
    // (the `repository` computed property shadows the synthesized member). The
    // app only ever decodes graphs; this exists for protocol conformance.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(community, forKey: .community)
        try c.encode(degree, forKey: .degree)
        try c.encode(language, forKey: .language)
        try c.encodeIfPresent(repositoryField, forKey: .repository)
    }

    enum CodingKeys: String, CodingKey { case id, label, community, degree, language, repository }
}

/// One undirected edge, referencing endpoints by index into `CodeGraph.nodes`.
struct CodeGraphEdge: Codable, Equatable {
    var source: Int
    var target: Int
    var weight: Double
    /// Dominant reference kind ("call", "import", …), when known.
    var kind: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = c.lenient(Int.self, .source, or: 0)
        target = c.lenient(Int.self, .target, or: 0)
        weight = c.lenient(Double.self, .weight, or: 1)
        kind   = try? c.decode(String.self, forKey: .kind)
    }

    /// Memberwise init, used when rewiring edges to collapsed meta-nodes.
    init(source: Int, target: Int, weight: Double, kind: String? = nil) {
        self.source = source; self.target = target; self.weight = weight; self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case source, target, weight, kind }
}

/// Per-community metadata: index (matches `CodeGraphNode.community`), name,
/// size, cohesion — drives the legend and node coloring.
struct CodeGraphCommunity: Codable, Equatable, Identifiable {
    var index: Int
    var name: String
    var size: Int
    var cohesion: Double
    var id: Int { index }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index    = c.lenient(Int.self, .index, or: 0)
        name     = c.lenient(String.self, .name, or: "").tightenedCommunityName
        size     = c.lenient(Int.self, .size, or: 0)
        cohesion = c.lenient(Double.self, .cohesion, or: 0)
    }

    enum CodingKeys: String, CodingKey { case index, name, size, cohesion }
}

// MARK: - Couplings

/// One verified coupling element — a node (file/symbol) or edge whose removal
/// splits a fragile community into its two latent sub-blocks.
struct CouplingElement: Codable, Equatable, Identifiable {
    /// `node` or `edge`.
    var kind: String
    /// The node id — or, for an edge, its two endpoint ids.
    var elements: [String]
    /// How much removing this element alone raises the split probability
    /// (`split_probability − baseline_split_probability`).
    var couplingStrength: Double
    var splitProbability: Double
    var participation: Double
    var minCutShare: Double

    var id: String { kind + ":" + elements.joined(separator: "→") }

    enum CodingKeys: String, CodingKey {
        case kind, elements, participation
        case couplingStrength = "coupling_strength"
        case splitProbability = "split_probability"
        case minCutShare = "min_cut_share"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind             = c.lenient(String.self, .kind, or: "node")
        elements         = c.lenient([String].self, .elements, or: [])
        couplingStrength = c.lenient(Double.self, .couplingStrength, or: 0)
        splitProbability = c.lenient(Double.self, .splitProbability, or: 0)
        participation    = c.lenient(Double.self, .participation, or: 0)
        minCutShare      = c.lenient(Double.self, .minCutShare, or: 0)
    }

    var isEdge: Bool { kind == "edge" }
}

/// A fragile community: internally two latent sub-blocks, plus the coupling
/// elements verified (by ablation) to hold it together.
struct CommunityCoupling: Codable, Equatable, Identifiable {
    /// Matches the community id shown by the clusters/symbol-clusters
    /// endpoints for the same member set.
    var communityId: String
    var size: Int
    var subBlockA: [String]
    var subBlockB: [String]
    /// Strongest first.
    var couplers: [CouplingElement]

    var id: String { communityId }

    enum CodingKeys: String, CodingKey {
        case size, couplers
        case communityId = "community_id"
        case subBlockA = "sub_block_a"
        case subBlockB = "sub_block_b"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        communityId = c.lenient(String.self, .communityId, or: UUID().uuidString)
        size        = c.lenient(Int.self, .size, or: 0)
        subBlockA   = c.lenient([String].self, .subBlockA, or: [])
        subBlockB   = c.lenient([String].self, .subBlockB, or: [])
        couplers    = c.lenient([CouplingElement].self, .couplers, or: [])
    }
}

/// `GET /api/couplings` — the full coupling analysis at one graph level.
struct CouplingReport: Codable, Equatable {
    var totalCommunities: Int
    var fragileCommunities: Int
    var communities: [CommunityCoupling]

    enum CodingKeys: String, CodingKey {
        case communities
        case totalCommunities = "total_communities"
        case fragileCommunities = "fragile_communities"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalCommunities   = c.lenient(Int.self, .totalCommunities, or: 0)
        fragileCommunities = c.lenient(Int.self, .fragileCommunities, or: 0)
        communities        = c.lenient([CommunityCoupling].self, .communities, or: [])
    }
}

// MARK: - LLM backends (models + endpoints)

/// LLM chat backend, as accepted by `?target=` and the explain stream's `llm`
/// field (`openai` | `anthropic` | `copilot`).
enum LlmBackend: String, CaseIterable, Identifiable, Codable {
    case openai, anthropic, copilot
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openai:    return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        case .copilot:   return "GitHub Copilot"
        }
    }
    /// The Anthropic Messages API has no uniform model-discovery endpoint, so
    /// `GET /api/llm/models` rejects it.
    var supportsModelDiscovery: Bool { self != .anthropic }
}

/// One model in `GET /api/llm/models`.
struct LlmModel: Codable, Equatable, Identifiable {
    /// The id to pass back as `model` on the streaming endpoints.
    var id: String
    /// Human-readable name when the backend provides one (Copilot does).
    var name: String?

    enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id   = c.lenient(String.self, .id, or: "")
        name = try? c.decode(String.self, forKey: .name)
    }

    var label: String { name ?? id }
}

struct LlmModelsResponse: Codable, Equatable {
    var target: String
    var models: [LlmModel]

    enum CodingKeys: String, CodingKey { case target, models }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = c.lenient(String.self, .target, or: "")
        models = c.lenient([LlmModel].self, .models, or: [])
    }
}

/// `GET/POST /api/llm/target` — which backend is live and, for Copilot, which
/// model is pinned. Lets the UI show the active backend across sections and
/// reflect the selected Copilot model.
struct LlmTargetResponse: Codable, Equatable {
    var target: LlmBackend?
    var copilotModel: String?

    enum CodingKeys: String, CodingKey {
        case target
        case copilotModel = "copilot_model"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode the target string leniently into the enum; an unknown value
        // (e.g. a backend the app doesn't model) leaves it nil rather than throwing.
        target = (try? c.decode(String.self, forKey: .target)).flatMap(LlmBackend.init(rawValue:))
        copilotModel = try? c.decode(String.self, forKey: .copilotModel)
    }
}

/// One configured OpenAI-compatible endpoint. Keys are never returned; only
/// whether one is set (`has_key`).
struct LlmEndpoint: Codable, Equatable, Identifiable {
    var name: String
    var baseUrl: String
    var model: String?
    var hasKey: Bool
    var active: Bool

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, model, active
        case baseUrl = "base_url"
        case hasKey = "has_key"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name    = c.lenient(String.self, .name, or: "")
        baseUrl = c.lenient(String.self, .baseUrl, or: "")
        model   = try? c.decode(String.self, forKey: .model)
        hasKey  = c.lenient(Bool.self, .hasKey, or: false)
        active  = c.lenient(Bool.self, .active, or: false)
    }
}

struct LlmEndpointsResponse: Codable, Equatable {
    var active: String?
    var endpoints: [LlmEndpoint]

    enum CodingKeys: String, CodingKey { case active, endpoints }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active    = try? c.decode(String.self, forKey: .active)
        endpoints = (try? c.decode([LlmEndpoint].self, forKey: .endpoints)) ?? []
    }

    /// Endpoints sorted with the active one first, then alphabetically.
    var sortedEndpoints: [LlmEndpoint] {
        endpoints.sorted { ($0.active ? 0 : 1, $0.name) < ($1.active ? 0 : 1, $1.name) }
    }
}

/// Body for `PUT /api/llm/endpoints/{name}`. `api_key` is write-only: stored
/// by the server but never returned by any GET.
struct LlmUpsertEndpointRequest: Codable {
    var baseUrl: String
    var model: String?
    var apiKey: String?
    var setActive: Bool = false

    enum CodingKeys: String, CodingKey {
        case model
        case baseUrl = "base_url"
        case apiKey = "api_key"
        case setActive = "set_active"
    }
}

// MARK: - SSE payloads

struct IndexStreamRequest: Codable {
    var path: String
    var name: String?
    var force: Bool = false
}

/// JSON body for `POST /api/stream/explain/{symbol}`. All fields optional —
/// the server also accepts a bare POST. `llm`/`model`/`endpoint` select the
/// chat backend per request (model ids come from `GET /api/llm/models`).
struct ExplainStreamRequest: Codable {
    var repository: String?
    var regex: Bool = false
    var llm: LlmBackend?
    var model: String?
    var endpoint: String?
    /// Bypass the server-side explanation cache and recompute (Regenerate).
    var regenerate: Bool = false
}

struct IndexDone: Codable, Equatable {
    var name: String
    var fileCount: Int
    var chunkCount: Int
    var languages: [IndexLang]
    enum CodingKeys: String, CodingKey {
        case name, languages
        case fileCount = "file_count"
        case chunkCount = "chunk_count"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name       = (try? c.decode(String.self, forKey: .name)) ?? ""
        fileCount  = (try? c.decode(Int.self, forKey: .fileCount)) ?? 0
        chunkCount = (try? c.decode(Int.self, forKey: .chunkCount)) ?? 0
        languages  = (try? c.decode([IndexLang].self, forKey: .languages)) ?? []
    }
}
struct IndexLang: Codable, Equatable { var language: String; var files: Int }

enum IndexEvent {
    case progress(stage: String, message: String)
    case done(IndexDone)
    case failed(String)
}

/// One symbol reached from the root in the call-flow analysis — the structural
/// context (callees / called methods) the server computes regardless of whether
/// the LLM produced prose. Present in the explain `done` payload's `referenced`.
struct ReferencedSymbol: Codable, Equatable, Identifiable {
    var symbol: String
    var file: String
    var line: Int

    var id: String { "\(symbol)@\(file):\(line)" }

    enum CodingKeys: String, CodingKey { case symbol, file, line }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = (try? c.decode(String.self, forKey: .symbol)) ?? ""
        file   = (try? c.decode(String.self, forKey: .file)) ?? ""
        line   = (try? c.decode(Int.self, forKey: .line)) ?? 0
    }

    /// Short display: the last `\\`- or `#`-delimited component of the FQN.
    var shortName: String {
        if let hash = symbol.lastIndex(of: "#") { return String(symbol[symbol.index(after: hash)...]) }
        if let bs = symbol.lastIndex(of: "\\") { return String(symbol[symbol.index(after: bs)...]) }
        return symbol
    }
    var fileName: String { (file as NSString).lastPathComponent }
}

struct ExplainDoneOk: Codable, Equatable {
    var rootSymbol: String
    var explanation: String
    var totalAffected: Int
    var maxDepthReached: Int
    /// The call-flow context (callees / called methods). Rendered even when
    /// `explanation` is empty, so the Call Graph tab always shows structure.
    var referenced: [ReferencedSymbol]
    enum CodingKeys: String, CodingKey {
        case rootSymbol = "root_symbol"
        case explanation
        case totalAffected = "total_affected"
        case maxDepthReached = "max_depth_reached"
        case referenced
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootSymbol      = (try? c.decode(String.self, forKey: .rootSymbol)) ?? ""
        explanation     = (try? c.decode(String.self, forKey: .explanation)) ?? ""
        totalAffected   = (try? c.decode(Int.self, forKey: .totalAffected)) ?? 0
        maxDepthReached = (try? c.decode(Int.self, forKey: .maxDepthReached)) ?? 0
        referenced      = (try? c.decode([ReferencedSymbol].self, forKey: .referenced)) ?? []
    }
}

enum ExplainEvent {
    case token(String)
    case doneOk(ExplainDoneOk)
    case doneAmbiguous(candidates: [String])
    case failed(String)
}

// MARK: - Symbol context (caller/callee tree, no LLM)

/// One node in the caller/callee tree from `GET /api/context/{symbol}`.
struct ContextNode: Codable, Equatable, Identifiable {
    var symbol: String
    var depth: Int
    var filePath: String
    var line: Int
    /// e.g. `method_call`, `unknown`.
    var referenceKind: String
    /// The symbol through which this node connects toward the root.
    var viaSymbol: String?

    var id: String { "\(symbol)@\(filePath):\(line)#\(depth)" }

    enum CodingKeys: String, CodingKey {
        case symbol, depth, line
        case filePath = "file_path"
        case referenceKind = "reference_kind"
        case viaSymbol = "via_symbol"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol        = (try? c.decode(String.self, forKey: .symbol)) ?? ""
        depth         = (try? c.decode(Int.self, forKey: .depth)) ?? 0
        filePath      = (try? c.decode(String.self, forKey: .filePath)) ?? ""
        line          = (try? c.decode(Int.self, forKey: .line)) ?? 0
        referenceKind = (try? c.decode(String.self, forKey: .referenceKind)) ?? ""
        viaSymbol     = try? c.decode(String.self, forKey: .viaSymbol)
    }

    var shortName: String {
        if let hash = symbol.lastIndex(of: "#") { return String(symbol[symbol.index(after: hash)...]) }
        if let bs = symbol.lastIndex(of: "\\") { return String(symbol[symbol.index(after: bs)...]) }
        return symbol
    }
    var fileName: String { (filePath as NSString).lastPathComponent }
}

/// `GET /api/context/{symbol}` — the structural call graph (callers up to entry
/// points, callees down to leaves), computed WITHOUT an LLM. Shown before/
/// alongside the LLM explanation.
struct SymbolContext: Codable, Equatable {
    var symbol: String
    /// The fully-qualified symbols this lookup resolved to. More than one means
    /// the query was ambiguous and the tree below is a MERGE of all of them —
    /// the UI shows a picker instead so unrelated repos aren't mingled.
    var rootSymbols: [String]
    var callersByDepth: [[ContextNode]]
    var calleesByDepth: [[ContextNode]]
    var totalCallers: Int
    var totalCallees: Int
    var maxCallerDepth: Int
    var maxCalleeDepth: Int

    enum CodingKeys: String, CodingKey {
        case symbol
        case rootSymbols = "root_symbols"
        case callersByDepth = "callers_by_depth"
        case calleesByDepth = "callees_by_depth"
        case totalCallers = "total_callers"
        case totalCallees = "total_callees"
        case maxCallerDepth = "max_caller_depth"
        case maxCalleeDepth = "max_callee_depth"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol         = (try? c.decode(String.self, forKey: .symbol)) ?? ""
        rootSymbols    = (try? c.decode([String].self, forKey: .rootSymbols)) ?? []
        callersByDepth = (try? c.decode([[ContextNode]].self, forKey: .callersByDepth)) ?? []
        calleesByDepth = (try? c.decode([[ContextNode]].self, forKey: .calleesByDepth)) ?? []
        totalCallers   = (try? c.decode(Int.self, forKey: .totalCallers)) ?? 0
        totalCallees   = (try? c.decode(Int.self, forKey: .totalCallees)) ?? 0
        maxCallerDepth = (try? c.decode(Int.self, forKey: .maxCallerDepth)) ?? 0
        maxCalleeDepth = (try? c.decode(Int.self, forKey: .maxCalleeDepth)) ?? 0
    }

    var isEmpty: Bool { callersByDepth.isEmpty && calleesByDepth.isEmpty }
    /// Ambiguous when the query matched more than one distinct symbol.
    var isAmbiguous: Bool { rootSymbols.count > 1 }
}

// MARK: - LLM explanation sections

/// One `<tag>…</tag>` section of a streamed LLM explanation, ready to render as
/// a titled block. The stream emits raw XML (`<purpose>…</purpose>`, …) rather
/// than the CLI's post-processed Markdown, so the app splits it into sections
/// itself — which also means each section appears the moment its opening tag
/// streams in, before the closing tag arrives.
struct ExplanationSection: Identifiable, Equatable {
    let tag: String
    let title: String
    /// The section body (Markdown), possibly still growing while it streams.
    var body: String
    var id: String { tag }
}

enum ExplanationParser {
    /// The four sections the explain prompt asks the LLM to emit, in order, with
    /// human titles. Mirrors the server's `xml_to_markdown` mapping so the app and
    /// the CLI label the same content identically.
    static let sections: [(tag: String, title: String)] = [
        ("purpose", "Purpose"),
        ("data_and_control_flow", "Data & control flow"),
        ("business_feature", "Business feature"),
        ("key_patterns_and_dependencies", "Key patterns & dependencies"),
    ]

    /// Split a raw (possibly mid-stream) XML explanation into titled sections.
    ///
    /// Returns `nil` when the text carries no recognised section tags — the
    /// caller then falls back to rendering it as plain Markdown (errors, or a
    /// model that ignored the format). A section with only its opening tag so far
    /// is included with whatever body has streamed in, so content reveals
    /// progressively instead of waiting for the closing tag.
    static func parse(_ raw: String) -> [ExplanationSection]? {
        var found: [ExplanationSection] = []
        for (tag, title) in sections {
            guard let openRange = raw.range(of: "<\(tag)>") else { continue }
            let afterOpen = openRange.upperBound
            // Prefer the matching close tag; if it hasn't streamed in yet, take
            // everything up to the next section's open tag (or end of text).
            let body: Substring
            if let closeRange = raw.range(of: "</\(tag)>", range: afterOpen..<raw.endIndex) {
                body = raw[afterOpen..<closeRange.lowerBound]
            } else if let nextOpen = nextSectionOpen(in: raw, after: afterOpen, excluding: tag) {
                body = raw[afterOpen..<nextOpen]
            } else {
                body = raw[afterOpen...]
            }
            let trimmed = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
            found.append(ExplanationSection(
                tag: tag, title: title, body: shortenSymbols(trimmed)))
        }
        return found.isEmpty ? nil : found
    }

    /// Index of the earliest other-section opening tag after `start`, used to
    /// bound a not-yet-closed section's body.
    private static func nextSectionOpen(in raw: String, after start: String.Index,
                                        excluding tag: String) -> String.Index? {
        sections
            .filter { $0.tag != tag }
            .compactMap { raw.range(of: "<\($0.tag)>", range: start..<raw.endIndex)?.lowerBound }
            .min()
    }

    /// Matches a namespaced FQN — two or more `\`/`/`-separated identifier
    /// segments (so bare words and `$vars` are left alone), keeping any trailing
    /// `#method`, `::method`, or `::CONST` selector. The leading `\` some PHP
    /// FQNs carry (`\Netatmo\…`) is allowed but not captured as a segment.
    private static let fqnPattern = try! NSRegularExpression(
        pattern: #"\\?(?:[A-Za-z_][A-Za-z0-9_]*[\\/]){1,}([A-Za-z_][A-Za-z0-9_]*(?:(?:#|::)[A-Za-z_][A-Za-z0-9_]*)?)"#)

    /// Collapse every namespaced FQN in `text` to its last segment (plus the
    /// `#method`/`::member` selector), e.g. `Netatmo\Api\User\Home\HomesData#post`
    /// → `HomesData#post`. The namespace prefix is repeated on nearly every line
    /// of the call-flow section and carries no signal; this matches the
    /// `shortSymbol` convention used everywhere else in the app. Runs on backtick-
    /// quoted symbols and bare ones alike, since the backticks aren't part of the
    /// match.
    static func shortenSymbols(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        // `$1` is the captured last segment + selector; replace the whole FQN with it.
        return fqnPattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: "$1")
    }
}

// MARK: - Namespace overview: features (GET /api/features)

/// One entry-point feature — a top-level flow (HTTP handler, job, …) ranked by
/// how much of the codebase it reaches. Mirrors the server's feature record.
/// One node of a feature's forward call chain — BFS order from the entry point
/// (depth 0 is the entry point itself).
struct FeatureNode: Decodable, Equatable {
    var symbol: String
    var filePath: String
    var line: Int
    var depth: Int
    /// BFS parent — the symbol whose call discovered this node. `nil` for the
    /// entry point (and for payloads from servers predating the field, which
    /// forces the flat-list fallback rendering).
    var caller: String?
    /// TOTAL execution callees of this symbol. May exceed its child count in
    /// the folded tree — the BFS shows each symbol once, under its first
    /// discoverer — so the UI can tell a true leaf from a deduplicated one.
    var calleeCount: Int
    /// Display name of the repository this SYMBOL lives in, present only when
    /// the flow crossed out of the feature's own repo. Note `filePath:line` is
    /// the CALL SITE (the caller's file) — without this field, cross-repo
    /// symbols are indistinguishable from local ones.
    var repositoryName: String?

    enum CodingKeys: String, CodingKey {
        case symbol, line, depth, caller
        case filePath = "file_path"
        case calleeCount = "callee_count"
        case repositoryName = "repository_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol         = c.lenient(String.self, .symbol, or: "")
        filePath       = c.lenient(String.self, .filePath, or: "")
        line           = c.lenient(Int.self, .line, or: 0)
        depth          = c.lenient(Int.self, .depth, or: 0)
        caller         = try? c.decode(String.self, forKey: .caller)
        calleeCount    = c.lenient(Int.self, .calleeCount, or: 0)
        repositoryName = try? c.decode(String.self, forKey: .repositoryName)
    }
}

struct CodeFeature: Decodable, Equatable, Identifiable {
    var id: String
    var name: String
    var entryPoint: String
    /// 0–1 criticality — reach × depth, normalized. Drives ranking.
    var criticality: Double
    var depth: Int
    var fileCount: Int
    /// Distinct symbols transitively driven by the entry point — the primary
    /// criticality signal.
    var reach: Int
    /// The BFS call chain from the entry point; index 0 is the entry point.
    var path: [FeatureNode]
    /// Repository this feature lives in (attached client-side when merging
    /// per-repo results into a namespace list).
    var repositoryName: String = ""

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = c.lenient(String.self, .id, or: UUID().uuidString)
        name        = c.lenient(String.self, .name, or: "")
        entryPoint  = c.lenient(String.self, .entryPoint, or: "")
        criticality = c.lenient(Double.self, .criticality, or: 0)
        depth       = c.lenient(Int.self, .depth, or: 0)
        fileCount   = c.lenient(Int.self, .fileCount, or: 0)
        reach       = c.lenient(Int.self, .reach, or: 0)
        path        = c.lenient([FeatureNode].self, .path, or: [])
    }

    enum CodingKeys: String, CodingKey {
        case id, name, depth, criticality, reach, path
        case entryPoint = "entry_point"
        case fileCount = "file_count"
    }

    /// Short display name — the last path component of the FQN entry point.
    var shortName: String {
        let base = name.isEmpty ? entryPoint : name
        return base.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? base
    }
}

struct FeaturesResponse: Decodable, Equatable {
    var features: [CodeFeature]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        features = c.lenient([CodeFeature].self, .features, or: [])
    }
    enum CodingKeys: String, CodingKey { case features }
}

// MARK: - Namespace overview: channels (GET /api/channels)

/// One end of a channel — a produce or consume site in some repo. The transport
/// is `protocol` (http/kafka/mqtt/amqp/grpc); the channel identifier is
/// `channel_normalized` (falling back to `channel_raw`).
struct ChannelEndpoint: Decodable, Equatable, Identifiable {
    var id: String
    var repositoryId: String
    var filePath: String
    var enclosingSymbol: String
    var proto: String
    var channel: String
    var method: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = c.lenient(String.self, .id, or: UUID().uuidString)
        repositoryId    = c.lenient(String.self, .repositoryId, or: "")
        filePath        = c.lenient(String.self, .filePath, or: "")
        enclosingSymbol = c.lenient(String.self, .enclosingSymbol, or: "")
        proto           = c.lenient(String.self, .proto, or: "")
        let normalized  = (try? c.decode(String.self, forKey: .channelNormalized)) ?? ""
        let raw         = (try? c.decode(String.self, forKey: .channelRaw)) ?? ""
        channel         = !normalized.isEmpty ? normalized : raw
        method          = try? c.decode(String.self, forKey: .method)
    }

    enum CodingKeys: String, CodingKey {
        case method
        case id, proto = "protocol"
        case repositoryId = "repository_id"
        case filePath = "file_path"
        case enclosingSymbol = "enclosing_symbol"
        case channelNormalized = "channel_normalized"
        case channelRaw = "channel_raw"
    }
}

/// A matched producer→consumer channel link across repos. `producer` and
/// `consumer` are full endpoint objects; the channel/protocol are read from
/// them (the server exposes those as methods, not serialized fields).
struct ChannelEdge: Decodable, Equatable, Identifiable {
    var producer: ChannelEndpoint
    var consumer: ChannelEndpoint
    var weight: Int

    var id: String { "\(producer.id)|\(consumer.id)" }
    /// The shared protocol + channel, for display (e.g. "kafka · orders.created").
    var proto: String { consumer.proto.isEmpty ? producer.proto : consumer.proto }
    var channel: String { consumer.channel.isEmpty ? producer.channel : consumer.channel }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        producer = try c.decode(ChannelEndpoint.self, forKey: .producer)
        consumer = try c.decode(ChannelEndpoint.self, forKey: .consumer)
        weight   = c.lenient(Int.self, .weight, or: 1)
    }

    enum CodingKeys: String, CodingKey { case producer, consumer, weight }
}

/// Cross-service channel graph for a namespace: matched links plus the
/// unmatched producer/consumer sites (a channel produced but never consumed, or
/// vice versa — a common integration smell).
struct ChannelGraph: Decodable, Equatable {
    var edges: [ChannelEdge]
    var unmatchedProducers: [ChannelEndpoint]
    var unmatchedConsumers: [ChannelEndpoint]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edges              = c.lenient([ChannelEdge].self, .edges, or: [])
        unmatchedProducers = c.lenient([ChannelEndpoint].self, .unmatchedProducers, or: [])
        unmatchedConsumers = c.lenient([ChannelEndpoint].self, .unmatchedConsumers, or: [])
    }

    var isEmpty: Bool { edges.isEmpty && unmatchedProducers.isEmpty && unmatchedConsumers.isEmpty }

    enum CodingKeys: String, CodingKey {
        case edges
        case unmatchedProducers = "unmatched_producers"
        case unmatchedConsumers = "unmatched_consumers"
    }
}

// MARK: - Namespace overview: cross-repo uses (GET /api/uses)

/// Files in one repo that reference symbols defined in another — a directed
/// cross-repo dependency.
struct UsesReport: Decodable, Equatable {
    var references: [UsesReference]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        references = (try? c.decode([UsesReference].self, forKey: .references))
            ?? (try? c.decode([UsesReference].self, forKey: .uses)) ?? []
    }
    enum CodingKeys: String, CodingKey { case references, uses }
    var count: Int { references.count }
}

struct UsesReference: Decodable, Equatable, Identifiable {
    var id: String { "\(fromFile)->\(symbol)" }
    var fromFile: String
    var symbol: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fromFile = c.lenient(String.self, .fromFile, or: "")
        symbol   = c.lenient(String.self, .symbol, or: "")
    }
    enum CodingKeys: String, CodingKey {
        case symbol
        case fromFile = "from_file"
    }
}
