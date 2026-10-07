import Foundation

// Shapes shared across the service clients: the lenient-decode helper, an
// "any JSON" value, and the `/api/llm/usages` DTOs that codesearch serves.

extension KeyedDecodingContainer {
    /// Decode a value if present and well-typed, falling back to `defaultValue`
    /// otherwise — the lenient-decode idiom used throughout these models. (For
    /// optional fields we keep plain `try?` so a missing key stays `nil`.)
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key, or defaultValue: T) -> T {
        (try? decode(type, forKey: key)) ?? defaultValue
    }
}

// MARK: - Lenient JSON backing

/// A minimal Codable "any JSON" value, used to read open-ended response
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

// MARK: - LLM usages

/// One LLM job a service runs, and which endpoint + model answers it.
///
/// The shape `GET /api/llm/usages` serves; `LlmUsagesSection` renders it.
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
