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

/// One memory: an atomic subject–predicate–object statement in the append-only
/// graph memory-rs stores.
///
/// Still raw-JSON-backed. That is what has let this app survive every server
/// reshape so far — a field it does not know about is carried through, and a
/// field that disappears degrades one accessor instead of failing the decode.
/// The strictness lives on the *envelope* (`MemoriesResponse`), where a missing
/// key means the binary is the wrong version and silence would be worse than a
/// thrown error.
struct Memory: Codable, Identifiable, RawJSONBacked {
    let raw: [String: JSONValue]
    /// Stable identity for memories without a recognized identifier — a fresh
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
    var id: String { string("id", "uuid") ?? fallbackID }
    var kind: String? { string("kind", "type") }

    /// The fact itself, written to read on its own. A memory has no *name* —
    /// its identity is its id — so this is the only thing to put in a row.
    var statement: String? { string("statement") }
    var project: String? { string("project") }
    var score: Double? { raw["score"]?.doubleValue }

    var sourceKind: MemorySourceKind {
        MemorySourceKind(rawValue: string("source_kind") ?? "") ?? .extracted
    }
    var confidence: Double? { raw["confidence"]?.doubleValue }
    var recordedAt: Int? { int("recorded_at") }
    var sourceSessionID: String? { string("source_session_id") }

    /// Entity names this fact mentions, already resolved server-side. The
    /// v0.3 subject/predicate/object triple is gone: a memory is a statement
    /// plus the entities it is about.
    var entities: [String] {
        guard case .array(let items)? = raw["entities"] else { return [] }
        return items.compactMap { $0.stringValue }.filter { !$0.isEmpty }
    }

    /// The row title. The statement is the memory now — there is no triple to
    /// distinguish two rows with, so the statement carries the row and the
    /// entities are shown beside it rather than folded into the title.
    var title: String {
        if let s = statement, !s.isEmpty { return s }
        return id
    }
}

/// Where a memory came from. Context for the reader, not something ingestion
/// arbitrates on.
///
/// v0.4.0 reduced this to two cases alongside the memory-model change: the old
/// `assistant_inferred`/`derived` pair went with the consolidation pass that
/// produced them. Unknown values fall back to `extracted`, which is what the
/// server writes for everything it did not hear the user say outright.
nonisolated enum MemorySourceKind: String, Codable, CaseIterable, Identifiable {
    case userStated = "user_stated"
    case extracted
    var id: String { rawValue }
    var label: String {
        switch self {
        case .userStated: return "You said this"
        case .extracted: return "Extracted"
        }
    }
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

// MARK: - Response envelopes
//
// memory-rs returns bare `{"<key>": [...]}` objects with no count field.

/// `GET /api/memory` — `{"memories": [...]}`.
///
/// The `memories` key is **required**, deliberately. Memory objects themselves
/// are lenient, which means a renamed field degrades quietly; that leniency is
/// wrong at the envelope. A new app pointed at an old binary still serving
/// `{"items": …}` must fail with an error the UI can show, not decode to an
/// empty array and render a convincing "no memories yet".
struct MemoriesResponse: Codable { var memories: [Memory] }

struct MemorySearchResponse: Codable {
    var results: [Memory]
    /// Set when a namespace scope matched no member projects.
    var note: String?
}
struct MemoryTreeResponse: Codable { var nodes: [MemoryNode] }

/// `GET /api/sessions` — `{"sessions": [...]}`. Rows stay opaque; only the
/// count is read.
struct MemorySessionsResponse: Codable { var sessions: [JSONValue] }

/// `GET /api/memory/{id}` — a tagged union over memory / resource.
///
/// v0.4.0 dropped the edge graph, so a memory now comes back on its own; the
/// `resource` arm replaces what older binaries returned as a node.
struct MemoryShowResponse: Codable {
    var type: String
    var memory: Memory?
    /// The non-memory arm. v0.4.0 renamed this key from `node` to `resource`
    /// and it is the only place L1/L2 text still comes from — the tree listing
    /// carries just `abstract` — so decoding the old key alone left every
    /// Overview/Detail row blank. `MemoryNode` is raw-JSON-backed, so the
    /// resource object drops straight into it.
    var node: MemoryNode?

    enum CodingKeys: String, CodingKey { case type, memory, node, resource }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        memory = try? c.decode(Memory.self, forKey: .memory)
        node = (try? c.decode(MemoryNode.self, forKey: .resource))
            ?? (try? c.decode(MemoryNode.self, forKey: .node))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(memory, forKey: .memory)
        try c.encodeIfPresent(node, forKey: .resource)
    }
}

/// `DELETE /api/memory/{id}` — a hard delete. v0.4.0 removed the append-only
/// retraction: the row is gone, not marked as never-true, so the app's delete
/// affordance is genuinely destructive.
nonisolated struct MemoryDeleteResponse: Codable { var deleted: Bool }

/// A resolved entity — the anchor memories hang off. Two memories about the
/// same thing share one of these, which is what still relates them now that
/// the memory-to-memory edges are gone.
nonisolated struct MemoryEntity: Codable, Identifiable, Equatable {
    var id: String
    var canonicalName: String
    var entityType: String
    /// Every name this entity answers to, canonical included — it is the
    /// lookup index, not decoration. A list longer than one means attribution
    /// has learned a variant; a common entity stuck at one means variants are
    /// still fragmenting into separate anchors.
    var names: [String]
    var memoryCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case canonicalName = "canonical_name"
        case entityType = "entity_type"
        case names
        case memoryCount = "memory_count"
    }

    var icon: String {
        switch entityType {
        case "person": return "person"
        case "project": return "shippingbox"
        case "tool": return "wrench.and.screwdriver"
        case "place": return "mappin"
        case "organization": return "building.2"
        case "concept": return "lightbulb"
        default: return "questionmark.circle"
        }
    }
}

struct MemoryEntitiesResponse: Codable { var entities: [MemoryEntity] }

/// `GET /api/entities/{id}` — the entity plus what references it.
struct MemoryEntityDetail: Codable {
    var entity: MemoryEntity
    var memories: [Memory]
}

// MARK: - Stats

/// What the Store panel shows. memory-rs dropped `GET /api/stats` in v0.4.0
/// along with the concepts most of it counted — the edge graph, the supersede
/// chain, the four-kind taxonomy — so this is no longer a decoded response.
/// It is assembled client-side from the list endpoints, and carries only
/// counts that still mean something in a store of facts and entities.
struct MemoryStats: Equatable {
    var totalMemories: Int
    var totalEntities: Int
    var totalSessions: Int
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

// MARK: - LLM usages

/// One LLM job a service runs, and which endpoint + model answers it.
///
/// Both services expose the same shape (`GET /api/llm/usages`), so one DTO and
/// one section view drive both settings panes.
nonisolated struct LlmUsage: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var usageDescription: String
    /// `chat` or `embedding` — an embedding usage only accepts an
    /// embedding-capable model, and Copilot can't serve it.
    var kind: String
    var endpoint: String?
    var model: String?
    /// Whether this follows the shared/active backend rather than naming its
    /// own. Shown so the user knows a role change will move it too.
    var inherited: Bool
    /// Set when the binding only applies after the service restarts (codesearch
    /// pins its query expander at boot).
    var requiresRestart: Bool

    var isEmbedding: Bool { kind == "embedding" }

    enum CodingKeys: String, CodingKey {
        case id, label, kind, endpoint, model, inherited
        case usageDescription = "description"
        case requiresRestart = "requires_restart"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = c.lenient(String.self, .id, or: "")
        label            = c.lenient(String.self, .label, or: "")
        usageDescription = c.lenient(String.self, .usageDescription, or: "")
        kind             = c.lenient(String.self, .kind, or: "chat")
        endpoint         = try? c.decode(String.self, forKey: .endpoint)
        model            = try? c.decode(String.self, forKey: .model)
        inherited        = c.lenient(Bool.self, .inherited, or: true)
        requiresRestart  = c.lenient(Bool.self, .requiresRestart, or: false)
    }
}

nonisolated struct LlmUsagesResponse: Codable { var usages: [LlmUsage] }

/// Body for `PUT /api/llm/usages/{id}`. Both nil clears the override.
nonisolated struct LlmUsageBinding: Codable {
    var endpoint: String?
    var model: String?
}

/// One selectable (provider, model) pair for a usage dropdown.
nonisolated struct LlmChoice: Identifiable, Hashable {
    let endpoint: String
    let model: String?
    var id: String { "\(endpoint)/\(model ?? "-")" }
    /// Model first: a picker in a settings pane truncates from the right, and
    /// the model is the part the user came to read — an embedding id runs past
    /// the width a popup button gets, so the endpoint is what gives way.
    var label: String { model.map { "\($0) · \(endpoint)" } ?? endpoint }
}
