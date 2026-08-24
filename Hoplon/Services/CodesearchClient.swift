import Foundation

/// Async client for the `codesearch serve` management REST/JSON + SSE API.
///
/// One instance is cheap; construct it from `CodesearchManager.mgmtBase`.
/// Request/response calls use `URLSession.data(for:)`; the two streaming
/// endpoints (`/api/stream/index`, `/api/stream/explain`) use
/// `URLSession.bytes(for:)` and yield parsed SSE frames through an
/// `AsyncThrowingStream`, so callers get natural `Task` cancellation.
struct CodesearchClient {
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
            case .decoding: return "Unexpected response from codesearch."
            }
        }
    }

    /// Server error bodies are uniformly `{ "error": "<message>" }`.
    private struct ErrorBody: Decodable { let error: String }

    // MARK: - Request helpers

    /// Percent-encode one path segment. `.urlPathAllowed` keeps `/` raw, which
    /// would split a value like `fact/user-name` (or a regex symbol) into
    /// multiple route segments; the server expects a single encoded segment.
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
                ?? "codesearch returned HTTP \(http.statusCode)."
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

    // MARK: - Meta / repositories

    func health() async throws -> CodesearchHealth {
        try await get("/health", type: CodesearchHealth.self, timeout: 5)
    }

    func stats() async throws -> CodesearchStats {
        try await get("/api/stats", type: CodesearchStats.self, timeout: 10)
    }

    func repositories() async throws -> [Repository] {
        try await get("/api/repositories", type: RepositoriesResponse.self, timeout: 15).repositories
    }

    func repository(id: String) async throws -> RepositoryDetail {
        let encoded = encodeSegment(id)
        return try await get("/api/repositories/\(encoded)", type: RepositoryDetail.self, timeout: 30)
    }

    /// `POST /api/namespaces` — create a namespace with the default embedding
    /// config. Idempotent server-side for a matching config, so re-creating an
    /// existing namespace is not an error.
    func createNamespace(_ name: String) async throws {
        _ = try await post(
            "/api/namespaces",
            body: CreateNamespaceRequest(name: name),
            type: JSONValue.self,
            timeout: 30
        )
    }

    /// `GET /api/namespaces` — every configured namespace, including ones with
    /// nothing indexed into them yet. Those are invisible to `/api/repositories`,
    /// so this is the only way a freshly created namespace can be listed.
    func namespaces() async throws -> [CodeNamespace] {
        try await get("/api/namespaces", type: NamespacesResponse.self, timeout: 15).namespaces
    }

    /// `DELETE /api/namespaces/{name}` — delete a namespace **and every
    /// repository indexed into it**. Cascading server-side; there is no
    /// non-destructive variant.
    @discardableResult
    func deleteNamespace(_ name: String) async throws -> Bool {
        let encoded = encodeSegment(name)
        var req = URLRequest(url: try url("/api/namespaces/\(encoded)"))
        req.httpMethod = "DELETE"
        // Cascading deletes clear the namespace's chunks, embeddings, call graph
        // and cached analyses, which on a large index is not instant.
        req.timeoutInterval = 120
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? "Delete failed (HTTP \(http.statusCode))."
            throw ClientError.http(status: http.statusCode, message: message)
        }
        return true
    }

    /// `DELETE /api/repositories/{id}` — returns true on success.
    @discardableResult
    func deleteRepository(id: String) async throws -> Bool {
        let encoded = encodeSegment(id)
        var req = URLRequest(url: try url("/api/repositories/\(encoded)"))
        req.httpMethod = "DELETE"
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? "Delete failed (HTTP \(http.statusCode))."
            throw ClientError.http(status: http.statusCode, message: message)
        }
        return true
    }

    // MARK: - Search

    func search(_ request: SearchRequest) async throws -> SearchResponse {
        try await post("/api/search", body: request, type: SearchResponse.self, timeout: 60)
    }

    // MARK: - Communities & couplings

    /// `GET /api/clusters` (file level) or `GET /api/symbol-clusters` (symbol
    /// level) — both decode into the normalized `CommunityGraph`. These run
    /// Leiden detection server-side, so allow a generous timeout.
    func communities(level: CommunityLevel, repository: String? = nil) async throws -> CommunityGraph {
        let path = level == .file ? "/api/clusters" : "/api/symbol-clusters"
        var q: [URLQueryItem] = []
        if let repository { q.append(URLQueryItem(name: "repository", value: repository)) }
        return try await get(path, query: q, type: CommunityGraph.self, timeout: 120)
    }

    /// `GET /api/graph` — the render-ready community graph (nodes + edges +
    /// communities) for one repository at the file or symbol level. Unlike
    /// `/api/clusters` this carries the edge adjacency, so the client can draw
    /// the graph. Large graphs auto-aggregate server-side into the community
    /// meta-graph (or force with `aggregate: true`). Runs Leiden server-side, so
    /// allow a generous timeout.
    ///
    /// With `global: true` the graph spans **every repository in the namespace**
    /// (one Leiden run over the combined, cross-repository graph) at either
    /// level: file nodes are qualified `repo:path`; symbol nodes keep their
    /// globally-unique FQN ids and carry a `repository` field instead. The
    /// `repository` filter is ignored when global.
    func graph(level: CommunityLevel, repository: String? = nil, global: Bool = false, namespace: String? = nil, aggregate: Bool? = nil) async throws -> CodeGraph {
        var q = [URLQueryItem(name: "level", value: level.rawValue)]
        if global {
            q.append(URLQueryItem(name: "global", value: "true"))
            // A global run reads shared, repository-keyed tables, so the server
            // can scope it to any namespace per-request — no restart.
            if let namespace { q.append(URLQueryItem(name: "namespace", value: namespace)) }
        } else if let repository {
            q.append(URLQueryItem(name: "repository", value: repository))
        }
        if let aggregate { q.append(URLQueryItem(name: "aggregate", value: aggregate ? "true" : "false")) }
        return try await get("/api/graph", query: q, type: CodeGraph.self, timeout: 120)
    }

    // MARK: - Namespace overview (features, channels, cross-repo uses)

    /// `GET /api/features` — entry-point features ranked by criticality for one
    /// repository. Cheap; namespace views call it per repo and merge.
    func features(repository: String) async throws -> FeaturesResponse {
        let q = [URLQueryItem(name: "repository", value: repository)]
        return try await get("/api/features", query: q, type: FeaturesResponse.self, timeout: 30)
    }

    /// `GET /api/channels` — cross-service channel links (Kafka/HTTP/…) between a
    /// set of repositories. The `repository` filter is **comma-separated** (a
    /// `Vec` can't be deserialized from repeated query keys); passing the
    /// namespace's repo names scopes the graph to that namespace.
    func channels(repositories: [String]) async throws -> ChannelGraph {
        var q: [URLQueryItem] = []
        if !repositories.isEmpty {
            q.append(URLQueryItem(name: "repository", value: repositories.joined(separator: ",")))
        }
        return try await get("/api/channels", query: q, type: ChannelGraph.self, timeout: 60)
    }

    /// `GET /api/uses` — files in `from` that reference symbols defined in `to`.
    /// Used to surface cross-repo dependencies within a namespace.
    func uses(from: String, to: String) async throws -> UsesReport {
        let q = [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)]
        return try await get("/api/uses", query: q, type: UsesReport.self, timeout: 30)
    }

    /// `GET /api/couplings` — coupling elements holding fragile communities
    /// together. The ablation analysis re-runs Leiden many times, so this is
    /// the slowest endpoint the app calls.
    ///
    /// With `global: true` the analysis runs over the namespace-wide graph, so a
    /// coupler that splits a community is the shared file/symbol welding two
    /// repositories together. File-level couplers are reported as `repo:path`.
    func couplings(level: CommunityLevel, repository: String? = nil, global: Bool = false, namespace: String? = nil) async throws -> CouplingReport {
        var q = [URLQueryItem(name: "level", value: level.rawValue)]
        if global {
            q.append(URLQueryItem(name: "global", value: "true"))
            if let namespace { q.append(URLQueryItem(name: "namespace", value: namespace)) }
        } else if let repository {
            q.append(URLQueryItem(name: "repository", value: repository))
        }
        return try await get("/api/couplings", query: q, type: CouplingReport.self, timeout: 300)
    }

    // MARK: - Symbol context (caller/callee tree)

    /// `GET /api/context/{symbol}` — callers up to entry points and callees down
    /// to leaves, computed without an LLM. 404 → symbol not found (surfaced as a
    /// friendly error by the caller).
    func context(symbol: String, repository: String? = nil, regex: Bool = false) async throws -> SymbolContext {
        let encoded = encodeSegment(symbol)
        var q: [URLQueryItem] = []
        if let repository { q.append(URLQueryItem(name: "repository", value: repository)) }
        if regex { q.append(URLQueryItem(name: "regex", value: "true")) }
        return try await get("/api/context/\(encoded)", query: q, type: SymbolContext.self, timeout: 30)
    }

    // MARK: - LLM backends

    /// `GET /api/llm/models` — chat models available to the given backend (or
    /// the server's default when `target` is nil). For the OpenAI backend,
    /// `endpoint` picks a named endpoint from config.
    func llmModels(target: LlmBackend? = nil, endpoint: String? = nil) async throws -> LlmModelsResponse {
        var q: [URLQueryItem] = []
        if let target { q.append(URLQueryItem(name: "target", value: target.rawValue)) }
        if let endpoint { q.append(URLQueryItem(name: "endpoint", value: endpoint)) }
        return try await get("/api/llm/models", query: q, type: LlmModelsResponse.self, timeout: 30)
    }

    /// `GET /api/llm/endpoints` — configured OpenAI-compatible endpoints (keys
    /// masked) and which is active.
    func llmEndpoints() async throws -> LlmEndpointsResponse {
        try await get("/api/llm/endpoints", type: LlmEndpointsResponse.self, timeout: 10)
    }

    /// `PUT /api/llm/endpoints/{name}` — add or update an endpoint. Returns the
    /// refreshed endpoint list.
    @discardableResult
    func upsertLlmEndpoint(name: String, _ body: LlmUpsertEndpointRequest) async throws -> LlmEndpointsResponse {
        let encoded = encodeSegment(name)
        var req = URLRequest(url: try url("/api/llm/endpoints/\(encoded)"))
        req.httpMethod = "PUT"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        return try decode(LlmEndpointsResponse.self, from: data, response: response)
    }

    /// `DELETE /api/llm/endpoints/{name}` — remove an endpoint. Returns the
    /// refreshed endpoint list.
    ///
    /// Requires a codesearch that serves the route: it was PUT-only through
    /// v2.4.0, which answers 405. `LlmView` surfaces that as "this build of
    /// codesearch can't remove endpoints" rather than a bare HTTP error.
    /// See ArtemisMucaj/codesearch#240.
    @discardableResult
    func deleteLlmEndpoint(name: String) async throws -> LlmEndpointsResponse {
        let encoded = encodeSegment(name)
        var req = URLRequest(url: try url("/api/llm/endpoints/\(encoded)"))
        req.httpMethod = "DELETE"
        req.timeoutInterval = 15
        let (data, response) = try await session.data(for: req)
        return try decode(LlmEndpointsResponse.self, from: data, response: response)
    }

    /// `POST /api/llm/active` — set the active OpenAI endpoint. Returns the
    /// refreshed endpoint list.
    @discardableResult
    func setActiveLlmEndpoint(name: String) async throws -> LlmEndpointsResponse {
        try await post("/api/llm/active", body: ["name": name], type: LlmEndpointsResponse.self, timeout: 15)
    }

    /// `GET /api/llm/target` — the live active backend + pinned Copilot model.
    func llmTarget() async throws -> LlmTargetResponse {
        try await get("/api/llm/target", type: LlmTargetResponse.self, timeout: 10)
    }

    /// `POST /api/llm/target` — switch the active backend (applied live +
    /// persisted). Returns the refreshed target.
    @discardableResult
    func setLlmTarget(_ target: LlmBackend) async throws -> LlmTargetResponse {
        try await post("/api/llm/target", body: ["target": target.rawValue],
                       type: LlmTargetResponse.self, timeout: 15)
    }

    /// `PUT /api/llm/copilot/model` — pin the Copilot model (empty clears it).
    /// Returns the refreshed target.
    @discardableResult
    func setCopilotModel(_ model: String) async throws -> LlmTargetResponse {
        var req = URLRequest(url: try url("/api/llm/copilot/model"))
        req.httpMethod = "PUT"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["model": model])
        let (data, response) = try await session.data(for: req)
        return try decode(LlmTargetResponse.self, from: data, response: response)
    }

    /// Probe an OpenAI-compatible server directly (not via codesearch) for its
    /// `/v1/models`. Used to auto-detect a locally-running LM Studio / vLLM so a
    /// first-run user gets community names + call-flow explanations without
    /// hand-configuring an endpoint. Returns the model ids, or nil if nothing is
    /// listening / it isn't OpenAI-compatible.
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

    /// `GET /api/llm/copilot/login` — poll the current login status.
    func copilotLoginStatus() async throws -> CopilotLoginStatus {
        try await get("/api/llm/copilot/login", type: CopilotLoginStatus.self, timeout: 10)
    }

    // MARK: - SSE: shared frame parser

    /// One decoded SSE frame: the `event:` name and the raw `data:` JSON string.
    struct SSEFrame { let event: String; let data: String }

    /// Stream SSE frames from a request. Parses the line protocol (accumulating
    /// `event:` / `data:` fields, dispatching on a blank line). The stream ends
    /// when the connection closes; cancelling the consuming `Task` tears down
    /// the request (the server drops in-flight work on disconnect).
    private func sseFrames(_ request: URLRequest) -> AsyncThrowingStream<SSEFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw ClientError.http(status: http.statusCode, message: "Stream failed (HTTP \(http.statusCode)).")
                    }
                    var event = "message"
                    var dataLines: [String] = []

                    func handle(_ line: String) {
                        if line.isEmpty {
                            // Blank line dispatches the accumulated frame.
                            if !dataLines.isEmpty {
                                continuation.yield(SSEFrame(event: event, data: dataLines.joined(separator: "\n")))
                            }
                            event = "message"
                            dataLines.removeAll()
                            return
                        }
                        if line.hasPrefix(":") { return } // comment/heartbeat
                        if let value = field("event:", in: line) {
                            event = value
                        } else if let value = field("data:", in: line) {
                            dataLines.append(value)
                        }
                    }

                    // Manual line splitting — NOT `bytes.lines`: Foundation's
                    // AsyncLineSequence swallows EMPTY lines, and an empty line
                    // is precisely what terminates an SSE frame. With it, no
                    // frame ever dispatched mid-stream (tokens never appeared)
                    // and the trailing flush mashed every frame's data into one
                    // undecodable blob. Splitting on the \n byte is UTF-8-safe:
                    // continuation bytes can never equal 0x0A.
                    var buffer: [UInt8] = []
                    func flushLine() {
                        var line = String(decoding: buffer, as: UTF8.self)
                        if line.hasSuffix("\r") { line.removeLast() }
                        buffer.removeAll(keepingCapacity: true)
                        handle(line)
                    }
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") { flushLine() } else { buffer.append(byte) }
                    }
                    if !buffer.isEmpty { flushLine() }
                    // Flush a trailing frame with no terminating blank line.
                    if !dataLines.isEmpty {
                        continuation.yield(SSEFrame(event: event, data: dataLines.joined(separator: "\n")))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func field(_ prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count))
        if value.hasPrefix(" ") { value.removeFirst() }
        return value
    }

    // MARK: - SSE: index

    /// `POST /api/stream/index` — yields `IndexEvent`s until a terminal
    /// `done`/`error` frame (or the connection closes).
    func indexStream(_ request: IndexStreamRequest) -> AsyncThrowingStream<IndexEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: try url("/api/stream/index"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.httpBody = try JSONEncoder().encode(request)
                    for try await frame in sseFrames(req) {
                        let data = Data(frame.data.utf8)
                        switch frame.event {
                        case "progress":
                            let stage = (try? JSONDecoder().decode([String: JSONValue].self, from: data))
                            let stageName = stage?["stage"]?.stringValue ?? "running"
                            let message = stage?["message"]?.stringValue ?? ""
                            continuation.yield(.progress(stage: stageName, message: message))
                        case "done":
                            // A malformed terminal payload must surface as an
                            // error — silently finishing leaves callers with
                            // neither a result nor a failure.
                            guard let done = try? JSONDecoder().decode(IndexDone.self, from: data) else {
                                throw ClientError.decoding
                            }
                            continuation.yield(.done(done))
                            continuation.finish()
                            return
                        case "error":
                            let message = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["message"]?.stringValue ?? "Indexing failed."
                            continuation.yield(.failed(message))
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - SSE: explain

    /// `POST /api/stream/explain/{symbol}` — yields `ExplainEvent`s (streamed
    /// tokens, then a terminal done/error/ambiguous frame). Options travel in
    /// the JSON body — the server reads no query parameters on this route —
    /// including the per-request LLM backend/model override.
    func explainStream(symbol: String, options: ExplainStreamRequest = ExplainStreamRequest()) -> AsyncThrowingStream<ExplainEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let encoded = encodeSegment(symbol)
                    var req = URLRequest(url: try url("/api/stream/explain/\(encoded)"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.httpBody = try JSONEncoder().encode(options)
                    for try await frame in sseFrames(req) {
                        let data = Data(frame.data.utf8)
                        switch frame.event {
                        case "token":
                            let text = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["text"]?.stringValue ?? ""
                            if !text.isEmpty { continuation.yield(.token(text)) }
                        case "done":
                            let obj = try? JSONDecoder().decode([String: JSONValue].self, from: data)
                            if obj?["status"]?.stringValue == "ambiguous" {
                                var candidates: [String] = []
                                if case .array(let arr)? = obj?["candidates"] {
                                    candidates = arr.compactMap { $0.stringValue }
                                }
                                continuation.yield(.doneAmbiguous(candidates: candidates))
                            } else if let done = try? JSONDecoder().decode(ExplainDoneOk.self, from: data) {
                                continuation.yield(.doneOk(done))
                            } else {
                                // Malformed terminal payload → error, not a
                                // silent finish.
                                throw ClientError.decoding
                            }
                            continuation.finish()
                            return
                        case "error":
                            let message = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["message"]?.stringValue ?? "Explanation failed."
                            continuation.yield(.failed(message))
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
