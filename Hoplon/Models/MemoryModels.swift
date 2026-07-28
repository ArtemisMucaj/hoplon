import Foundation

// DTOs for the memory-rs management API (`memory-rs serve --port PORT`).
//
// The memory shapes are deliberately decoded leniently: the server serializes
// its domain types directly, so field names can gain or lose keys between
// versions. Every wrapper keeps the raw object and projects the handful of
// fields the UI actually renders, rather than failing the whole response over
// one unexpected key.

// MARK: - Meta

struct MemoryHealth: Codable, Equatable {
    var status: String
    var version: String?
}

// MARK: - Lenient JSON backing

/// A minimal Codable "any JSON" value, used to back the memory API's open
/// shapes without brittle field-by-field decoding.
indirect enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Best-effort string projection for display.
    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    var intValue: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    subscript(_ key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

/// Common wrapper for the open memory shapes (item / node / session). Holds the
/// raw object and exposes lenient accessors for the fields we render.
protocol RawJSONBacked {
    var raw: [String: JSONValue] { get }
}
extension RawJSONBacked {
    func string(_ keys: String...) -> String? {
        for k in keys { if let s = raw[k]?.stringValue, !s.isEmpty { return s } }
        return nil
    }
    func int(_ keys: String...) -> Int? {
        for k in keys { if let n = raw[k]?.intValue { return n } }
        return nil
    }
    /// Pretty-printed JSON of the whole object, for a raw disclosure view.
    var prettyJSON: String {
        let obj = JSONValue.object(raw)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(obj), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Memory items / nodes / sessions

struct MemoryItem: Codable, Identifiable, RawJSONBacked {
    let raw: [String: JSONValue]
    /// Stable identity for items without a recognized identifier — a fresh
    /// UUID per `id` read would make SwiftUI replace the row on every diff.
    private let fallbackID = UUID().uuidString
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        raw = (try? c.decode([String: JSONValue].self)) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
    var id: String { string("id", "uuid", "name") ?? fallbackID }
    var kind: String? { string("kind", "type") }
    var name: String? { string("name", "title") }
    var body: String? { string("content", "text", "summary", "value", "description") }
    var project: String? { string("project") }
    var score: Double? { raw["score"]?.doubleValue }
    var updateCount: Int? { int("update_count") }
}

struct MemoryNode: Codable, Identifiable, RawJSONBacked {
    let raw: [String: JSONValue]
    private let fallbackID = UUID().uuidString
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        raw = (try? c.decode([String: JSONValue].self)) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
    var id: String { string("uri", "id", "name") ?? fallbackID }
    var uri: String? { string("uri") }
    var name: String? { string("name", "title", "uri") }
    var kind: String? { string("kind", "type") }
    /// The human-readable summary the server generates for each node — far more
    /// useful than the opaque `memory://sessions/ses_…` uri.
    var abstract: String? { string("abstract_", "abstract", "overview", "summary") }
    /// L0 · the short distilled abstract (read first). Distinct from `abstract`
    /// above, which falls through to overview for a display title.
    var level0Abstract: String? { string("abstract_", "abstract") }
    /// L1 · the longer overview.
    var level1Overview: String? { string("overview") }
    /// L2 · the full body (session transcript / resource text). Often absent on
    /// a bare tree listing and fetched on demand via `node(uri:)`.
    var level2Content: String? { string("content") }
    /// Best title for a tree row: the abstract, else an explicit name, else the
    /// last uri path component (never the full opaque uri).
    var displayTitle: String {
        if let a = abstract, !a.isEmpty { return a }
        if let n = string("name", "title"), !n.isEmpty { return n }
        if let u = uri { return (u as NSString).lastPathComponent }
        return id
    }
    /// A short identifier for a tree row — the node's label/name (or uri's last
    /// component), NOT the abstract. Used where the row should read as a label
    /// (project/session/resource nodes) and the abstract belongs in the detail.
    ///
    /// Prefers the server-provided `label` (project digests carry their original
    /// git remote there, since the URI slugifies it lossily), then a
    /// `name`/`title`, then the uri's last component.
    var shortName: String {
        if let l = string("label"), !l.isEmpty { return l }
        if let n = string("name", "title"), !n.isEmpty { return n }
        if let u = uri {
            let last = (u as NSString).lastPathComponent
            // Older servers (< the label field) still send the slug; fall back
            // to a best-effort humanization for project nodes.
            if kind == "project" { return Self.humanizeProjectSlug(last) }
            return last
        }
        return id
    }

    /// Turn a project digest's URI slug (`github_com_org_repo-51bfd697`) back
    /// into a readable remote (`github.com/org/repo`). Best-effort fallback for
    /// servers that predate the `label` field: drops the trailing `-<hash>`,
    /// maps the known TLD tokens (`_com`/`_org`/…) to a `.`.
    private static func humanizeProjectSlug(_ slug: String) -> String {
        // Strip a trailing `-<hex hash>`.
        var base = slug
        if let dash = base.lastIndex(of: "-"),
           base[base.index(after: dash)...].allSatisfy({ $0.isHexDigit }) {
            base = String(base[..<dash])
        }
        let tokens = base.split(separator: "_").map(String.init)
        guard let tldIdx = tokens.firstIndex(where: { ["com", "org", "net", "io", "dev", "co"].contains($0) }),
              tldIdx > 0 else {
            return slug   // Unrecognized shape — keep it rather than mangle it.
        }
        let host = tokens[0..<tldIdx].joined(separator: ".") + "." + tokens[tldIdx]
        let path = tokens[(tldIdx + 1)...].joined(separator: "/")
        return path.isEmpty ? host : "\(host)/\(path)"
    }

    /// Whether this node is a directory the user can drill into.
    var isDirectory: Bool {
        if let b = raw["is_dir"]?.boolValue ?? raw["is_directory"]?.boolValue { return b }
        if let k = kind?.lowercased() { return k.contains("dir") || k.contains("directory") || k.contains("rollup") }
        return false
    }
}

/// One row of `GET /api/sessions` — a session already imported into memory.
struct MemorySession: Codable, Identifiable, RawJSONBacked {
    let raw: [String: JSONValue]
    private let fallbackID = UUID().uuidString
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        raw = (try? c.decode([String: JSONValue].self)) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
    var id: String { string("id", "uuid", "session_id", "name") ?? fallbackID }
    var source: String? { string("source") }
    var status: String? { string("status") }
    var lastError: String? { string("last_error") }
    var messageCount: Int? { int("message_count") }
    var itemsWritten: Int? { int("items_written") }
    /// Unix seconds; the server sends a raw integer.
    var importedAt: Int? { int("imported_at") }

    var importedDate: Date? { importedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    /// Whether the recorded import attempt failed (memory-rs records failures so
    /// the dream harvest stops retrying them).
    var didFail: Bool { (status ?? "").lowercased() == "failed" }
}

// MARK: - Response envelopes
//
// memory-rs returns bare `{"<key>": [...]}` objects with no count field.

struct MemoryListResponse: Codable { var items: [MemoryItem] }
struct MemorySearchResponse: Codable {
    var results: [MemoryItem]
    /// Set when a namespace scope matched no member projects.
    var note: String?
}
struct MemorySessionsResponse: Codable { var sessions: [MemorySession] }
struct MemoryTreeResponse: Codable { var nodes: [MemoryNode] }

/// `GET /api/memory/{id}` — a tagged union over node / item / ambiguous.
struct MemoryShowResponse: Codable {
    var type: String
    var node: MemoryNode?
    var item: MemoryItem?
    var matches: [MemoryItem]?
}

// MARK: - Stats

struct MemoryStats: Codable, Equatable {
    var totalItems: Int
    var totalSessions: Int
    var totalNodes: Int
    /// `[(kind, count)]` — the server sends an array of 2-element arrays.
    var itemsByKind: [(String, Int)]
    var nodesByKind: [(String, Int)]
    var dataDir: String?

    enum CodingKeys: String, CodingKey {
        case totalItems = "total_items"
        case totalSessions = "total_sessions"
        case totalNodes = "total_nodes"
        case itemsByKind = "items_by_kind"
        case nodesByKind = "nodes_by_kind"
        case dataDir = "data_dir"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalItems    = (try? c.decode(Int.self, forKey: .totalItems)) ?? 0
        totalSessions = (try? c.decode(Int.self, forKey: .totalSessions)) ?? 0
        totalNodes    = (try? c.decode(Int.self, forKey: .totalNodes)) ?? 0
        dataDir       = try? c.decode(String.self, forKey: .dataDir)
        itemsByKind   = Self.decodePairs(c, .itemsByKind)
        nodesByKind   = Self.decodePairs(c, .nodesByKind)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(totalItems, forKey: .totalItems)
        try c.encode(totalSessions, forKey: .totalSessions)
        try c.encode(totalNodes, forKey: .totalNodes)
    }

    /// Rust serializes `Vec<(String, u64)>` as `[["fact", 3], …]`.
    private static func decodePairs(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [(String, Int)] {
        guard let raw = try? c.decode([JSONValue].self, forKey: key) else { return [] }
        return raw.compactMap { entry in
            guard case .array(let pair) = entry, pair.count == 2,
                  let name = pair[0].stringValue, let count = pair[1].intValue else { return nil }
            return (name, count)
        }
    }

    static func == (lhs: MemoryStats, rhs: MemoryStats) -> Bool {
        lhs.totalItems == rhs.totalItems
            && lhs.totalSessions == rhs.totalSessions
            && lhs.totalNodes == rhs.totalNodes
            && lhs.itemsByKind.elementsEqual(rhs.itemsByKind, by: ==)
            && lhs.nodesByKind.elementsEqual(rhs.nodesByKind, by: ==)
    }
}

/// One memory kind, for the browse/search filter.
enum MemoryKind: String, CaseIterable, Identifiable {
    case preference, experience, skill, fact
    var id: String { rawValue }
    var label: String { rawValue.capitalized + "s" }   // "Facts", "Skills", …
    var icon: String {
        switch self {
        case .preference: return "slider.horizontal.3"
        case .experience: return "sparkles"
        case .skill:      return "wrench.and.screwdriver"
        case .fact:       return "text.book.closed"
        }
    }
}

// MARK: - Namespaces

/// A namespace groups projects so recall can span a multi-repo effort.
struct MemoryNamespace: Codable, Identifiable, Equatable {
    var name: String
    var projectCount: Int
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case projectCount = "project_count"
    }
}

struct MemoryNamespacesResponse: Codable { var namespaces: [MemoryNamespace] }
struct MemoryNamespaceDetail: Codable, Equatable {
    var name: String
    var projects: [String]
}

// MARK: - Commands

struct MemoryImportRequest: Codable {
    var path: String
    var force: Bool
}

struct MemoryImportResponse: Codable, Equatable {
    var imported: Bool
    var alreadyImported: Bool?
    var sessionId: String?
    var messageCount: Int?
    var operationsApplied: Int?
    var operationsSkipped: Int?

    enum CodingKeys: String, CodingKey {
        case imported
        case alreadyImported = "already_imported"
        case sessionId = "session_id"
        case messageCount = "message_count"
        case operationsApplied = "operations_applied"
        case operationsSkipped = "operations_skipped"
    }
}

struct MemoryAddResourceRequest: Codable {
    var source: String
    var name: String?
}

struct MemoryAddResourceResponse: Codable, Equatable {
    var uri: String
    var source: String
    var chars: Int
    var abstract: String?

    enum CodingKeys: String, CodingKey {
        case uri, source, chars
        case abstract
    }
}

// MARK: - LLM endpoints (memory-rs's own config, separate from codesearch's)

/// Which resolution slot an endpoint is bound to. memory-rs resolves chat and
/// embeddings **independently**, so a remote chat model can pair with local
/// embeddings; `shared` is the default used by whichever role has no override.
nonisolated enum LlmRole: String, Codable, CaseIterable, Identifiable {
    case shared, chat, embedding
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shared:    return "Default"
        case .chat:      return "Chat"
        case .embedding: return "Embeddings"
        }
    }
    var help: String {
        switch self {
        case .shared:    return "Used by whichever role has no endpoint of its own."
        case .chat:      return "Extraction, summarization and dreaming."
        case .embedding: return "Semantic recall."
        }
    }
}

/// One registered endpoint. The API never echoes the key — `hasApiKey` says
/// only whether one is stored.
nonisolated struct MemoryLlmEndpoint: Codable, Equatable, Identifiable {
    var name: String
    var baseUrl: String
    var model: String?
    var embeddingModel: String?
    var hasApiKey: Bool
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, model
        case baseUrl = "base_url"
        case embeddingModel = "embedding_model"
        case hasApiKey = "has_api_key"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name           = c.lenient(String.self, .name, or: "")
        baseUrl        = c.lenient(String.self, .baseUrl, or: "")
        model          = try? c.decode(String.self, forKey: .model)
        embeddingModel = try? c.decode(String.self, forKey: .embeddingModel)
        hasApiKey      = c.lenient(Bool.self, .hasApiKey, or: false)
    }
}

/// The embedding model + dimension the database is pinned to on first open.
/// Switching to a model of a different width is rejected at open time, so the
/// UI warns before the user strands their store.
nonisolated struct MemoryPinnedEmbedding: Codable, Equatable {
    var model: String
    var dimensions: Int
}

/// Copilot's state, reported alongside the registered endpoints. Copilot isn't
/// a registered endpoint — its URL, headers and credential are fixed — so it's
/// bound by the reserved name `copilot` in the same active-role slot.
nonisolated struct MemoryCopilotState: Codable, Equatable {
    var endpointName: String
    var authenticated: Bool
    var model: String?

    enum CodingKeys: String, CodingKey {
        case endpointName = "endpoint_name"
        case authenticated, model
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endpointName  = c.lenient(String.self, .endpointName, or: "copilot")
        authenticated = c.lenient(Bool.self, .authenticated, or: false)
        model         = try? c.decode(String.self, forKey: .model)
    }
}

/// `GET /api/llm/endpoints` — the whole LLM configuration.
nonisolated struct MemoryLlmConfig: Codable, Equatable {
    var endpoints: [MemoryLlmEndpoint]
    var active: String?
    var activeChat: String?
    var activeEmbedding: String?
    var pinnedEmbedding: MemoryPinnedEmbedding?
    var copilot: MemoryCopilotState?

    /// The reserved endpoint name that selects the Copilot backend.
    static let copilotEndpointName = "copilot"

    enum CodingKeys: String, CodingKey {
        case endpoints, active, copilot
        case activeChat = "active_chat"
        case activeEmbedding = "active_embedding"
        case pinnedEmbedding = "pinned_embedding"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endpoints       = c.lenient([MemoryLlmEndpoint].self, .endpoints, or: [])
        active          = try? c.decode(String.self, forKey: .active)
        activeChat      = try? c.decode(String.self, forKey: .activeChat)
        activeEmbedding = try? c.decode(String.self, forKey: .activeEmbedding)
        pinnedEmbedding = try? c.decode(MemoryPinnedEmbedding.self, forKey: .pinnedEmbedding)
        copilot         = try? c.decode(MemoryCopilotState.self, forKey: .copilot)
    }

    /// Whether Copilot is the chat backend right now.
    var copilotIsChatBackend: Bool {
        resolved(.chat) == Self.copilotEndpointName
    }

    /// The endpoint bound to `role`, resolving chat/embedding through the
    /// shared default the way the server does.
    func resolved(_ role: LlmRole) -> String? {
        switch role {
        case .shared:    return active
        case .chat:      return activeChat ?? active
        case .embedding: return activeEmbedding ?? active
        }
    }

    /// Whether `role` names its own endpoint rather than inheriting `active`.
    func isExplicit(_ role: LlmRole) -> Bool {
        switch role {
        case .shared:    return active != nil
        case .chat:      return activeChat != nil
        case .embedding: return activeEmbedding != nil
        }
    }
}

/// Body for `PUT /api/llm/endpoints/{name}`.
nonisolated struct MemoryLlmUpsertRequest: Codable {
    /// Omitted for the reserved `copilot` name, whose URL the provider fixes.
    var baseUrl: String?
    var model: String?
    var embeddingModel: String?
    /// Omit to keep an existing key; send `""` to clear it.
    var apiKey: String?
    var setActive: LlmRole?

    enum CodingKeys: String, CodingKey {
        case baseUrl = "base_url"
        case model
        case embeddingModel = "embedding_model"
        case apiKey = "api_key"
        case setActive = "set_active"
    }
}

/// Body for `POST /api/llm/active`.
nonisolated struct MemoryLlmSetActiveRequest: Codable {
    /// `nil` clears the role back to the shared default.
    var name: String?
    var role: LlmRole
}

nonisolated struct MemoryLlmModel: Codable, Equatable, Identifiable {
    var id: String
    var vendor: String?
}

nonisolated struct MemoryLlmModelsResponse: Codable, Equatable {
    var baseUrl: String
    var models: [MemoryLlmModel]

    enum CodingKeys: String, CodingKey {
        case baseUrl = "base_url"
        case models
    }
}

// MARK: - Dream (memory consolidation) config + status

/// `GET /api/dream` — the dream scheduler's config, whether a cycle is running,
/// and the last recorded run. Config fields double as the editable dream
/// settings (written back via `PUT /api/dream/config`).
nonisolated struct DreamStatus: Codable, Equatable {
    var enabled: Bool
    var intervalHours: Int
    var sessionIdleMinutes: Int
    var autoImport: Bool
    var running: Bool

    enum CodingKeys: String, CodingKey {
        case enabled, running
        case intervalHours = "interval_hours"
        case sessionIdleMinutes = "session_idle_minutes"
        case autoImport = "auto_import"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled            = c.lenient(Bool.self, .enabled, or: true)
        intervalHours      = c.lenient(Int.self, .intervalHours, or: 4)
        sessionIdleMinutes = c.lenient(Int.self, .sessionIdleMinutes, or: 60)
        autoImport         = c.lenient(Bool.self, .autoImport, or: true)
        running            = c.lenient(Bool.self, .running, or: false)
    }
}

/// Body for `PUT /api/dream/config` — a partial update. Every field is optional
/// so changing one setting leaves the rest untouched server-side.
nonisolated struct DreamConfigRequest: Codable {
    var dreamEnabled: Bool?
    var dreamIntervalHours: Int?
    var sessionIdleMinutes: Int?
    var autoImport: Bool?

    enum CodingKeys: String, CodingKey {
        case dreamEnabled = "dream_enabled"
        case dreamIntervalHours = "dream_interval_hours"
        case sessionIdleMinutes = "session_idle_minutes"
        case autoImport = "auto_import"
    }
}

/// `PUT /api/dream/config` response — the merged effective config.
nonisolated struct DreamConfigResponse: Codable, Equatable {
    var dreamEnabled: Bool
    var dreamIntervalHours: Int
    var sessionIdleMinutes: Int
    var autoImport: Bool

    enum CodingKeys: String, CodingKey {
        case dreamEnabled = "dream_enabled"
        case dreamIntervalHours = "dream_interval_hours"
        case sessionIdleMinutes = "session_idle_minutes"
        case autoImport = "auto_import"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dreamEnabled       = c.lenient(Bool.self, .dreamEnabled, or: true)
        dreamIntervalHours = c.lenient(Int.self, .dreamIntervalHours, or: 4)
        sessionIdleMinutes = c.lenient(Int.self, .sessionIdleMinutes, or: 60)
        autoImport         = c.lenient(Bool.self, .autoImport, or: true)
    }
}
