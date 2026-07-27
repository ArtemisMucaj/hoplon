import Foundation

/// Async client for the `memory-rs serve` management REST/JSON API.
///
/// One instance is cheap; construct it from `MemoryManager.apiBase`. The MCP
/// endpoint lives on the same port at `/mcp` and is for agents, not this app —
/// everything here goes through the REST surface.
struct MemoryClient {
    let base: String
    private let session: URLSession

    init(base: String, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    enum ClientError: LocalizedError {
        case badURL
        case http(status: Int, message: String)
        case decoding
        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid URL."
            case .http(_, let message): return message
            case .decoding: return "Unexpected response from memory-rs."
            }
        }
    }

    /// Server error bodies are uniformly `{ "error": "<message>" }`.
    private struct ErrorBody: Decodable { let error: String }

    // MARK: - Request helpers

    /// Percent-encode one path segment. `.urlPathAllowed` keeps `/` raw, which
    /// would split a value like `fact/user-name` into multiple route segments;
    /// the server expects a single encoded segment.
    private static let pathSegmentAllowed: CharacterSet =
        CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    private func encodeSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? value
    }

    private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var comps = URLComponents(string: base + path) else { throw ClientError.badURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let u = comps.url else { throw ClientError.badURL }
        return u
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, response: URLResponse) throws -> T {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? "memory-rs returned HTTP \(http.statusCode)."
            throw ClientError.http(status: http.statusCode, message: message)
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw ClientError.decoding }
        return value
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], type: T.Type, timeout: TimeInterval = 20) async throws -> T {
        var req = URLRequest(url: try url(path, query: query))
        req.timeoutInterval = timeout
        let (data, response) = try await session.data(for: req)
        return try decode(T.self, from: data, response: response)
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body, type: T.Type, timeout: TimeInterval = 60) async throws -> T {
        var req = URLRequest(url: try url(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        return try decode(T.self, from: data, response: response)
    }

    @discardableResult
    private func delete<T: Decodable>(_ path: String, type: T.Type, timeout: TimeInterval = 30) async throws -> T {
        var req = URLRequest(url: try url(path))
        req.httpMethod = "DELETE"
        req.timeoutInterval = timeout
        let (data, response) = try await session.data(for: req)
        return try decode(T.self, from: data, response: response)
    }

    // MARK: - Meta

    func health() async throws -> MemoryHealth {
        try await get("/health", type: MemoryHealth.self, timeout: 5)
    }

    func stats() async throws -> MemoryStats {
        try await get("/api/stats", type: MemoryStats.self, timeout: 10)
    }

    // MARK: - Items

    /// `GET /api/memory` — every item, newest first, optionally one kind.
    func list(kind: MemoryKind? = nil) async throws -> [MemoryItem] {
        var query: [URLQueryItem] = []
        if let kind { query.append(URLQueryItem(name: "kind", value: kind.rawValue)) }
        return try await get("/api/memory", query: query, type: MemoryListResponse.self, timeout: 30).items
    }

    /// `GET /api/search` — hybrid semantic + keyword search.
    ///
    /// `project` and `namespace` are mutually exclusive scopes; passing both
    /// makes the server prefer the namespace, so callers should pass one.
    func search(
        query: String,
        kind: MemoryKind? = nil,
        project: String? = nil,
        namespace: String? = nil,
        limit: Int = 20
    ) async throws -> MemorySearchResponse {
        var items = [URLQueryItem(name: "q", value: query),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let kind { items.append(URLQueryItem(name: "kind", value: kind.rawValue)) }
        if let namespace {
            items.append(URLQueryItem(name: "namespace", value: namespace))
        } else if let project {
            items.append(URLQueryItem(name: "project", value: project))
        }
        return try await get("/api/search", query: items, type: MemorySearchResponse.self, timeout: 45)
    }

    /// `GET /api/memory/{id}` — an item by id or `kind/name`, or a node by URI.
    func show(_ id: String) async throws -> MemoryShowResponse {
        try await get("/api/memory/\(encodeSegment(id))", type: MemoryShowResponse.self, timeout: 30)
    }

    /// Resolve one node by `memory://` URI. The tree listing omits L2 content,
    /// so the detail pane fetches it on demand through here.
    func node(uri: String) async throws -> MemoryNode? {
        try await show(uri).node
    }

    /// `DELETE /api/memory/{id}` — delete an item by id or unique `kind/name`.
    private struct DeleteResponse: Decodable { let deleted: Bool; let reason: String? }
    @discardableResult
    func deleteItem(_ id: String) async throws -> Bool {
        try await delete("/api/memory/\(encodeSegment(id))", type: DeleteResponse.self).deleted
    }

    // MARK: - Virtual filesystem

    /// `GET /api/tree` — a directory's children; the roots when `uri` is nil.
    func tree(uri: String? = nil) async throws -> [MemoryNode] {
        var query: [URLQueryItem] = []
        if let uri { query.append(URLQueryItem(name: "uri", value: uri)) }
        return try await get("/api/tree", query: query, type: MemoryTreeResponse.self, timeout: 30).nodes
    }

    // MARK: - Sessions

    /// `GET /api/sessions` — sessions already imported (including failed
    /// attempts, which memory-rs records so the dream harvest stops retrying).
    func sessions() async throws -> [MemorySession] {
        try await get("/api/sessions", type: MemorySessionsResponse.self, timeout: 20).sessions
    }

    /// `POST /api/import` — import one transcript file by path. Extraction calls
    /// the configured LLM, so this is slow; the timeout is generous.
    func importSession(path: String, force: Bool = false) async throws -> MemoryImportResponse {
        try await post("/api/import",
                       body: MemoryImportRequest(path: path, force: force),
                       type: MemoryImportResponse.self,
                       timeout: 600)
    }

    // MARK: - Namespaces

    func namespaces() async throws -> [MemoryNamespace] {
        try await get("/api/namespaces", type: MemoryNamespacesResponse.self, timeout: 15).namespaces
    }

    func namespace(_ name: String) async throws -> MemoryNamespaceDetail {
        try await get("/api/namespaces/\(encodeSegment(name))", type: MemoryNamespaceDetail.self, timeout: 15)
    }

    private struct CreatedResponse: Decodable { let created: Bool }
    @discardableResult
    func createNamespace(_ name: String) async throws -> Bool {
        try await post("/api/namespaces", body: ["name": name], type: CreatedResponse.self, timeout: 15).created
    }

    @discardableResult
    func deleteNamespace(_ name: String) async throws -> Bool {
        try await delete("/api/namespaces/\(encodeSegment(name))", type: DeleteResponse.self).deleted
    }

    private struct AssignedResponse: Decodable { let assigned: Bool }
    @discardableResult
    func assignProject(_ project: String, to namespace: String) async throws -> Bool {
        try await post("/api/namespaces/\(encodeSegment(namespace))/projects",
                       body: ["project": project],
                       type: AssignedResponse.self,
                       timeout: 15).assigned
    }

    private struct RemovedResponse: Decodable { let removed: Bool }
    @discardableResult
    func unassignProject(_ project: String, from namespace: String) async throws -> Bool {
        try await delete("/api/namespaces/\(encodeSegment(namespace))/projects/\(encodeSegment(project))",
                         type: RemovedResponse.self).removed
    }

    // MARK: - Commands

    /// `POST /api/resources` — fetch a file or URL, summarize it, store it at
    /// `memory://resources/<name>`. Calls the LLM for the summary.
    func addResource(source: String, name: String? = nil) async throws -> MemoryAddResourceResponse {
        try await post("/api/resources",
                       body: MemoryAddResourceRequest(source: source, name: name),
                       type: MemoryAddResourceResponse.self,
                       timeout: 300)
    }

    /// `POST /api/dream` — one dream cycle: harvest finished sessions, then
    /// consolidate the store. Long-running; the timeout matches.
    func dream(idleMinutes: Int? = nil) async throws -> MemoryDreamResponse {
        try await post("/api/dream",
                       body: MemoryDreamRequest(idleMinutes: idleMinutes),
                       type: MemoryDreamResponse.self,
                       timeout: 1800)
    }
}
