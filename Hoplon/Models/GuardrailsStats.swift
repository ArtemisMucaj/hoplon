import Foundation

// Decodes the JSON served by the guardrail admin server
// (https://github.com/ArtemisMucaj/guardrails), enabled with `--admin-listen`:
//
//   /healthz   liveness
//   /info      how the running proxy is configured
//   /stats     the metrics rollup, optionally bounded by ?since=/?until=
//   /activity  per-day totals, for the contribution graph
//
// Decoding is lenient on purpose — each field falls back rather than failing
// the whole response — so the app tolerates a binary slightly older or newer
// than it was built against instead of showing nothing.

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

    /// Models that reported any usage, biggest spender first — the population
    /// the token bars are drawn over.
    var measured: [ModelStat] {
        perModel.filter { $0.usage != nil }
            .sorted { ($0.usage?.billedTokens ?? 0) > ($1.usage?.billedTokens ?? 0) }
    }

    /// Tokens the provider charged for, across every model that reported usage.
    var totalBilledTokens: Int { perModel.compactMap { $0.usage?.billedTokens }.reduce(0, +) }
    var totalCachedTokens: Int { perModel.compactMap { $0.usage?.cachedTokens }.reduce(0, +) }
    var totalPromptTokens: Int { perModel.compactMap { $0.usage?.promptTokens }.reduce(0, +) }

    /// Cache hit rate over prompt tokens, or `nil` when nothing was measured —
    /// so the UI shows "not measured" rather than a confident 0%.
    var overallCacheHitRate: Double? {
        guard totalPromptTokens > 0 else { return nil }
        return Double(totalCachedTokens) / Double(totalPromptTokens)
    }
}

nonisolated struct ModelStat: Codable, Equatable, Identifiable {
    /// The provider serving this model. The proxy routes to several, so this is
    /// half the identity of a row.
    var provider: String
    var model: String
    var total: Int
    var toolCalls: Int
    var succeeded: Int
    var errors: Int
    var successRate: Double?
    var byOutcome: [OutcomeCount]
    /// Token usage, or `nil` when no request for this model reported any.
    /// Absent means *not measured* and must not render as a confident zero.
    var usage: ModelUsage?

    /// Keyed on the pair, not the model alone: the same model id served by two
    /// providers (Copilot and a local server both offering `qwen2.5-7b`) is two
    /// rows, and keying on `model` alone collapses them into one.
    var id: String { "\(provider)|\(model)" }

    /// What to show in a chart axis or table row.
    var label: String { "\(provider) · \(model)" }

    enum CodingKeys: String, CodingKey {
        case provider
        case model
        case total
        case toolCalls = "tool_calls"
        case succeeded
        case errors
        case successRate = "success_rate"
        case byOutcome = "by_outcome"
        case usage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider    = (try? c.decode(String.self, forKey: .provider)) ?? "unknown"
        model       = (try? c.decode(String.self, forKey: .model)) ?? "unknown"
        total       = (try? c.decode(Int.self, forKey: .total)) ?? 0
        toolCalls   = (try? c.decode(Int.self, forKey: .toolCalls)) ?? 0
        succeeded   = (try? c.decode(Int.self, forKey: .succeeded)) ?? 0
        errors      = (try? c.decode(Int.self, forKey: .errors)) ?? 0
        successRate = try? c.decode(Double.self, forKey: .successRate)
        byOutcome   = (try? c.decode([OutcomeCount].self, forKey: .byOutcome)) ?? []
        usage       = try? c.decode(ModelUsage.self, forKey: .usage)
    }
}

/// Token usage for one (provider, model), summed over every backend attempt the
/// measured requests made.
nonisolated struct ModelUsage: Codable, Equatable {
    /// Prompt tokens as billed. NOT additive across a conversation: each turn
    /// resends the transcript, so shared prefixes count once per turn.
    /// `distinctPromptTokens` is the figure that counts them once.
    var promptTokens: Int
    var completionTokens: Int
    /// `promptTokens + completionTokens` — what the provider charged for.
    var billedTokens: Int
    /// Of `promptTokens`, the portion served from the prompt cache.
    var cachedTokens: Int
    /// Of `promptTokens`, the portion billed at full rate.
    var uncachedPromptTokens: Int
    /// Cache hit rate over prompt tokens, `nil` without any.
    var cacheHitRate: Double?
    /// Backend calls these totals span, retries included.
    var billedCalls: Int
    /// Client requests the totals are measured over.
    var requests: Int
    /// The multiplier retries add to the bill.
    var callsPerRequest: Double?
    /// Prompt tokens with resent transcript prefixes counted once. `nil` when
    /// conversations cannot be reconstructed, rather than repeating the
    /// inflated sum under a better name.
    var distinctPromptTokens: Int?
    var distinctTokens: Int?
    var conversations: Int?
    /// Whether the three fields above rest on conversation edges the proxy
    /// *inferred* from message prefixes rather than ones the API supplied.
    /// Inferred grouping is a heuristic, so those figures are real but
    /// approximate — the UI marks them as such.
    var inferredConversations: Bool

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case billedTokens = "billed_tokens"
        case cachedTokens = "cached_tokens"
        case uncachedPromptTokens = "uncached_prompt_tokens"
        case cacheHitRate = "cache_hit_rate"
        case billedCalls = "billed_calls"
        case requests
        case callsPerRequest = "calls_per_request"
        case distinctPromptTokens = "distinct_prompt_tokens"
        case distinctTokens = "distinct_tokens"
        case conversations
        case inferredConversations = "inferred_conversations"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens         = (try? c.decode(Int.self, forKey: .promptTokens)) ?? 0
        completionTokens     = (try? c.decode(Int.self, forKey: .completionTokens)) ?? 0
        billedTokens         = (try? c.decode(Int.self, forKey: .billedTokens)) ?? 0
        cachedTokens         = (try? c.decode(Int.self, forKey: .cachedTokens)) ?? 0
        uncachedPromptTokens = (try? c.decode(Int.self, forKey: .uncachedPromptTokens)) ?? 0
        cacheHitRate         = try? c.decode(Double.self, forKey: .cacheHitRate)
        billedCalls          = (try? c.decode(Int.self, forKey: .billedCalls)) ?? 0
        requests             = (try? c.decode(Int.self, forKey: .requests)) ?? 0
        callsPerRequest      = try? c.decode(Double.self, forKey: .callsPerRequest)
        distinctPromptTokens = try? c.decode(Int.self, forKey: .distinctPromptTokens)
        distinctTokens       = try? c.decode(Int.self, forKey: .distinctTokens)
        conversations        = try? c.decode(Int.self, forKey: .conversations)
        inferredConversations =
            (try? c.decode(Bool.self, forKey: .inferredConversations)) ?? false
    }
}

nonisolated struct OutcomeCount: Codable, Equatable, Identifiable {
    var outcome: String
    var count: Int
    var id: String { outcome }
}

nonisolated struct ErrorStat: Codable, Equatable, Identifiable {
    var provider: String
    var model: String
    /// Optional on the wire: an unfixed failure need not be categorised.
    var errorCategory: String?
    var toolName: String?
    var detail: String?
    var count: Int

    var id: String {
        "\(provider)|\(model)|\(errorCategory ?? "")|\(toolName ?? "")|\(detail ?? "")"
    }

    var label: String { "\(provider) · \(model)" }

    enum CodingKeys: String, CodingKey {
        case provider
        case model
        case errorCategory = "error_category"
        case toolName = "tool_name"
        case detail
        case count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider      = (try? c.decode(String.self, forKey: .provider)) ?? "unknown"
        model         = (try? c.decode(String.self, forKey: .model)) ?? "unknown"
        errorCategory = try? c.decode(String.self, forKey: .errorCategory)
        toolName      = try? c.decode(String.self, forKey: .toolName)
        detail        = try? c.decode(String.self, forKey: .detail)
        count         = (try? c.decode(Int.self, forKey: .count)) ?? 0
    }
}

// MARK: - Activity

/// The `GET /activity` envelope.
nonisolated struct GuardrailsActivity: Decodable, Equatable {
    var days: [DayActivity]

    enum CodingKeys: String, CodingKey {
        case activity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = (try? c.decode([DayActivity].self, forKey: .activity)) ?? []
    }

    init(days: [DayActivity]) { self.days = days }
}

/// One UTC day's traffic.
///
/// The server omits days with no traffic — the client owns the calendar it is
/// drawing — so the graph fills the gaps itself (see `ContributionGraph`).
nonisolated struct DayActivity: Codable, Equatable, Identifiable {
    /// `YYYY-MM-DD`, in **UTC**, which is the timezone the proxy stamps rows
    /// in. Not relabelled locally: a day's figures are the server's buckets,
    /// and shifting the label without shifting the buckets would misattribute
    /// traffic near midnight.
    var date: String
    var requests: Int
    var errors: Int
    /// `promptTokens + completionTokens` — what the provider charged for.
    var billedTokens: Int
    var promptTokens: Int
    var completionTokens: Int
    var cachedTokens: Int
    var billedCalls: Int
    /// Of `requests`, those that reported usage — so a zero token figure is
    /// distinguishable from one that was never measured.
    var usageRequests: Int

    var id: String { date }

    /// Midnight UTC on this day, for charting and comparison.
    var day: Date? { DayActivity.formatter.date(from: date) }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    enum CodingKeys: String, CodingKey {
        case date
        case requests
        case errors
        case billedTokens = "billed_tokens"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case cachedTokens = "cached_tokens"
        case billedCalls = "billed_calls"
        case usageRequests = "usage_requests"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date             = (try? c.decode(String.self, forKey: .date)) ?? ""
        requests         = (try? c.decode(Int.self, forKey: .requests)) ?? 0
        errors           = (try? c.decode(Int.self, forKey: .errors)) ?? 0
        billedTokens     = (try? c.decode(Int.self, forKey: .billedTokens)) ?? 0
        promptTokens     = (try? c.decode(Int.self, forKey: .promptTokens)) ?? 0
        completionTokens = (try? c.decode(Int.self, forKey: .completionTokens)) ?? 0
        cachedTokens     = (try? c.decode(Int.self, forKey: .cachedTokens)) ?? 0
        billedCalls      = (try? c.decode(Int.self, forKey: .billedCalls)) ?? 0
        usageRequests    = (try? c.decode(Int.self, forKey: .usageRequests)) ?? 0
    }

    init(date: String, requests: Int = 0, errors: Int = 0, billedTokens: Int = 0,
         promptTokens: Int = 0, completionTokens: Int = 0, cachedTokens: Int = 0,
         billedCalls: Int = 0, usageRequests: Int = 0) {
        self.date = date
        self.requests = requests
        self.errors = errors
        self.billedTokens = billedTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.billedCalls = billedCalls
        self.usageRequests = usageRequests
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
