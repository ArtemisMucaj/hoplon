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

struct MemoryDreamRequest: Codable {
    var idleMinutes: Int?
    enum CodingKeys: String, CodingKey { case idleMinutes = "idle_minutes" }
}

struct MemoryDreamResponse: Codable, Equatable {
    var sessionsEligible: Int
    var sessionsImported: Int
    var sessionsFailed: Int
    var clustersFound: Int
    var operationsApplied: Int
    var operationsSkipped: Int

    enum CodingKeys: String, CodingKey {
        case sessionsEligible = "sessions_eligible"
        case sessionsImported = "sessions_imported"
        case sessionsFailed = "sessions_failed"
        case clustersFound = "clusters_found"
        case operationsApplied = "operations_applied"
        case operationsSkipped = "operations_skipped"
    }
}
