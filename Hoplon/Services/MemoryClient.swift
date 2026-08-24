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

    // MARK: - Memories

    /// `GET /api/memory` — memories, newest first.
    ///
    /// v0.4.0 dropped both the `kind` and `status` filters: every memory is a
    /// fact now, and there is no lifecycle to filter by. Scope is the only
    /// narrowing left, and `project`/`namespace` are mutually exclusive.
    func list(project: String? = nil, namespace: String? = nil) async throws -> [Memory] {
        var query: [URLQueryItem] = []
        if let namespace {
            query.append(URLQueryItem(name: "namespace", value: namespace))
        } else if let project {
            query.append(URLQueryItem(name: "project", value: project))
        }
        return try await get("/api/memory", query: query, type: MemoriesResponse.self, timeout: 30)
            .memories
    }

    /// `GET /api/search` — hybrid semantic + keyword search.
    ///
    /// `project` and `namespace` are mutually exclusive scopes; passing both
    /// makes the server prefer the namespace, so callers should pass one.
    func search(
        query: String,
        project: String? = nil,
        namespace: String? = nil,
        limit: Int = 20
    ) async throws -> MemorySearchResponse {
        var items = [URLQueryItem(name: "q", value: query),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let namespace {
            items.append(URLQueryItem(name: "namespace", value: namespace))
        } else if let project {
            items.append(URLQueryItem(name: "project", value: project))
        }
        return try await get("/api/search", query: items, type: MemorySearchResponse.self, timeout: 45)
    }

    /// `GET /api/sessions` — sessions already imported into the store.
    ///
    /// Only the count is used (the Store panel), so the rows decode as opaque
    /// JSON rather than a modelled type: this endpoint's row shape is not
    /// otherwise consumed, and modelling it would be a second thing to keep in
    /// step with the server for no gain.
    func sessions() async throws -> [JSONValue] {
        try await get("/api/sessions", type: MemorySessionsResponse.self, timeout: 20).sessions
    }

    /// `GET /api/entities` — the anchors memories reference, most-used first.
    func entities() async throws -> [MemoryEntity] {
        try await get("/api/entities", type: MemoryEntitiesResponse.self, timeout: 20).entities
    }

    /// `GET /api/entities/{id}` — one entity and the memories referencing it.
    func entity(_ id: String) async throws -> MemoryEntityDetail {
        try await get("/api/entities/\(encodeSegment(id))",
                      type: MemoryEntityDetail.self, timeout: 20)
    }

    /// `DELETE /api/memory/{id}` — delete a memory for good.
    ///
    /// v0.4.0 made this a hard delete: the row is removed rather than marked
    /// as never-true and kept in the log for provenance. Nothing behind this
    /// can restore the memory, so callers must treat it as destructive.
    @discardableResult
    func forget(_ id: String) async throws -> Bool {
        try await delete("/api/memory/\(encodeSegment(id))",
                         type: MemoryDeleteResponse.self).deleted
    }

    /// `GET /api/memory/{id}` — a memory (with its edges) by id, or a node by
    /// `memory://` URI.
    func show(_ id: String) async throws -> MemoryShowResponse {
        try await get("/api/memory/\(encodeSegment(id))", type: MemoryShowResponse.self, timeout: 30)
    }

    /// Resolve one node by `memory://` URI. The tree listing omits L2 content,
    /// so the detail pane fetches it on demand through here.
    func node(uri: String) async throws -> MemoryNode? {
        try await show(uri).node
    }

    // MARK: - Virtual filesystem

    /// `GET /api/tree` — a directory's children; the roots when `uri` is nil.
    func tree(uri: String? = nil) async throws -> [MemoryNode] {
        var query: [URLQueryItem] = []
        if let uri { query.append(URLQueryItem(name: "uri", value: uri)) }
        return try await get("/api/tree", query: query, type: MemoryTreeResponse.self, timeout: 30).nodes
    }

    // MARK: - Session discovery + background import

    /// `GET /api/sessions/discover` — importable sessions found on disk, newest
    /// first. Distinct from `sessions()` above, which lists what's already in
    /// the store. Discovery walks three session stores, so it can be slow on a
    /// large backlog — hence the generous timeout.
    func discoverSessions() async throws -> [DiscoveredSessionDTO] {
        try await get("/api/sessions/discover", type: DiscoveredSessionsResponse.self, timeout: 45).sessions
    }

    /// `GET /api/sessions/transcript?source=&id=` — one session's full transcript.
    func sessionTranscript(source: String, id: String) async throws -> SessionTranscriptDTO {
        let q = [URLQueryItem(name: "source", value: source), URLQueryItem(name: "id", value: id)]
        return try await get("/api/sessions/transcript", query: q, type: SessionTranscriptDTO.self, timeout: 30)
    }

    /// `GET /api/sessions/import` — the import status of every tracked session.
    func sessionImportStatuses() async throws -> [SessionImportStatusDTO] {
        try await get("/api/sessions/import", type: SessionImportStatusResponse.self, timeout: 10).statuses
    }

    /// `POST /api/sessions/import` — queue a background import. Returns once the
    /// server has accepted it (202); the import itself runs server-side and is
    /// polled via `sessionImportStatuses()`.
    func importSession(source: String, id: String, force: Bool = false) async throws {
        struct Accepted: Decodable { let queued: Bool? }
        _ = try await post(
            "/api/sessions/import",
            body: SessionImportRequest(source: source, id: id, force: force),
            type: Accepted.self,
            timeout: 15
        )
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

    private struct DeletedResponse: Decodable { let deleted: Bool }
    @discardableResult
    func deleteNamespace(_ name: String) async throws -> Bool {
        try await delete("/api/namespaces/\(encodeSegment(name))", type: DeletedResponse.self).deleted
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

    // MARK: - LLM endpoints

    /// `GET /api/llm/endpoints` — registered endpoints plus the active bindings.
    func llmConfig() async throws -> MemoryLlmConfig {
        try await get("/api/llm/endpoints", type: MemoryLlmConfig.self, timeout: 10)
    }

    /// `PUT /api/llm/endpoints/{name}` — register or update one endpoint.
    @discardableResult
    func upsertLlmEndpoint(name: String, _ request: MemoryLlmUpsertRequest) async throws -> MemoryLlmConfig {
        var req = URLRequest(url: try url("/api/llm/endpoints/\(encodeSegment(name))"))
        req.httpMethod = "PUT"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)
        let (data, response) = try await session.data(for: req)
        return try decode(MemoryLlmConfig.self, from: data, response: response)
    }

    /// `DELETE /api/llm/endpoints/{name}` — remove an endpoint (and any role
    /// bound to it).
    @discardableResult
    func deleteLlmEndpoint(name: String) async throws -> MemoryLlmConfig {
        try await delete("/api/llm/endpoints/\(encodeSegment(name))", type: MemoryLlmConfig.self)
    }

    /// `POST /api/llm/active` — bind (or clear) the endpoint used for a role.
    @discardableResult
    func setLlmActive(name: String?, role: LlmRole) async throws -> MemoryLlmConfig {
        try await post("/api/llm/active",
                       body: MemoryLlmSetActiveRequest(name: name, role: role),
                       type: MemoryLlmConfig.self,
                       timeout: 15)
    }

    /// `GET /api/llm/models` — enumerate a server's models, either from a
    /// registered endpoint or a raw base URL (so a UI can validate before save).
    func llmModels(endpoint: String? = nil, baseUrl: String? = nil) async throws -> MemoryLlmModelsResponse {
        var query: [URLQueryItem] = []
        if let endpoint { query.append(URLQueryItem(name: "endpoint", value: endpoint)) }
        if let baseUrl { query.append(URLQueryItem(name: "base_url", value: baseUrl)) }
        return try await get("/api/llm/models", query: query, type: MemoryLlmModelsResponse.self, timeout: 30)
    }

    /// Probe an OpenAI-compatible server directly (not via memory-rs) for its
    /// `/v1/models`. Used to auto-detect a locally-running LM Studio / vLLM so a
    /// first-run user gets memory extraction working without hand-configuring an
    /// endpoint. Returns the model ids, or nil if nothing is listening / it
    /// isn't OpenAI-compatible.
    static func probeOpenAIModels(baseUrl: String, timeout: TimeInterval = 2) async -> [String]? {
        // Accept both ".../v1" and a bare host; normalize to ".../v1/models".
        let trimmed = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let modelsURL = trimmed.hasSuffix("/v1") ? trimmed + "/models" : trimmed + "/v1/models"
        guard let url = URL(string: modelsURL) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return nil }
        // OpenAI `/v1/models` shape: { "data": [ { "id": "..." }, ... ] }.
        struct ModelsList: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        guard let list = try? JSONDecoder().decode(ModelsList.self, from: data) else { return nil }
        return list.data.map(\.id)
    }

    // MARK: - LLM usages

    /// `GET /api/llm/usages` — every LLM job this service runs.
    func llmUsages() async throws -> [LlmUsage] {
        try await get("/api/llm/usages", type: LlmUsagesResponse.self, timeout: 15).usages
    }

    /// `PUT /api/llm/usages/{id}` — bind one usage. Both nil clears it.
    @discardableResult
    func setLlmUsage(_ id: String, endpoint: String?, model: String?) async throws -> LlmUsage {
        var req = URLRequest(url: try url("/api/llm/usages/\(encodeSegment(id))"))
        req.httpMethod = "PUT"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(LlmUsageBinding(endpoint: endpoint, model: model))
        let (data, response) = try await session.data(for: req)
        return try decode(LlmUsage.self, from: data, response: response)
    }

    // MARK: - Copilot device-flow login

    /// `POST /api/llm/copilot/login` — start (or restart) the GitHub device
    /// flow. Returns the initial status (pending with the code + URL, or failed).
    @discardableResult
    func startCopilotLogin() async throws -> CopilotLoginStatus {
        var req = URLRequest(url: try url("/api/llm/copilot/login"))
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        let (data, response) = try await session.data(for: req)
        return try decode(CopilotLoginStatus.self, from: data, response: response)
    }

    /// `PUT /api/llm/endpoints/copilot` — pin the Copilot model. Copilot is a
    /// reserved name rather than a registered endpoint, so this writes the
    /// copilot config instead of an OpenAI one.
    @discardableResult
    func setCopilotModel(_ model: String) async throws -> MemoryLlmConfig {
        try await upsertLlmEndpoint(
            name: MemoryLlmConfig.copilotEndpointName,
            MemoryLlmUpsertRequest(baseUrl: nil, model: model, embeddingModel: nil,
                                   apiKey: nil, setActive: nil)
        )
    }

    /// `GET /api/llm/copilot/login` — poll the device flow's progress.
    func copilotLoginStatus() async throws -> CopilotLoginStatus {
        try await get("/api/llm/copilot/login", type: CopilotLoginStatus.self, timeout: 10)
    }

    // MARK: - Dream scheduler

    /// `GET /api/dream` — the scheduler's settings plus whether a cycle is
    /// currently running.
    func dreamStatus() async throws -> DreamStatus {
        try await get("/api/dream", type: DreamStatus.self, timeout: 10)
    }

    /// `PUT /api/dream/config` — partial update, applied live and persisted.
    /// Returns the merged effective config.
    @discardableResult
    func updateDreamConfig(_ request: DreamConfigRequest) async throws -> DreamConfigResponse {
        var req = URLRequest(url: try url("/api/dream/config"))
        req.httpMethod = "PUT"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)
        let (data, response) = try await session.data(for: req)
        return try decode(DreamConfigResponse.self, from: data, response: response)
    }

    /// `POST /api/dream` — start one cycle in the background. Returns as soon as
    /// the server accepts it (202); poll `dreamStatus()` for `running`.
    func triggerDream() async throws {
        struct Accepted: Decodable { let started: Bool? }
        _ = try await post("/api/dream", body: [String: String](), type: Accepted.self, timeout: 15)
    }
}
