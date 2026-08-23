import Foundation

/// Async client for the guardrail admin server's management and login routes.
///
/// The read-only metrics routes (`/stats`, `/activity`, `/info`, `/healthz`) are
/// polled by `GuardrailsManager` on a timer; this covers the surfaces a *user*
/// drives — changing what the proxy exposes, and authorizing Copilot.
///
/// `/providers` writes to the proxy's `config.json` as well as the live
/// registry, so a change here survives a restart. That is also why the app
/// drives configuration through this API rather than through launch flags:
/// once the config file exists it wins over the flags, and flag-derived state
/// would silently disagree with the running proxy.
struct GuardrailsClient {
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
        /// The route answered 404 because the feature is not enabled — the
        /// management API without `--config`, or Copilot without `--copilot`.
        /// Distinct from a failure: there is nothing wrong, the surface simply
        /// does not exist on this proxy.
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid URL."
            case .http(_, let message): return message
            case .decoding: return "Unexpected response from the guardrail admin server."
            case .notConfigured: return "This proxy does not expose that feature."
            }
        }
    }

    /// Admin error bodies are uniformly `{ "error": "<message>" }`.
    private struct ErrorBody: Decodable { let error: String }

    private func url(_ path: String) throws -> URL {
        guard let u = URL(string: base + path) else { throw ClientError.badURL }
        return u
    }

    /// A path segment, encoded so a provider name with a slash or space cannot
    /// split the route.
    private static let segmentAllowed: CharacterSet =
        CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    private func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? value
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 404 { throw ClientError.notConfigured }
        guard !(200...299).contains(http.statusCode) else { return }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            ?? "The guardrail admin server returned HTTP \(http.statusCode)."
        throw ClientError.http(status: http.statusCode, message: message)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw ClientError.decoding
        }
        return value
    }

    private func send<T: Decodable>(
        _ type: T.Type, _ path: String, method: String, body: Data? = nil
    ) async throws -> T {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        request.timeoutInterval = 10
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try check(data, response)
        return try decode(T.self, from: data)
    }

    // MARK: - Providers

    func providers() async throws -> [ProviderConfig] {
        try await send(ProvidersResponse.self, "/providers", method: "GET").providers
    }

    /// Add a provider. `unversioned` is for upstreams serving their routes at
    /// the root rather than under `/v1`.
    ///
    /// Returns the full new snapshot, so a caller re-renders from the response
    /// rather than refetching.
    func addProvider(
        name: String, baseURL: String, unversioned: Bool = false, exposeByDefault: Bool? = nil
    ) async throws -> [ProviderConfig] {
        var payload: [String: Any] = [
            "name": name, "base_url": baseURL, "unversioned": unversioned,
        ]
        if let exposeByDefault { payload["expose_by_default"] = exposeByDefault }
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try await send(ProvidersResponse.self, "/providers", method: "POST", body: body)
            .providers
    }

    /// Change one provider. Every field is optional; models not named keep
    /// whatever they had, so a single toggle sends a single key.
    func updateProvider(
        _ name: String,
        models: [String: Bool] = [:],
        enabled: Bool? = nil,
        exposeByDefault: Bool? = nil,
        clearModels: Bool = false
    ) async throws -> [ProviderConfig] {
        var payload: [String: Any] = [:]
        if clearModels { payload["clear_models"] = true }
        if !models.isEmpty { payload["models"] = models }
        if let enabled { payload["enabled"] = enabled }
        if let exposeByDefault { payload["expose_by_default"] = exposeByDefault }
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try await send(
            ProvidersResponse.self, "/providers/\(segment(name))", method: "PATCH", body: body
        ).providers
    }

    func removeProvider(_ name: String) async throws -> [ProviderConfig] {
        try await send(
            ProvidersResponse.self, "/providers/\(segment(name))", method: "DELETE"
        ).providers
    }

    // MARK: - Copilot

    /// Where the device flow stands. Throws `.notConfigured` when the proxy was
    /// not started with `--copilot`.
    func copilotStatus() async throws -> CopilotLoginStatus {
        try await send(CopilotLoginStatus.self, "/copilot/login", method: "GET")
    }

    /// Start (or restart) the device flow. Returns as soon as GitHub issues the
    /// code, so the response carries what to show the user; polling continues
    /// on the server.
    func startCopilotLogin() async throws -> CopilotLoginStatus {
        try await send(CopilotLoginStatus.self, "/copilot/login", method: "POST")
    }
}
