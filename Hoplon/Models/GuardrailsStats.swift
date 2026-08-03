import Foundation

// Decodes the JSON served by the guardrail admin server's `GET /stats`
// endpoint. See https://github.com/ArtemisMucaj/guardrails — the admin
// server is enabled with `--admin-listen` and exposes /healthz, /info,
// and /stats.

nonisolated struct GuardrailsStats: Codable, Equatable {
    var perModel: [ModelStat]
    var errors: [ErrorStat]

    enum CodingKeys: String, CodingKey {
        case perModel = "per_model"
        case errors
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        perModel = (try? c.decode([ModelStat].self, forKey: .perModel)) ?? []
        errors   = (try? c.decode([ErrorStat].self, forKey: .errors)) ?? []
    }

    var isEmpty: Bool { perModel.isEmpty && errors.isEmpty }

    // Aggregate rollups for the header summary.
    var totalRequests: Int { perModel.reduce(0) { $0 + $1.total } }
    var totalToolCalls: Int { perModel.reduce(0) { $0 + $1.toolCalls } }
    var totalSucceeded: Int { perModel.reduce(0) { $0 + $1.succeeded } }
    var totalErrors: Int { perModel.reduce(0) { $0 + $1.errors } }
    var overallSuccessRate: Double? {
        let attempted = totalSucceeded + totalErrors
        guard attempted > 0 else { return nil }
        return Double(totalSucceeded) / Double(attempted)
    }
}

nonisolated struct ModelStat: Codable, Equatable, Identifiable {
    var model: String
    var total: Int
    var toolCalls: Int
    var succeeded: Int
    var errors: Int
    var successRate: Double?
    var byOutcome: [OutcomeCount]

    var id: String { model }

    enum CodingKeys: String, CodingKey {
        case model
        case total
        case toolCalls = "tool_calls"
        case succeeded
        case errors
        case successRate = "success_rate"
        case byOutcome = "by_outcome"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model       = (try? c.decode(String.self, forKey: .model)) ?? "unknown"
        total       = (try? c.decode(Int.self, forKey: .total)) ?? 0
        toolCalls   = (try? c.decode(Int.self, forKey: .toolCalls)) ?? 0
        succeeded   = (try? c.decode(Int.self, forKey: .succeeded)) ?? 0
        errors      = (try? c.decode(Int.self, forKey: .errors)) ?? 0
        successRate = try? c.decode(Double.self, forKey: .successRate)
        byOutcome   = (try? c.decode([OutcomeCount].self, forKey: .byOutcome)) ?? []
    }
}

nonisolated struct OutcomeCount: Codable, Equatable, Identifiable {
    var outcome: String
    var count: Int
    var id: String { outcome }
}

nonisolated struct ErrorStat: Codable, Equatable, Identifiable {
    var model: String
    var errorCategory: String
    var toolName: String?
    var detail: String?
    var count: Int

    var id: String { "\(model)|\(errorCategory)|\(toolName ?? "")|\(detail ?? "")" }

    enum CodingKeys: String, CodingKey {
        case model
        case errorCategory = "error_category"
        case toolName = "tool_name"
        case detail
        case count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model         = (try? c.decode(String.self, forKey: .model)) ?? "unknown"
        errorCategory = (try? c.decode(String.self, forKey: .errorCategory)) ?? "unknown"
        toolName      = try? c.decode(String.self, forKey: .toolName)
        detail        = try? c.decode(String.self, forKey: .detail)
        count         = (try? c.decode(Int.self, forKey: .count)) ?? 0
    }
}

/// A flattened key/value view of the admin `GET /info` response. The exact
/// shape isn't part of a stable contract, so we decode it loosely and present
/// whatever fields the server reports.
nonisolated struct GuardrailsInfo: Equatable {
    var rows: [(key: String, value: String)]

    static func == (lhs: GuardrailsInfo, rhs: GuardrailsInfo) -> Bool {
        lhs.rows.map(\.key) == rhs.rows.map(\.key)
            && lhs.rows.map(\.value) == rhs.rows.map(\.value)
    }

    init?(data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        rows = obj
            .map { (key: $0.key, value: GuardrailsInfo.stringify($0.value)) }
            .sorted { $0.key < $1.key }
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let b as Bool:   return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        case let arr as [Any]: return arr.map(stringify).joined(separator: ", ")
        case let dict as [String: Any]:
            return dict.sorted { $0.key < $1.key }
                .map { "\($0.key): \(stringify($0.value))" }
                .joined(separator: ", ")
        default: return String(describing: value)
        }
    }
}
