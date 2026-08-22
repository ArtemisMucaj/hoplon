import Foundation

/// The window the Guardrails screen reports over.
///
/// Maps onto the admin server's `?since=`/`?until=` half-open range. Selecting a
/// square in the contribution graph produces `.day`; the segmented control
/// produces the rolling windows.
nonisolated enum GuardrailsPeriod: Equatable, Hashable {
    case allTime
    case last7Days
    case last30Days
    /// One UTC day, as `YYYY-MM-DD` — the same bucket key `/activity` returns.
    case day(String)

    static let selectable: [GuardrailsPeriod] = [.last7Days, .last30Days, .allTime]

    var label: String {
        switch self {
        case .allTime:     return "All time"
        case .last7Days:   return "7 days"
        case .last30Days:  return "30 days"
        case .day(let d):  return GuardrailsPeriod.pretty(d)
        }
    }

    /// Whether this is one of the rolling windows the segmented control offers.
    var isRollingWindow: Bool {
        if case .day = self { return false }
        return true
    }

    /// The `?since=`/`?until=` pair, or `nil` for an unbounded end.
    ///
    /// Bounds are RFC3339 in **UTC**, matching how the proxy stamps rows: the
    /// server compares them as text against fixed-width timestamps, so the
    /// timezone has to be the one the rows are written in, not the user's.
    var bounds: (since: String?, until: String?) {
        switch self {
        case .allTime:
            return (nil, nil)
        case .last7Days:
            return (GuardrailsPeriod.daysAgo(7), nil)
        case .last30Days:
            return (GuardrailsPeriod.daysAgo(30), nil)
        case .day(let d):
            // Half-open: the server excludes `until`, so the next day's
            // midnight is the right upper bound for a single day.
            return (d, GuardrailsPeriod.nextDay(d))
        }
    }

    /// Query string to append to an admin URL, empty when unbounded.
    var query: String {
        let (since, until) = bounds
        var parts: [String] = []
        if let since { parts.append("since=\(since)") }
        if let until { parts.append("until=\(until)") }
        return parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
    }

    // MARK: - Date helpers

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Midnight UTC, `days` before today — so a "7 days" window starts at the
    /// beginning of a day rather than at this moment seven days ago, which is
    /// what makes it line up with the graph's squares.
    private static func daysAgo(_ days: Int) -> String {
        let cal = utc
        let start = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .day, value: -(days - 1), to: start) ?? start
        return DayActivity.formatter.string(from: from)
    }

    private static func nextDay(_ date: String) -> String? {
        guard let d = DayActivity.formatter.date(from: date),
              let next = utc.date(byAdding: .day, value: 1, to: d)
        else { return nil }
        return DayActivity.formatter.string(from: next)
    }

    /// "22 Aug 2026" for a `YYYY-MM-DD` key, in the user's locale.
    static func pretty(_ date: String) -> String {
        guard let d = DayActivity.formatter.date(from: date) else { return date }
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }
}
