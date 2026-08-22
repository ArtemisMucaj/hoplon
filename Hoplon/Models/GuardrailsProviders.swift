import Foundation

// Decodes the guardrail admin server's management API — `GET/POST/PATCH/DELETE
// /providers` — which reads and changes what the proxy exposes, at runtime.
//
// The proxy's `config.json` is the source of truth and wins over CLI flags once
// it exists, so this API (not the launch arguments) is how the app changes
// provider configuration. A change applies to the live registry and is
// persisted in the same call, so it survives a restart.

/// The `GET /providers` envelope.
nonisolated struct ProvidersResponse: Decodable, Equatable {
    var providers: [ProviderConfig]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = (try? c.decode([ProviderConfig].self, forKey: .providers)) ?? []
    }

    enum CodingKeys: String, CodingKey { case providers }
}

/// One upstream the proxy routes to, and the exposure policy for its models.
nonisolated struct ProviderConfig: Decodable, Equatable, Identifiable {
    var name: String
    /// Reduced to scheme/host/port by the server — a base URL may embed
    /// credentials, so the full one never leaves the proxy.
    var baseURL: String
    /// Whether this provider is routed to at all. A disabled provider keeps its
    /// model choices, so turning it off and on again loses no curation.
    var enabled: Bool
    /// What happens to a model the user has not decided about — a new model
    /// appearing in LM Studio should be usable without a trip to settings.
    var exposeByDefault: Bool
    var models: [ProviderModel]

    var id: String { name }

    /// Models currently served to clients.
    var exposedCount: Int { models.filter(\.exposed).count }

    /// Models paired with a row id unique across the whole settings form.
    ///
    /// `ProviderModel.id` is the bare model id, and two providers can serve the
    /// same one — Copilot and a local server both offering `qwen2.5-7b`. Since
    /// every provider's rows live in one `Form`, keying on that alone makes
    /// SwiftUI treat the two as a single row.
    var identifiedModels: [(rowID: String, model: ProviderModel)] {
        models.map { (rowID: "\(name)|\($0.id)", model: $0) }
    }

    enum CodingKeys: String, CodingKey {
        case name
        case baseURL = "base_url"
        case enabled
        case exposeByDefault = "expose_by_default"
        case models
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name            = (try? c.decode(String.self, forKey: .name)) ?? "unknown"
        baseURL         = (try? c.decode(String.self, forKey: .baseURL)) ?? ""
        enabled         = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        exposeByDefault = (try? c.decode(Bool.self, forKey: .exposeByDefault)) ?? true
        models          = (try? c.decode([ProviderModel].self, forKey: .models)) ?? []
    }
}

/// One model a provider reported at discovery.
nonisolated struct ProviderModel: Decodable, Equatable, Identifiable {
    var id: String
    /// Present when the provider names the model distinctly from its id.
    var displayName: String?
    var vendor: String?
    /// Whether clients can see and use this model. A hidden model is not
    /// served, not merely unlisted.
    var exposed: Bool
    /// Whether the live registry currently routes it. Differs from `exposed`
    /// when a change was made but the model was never discovered.
    var routed: Bool

    /// What a picker should show.
    var label: String { displayName ?? id }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case vendor
        case exposed
        case routed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = (try? c.decode(String.self, forKey: .id)) ?? "unknown"
        displayName = try? c.decode(String.self, forKey: .displayName)
        vendor      = try? c.decode(String.self, forKey: .vendor)
        exposed     = (try? c.decode(Bool.self, forKey: .exposed)) ?? false
        routed      = (try? c.decode(Bool.self, forKey: .routed)) ?? false
    }
}

// Copilot device-flow login reuses `CopilotLoginStatus` from CodesearchModels:
// codesearch and guardrails both front the same GitHub device flow and return
// the same `{status, user_code, verification_uri, error}` body, so a second
// type would be the same shape under a different name.
