import SwiftUI

/// A GitHub-style contribution calendar: one cell per day, columns are weeks,
/// rows are weekdays, shade is that day's token spend.
///
/// Laid out as an explicit grid rather than with Swift Charts. `RectangleMark`
/// in a continuous plot sizes each mark to the space between data points, which
/// renders as small dots with wide gaps — the opposite of the dense, nearly
/// touching cells this pattern depends on to read as a calendar. A grid also
/// makes hit-testing exact: each cell owns its own frame, so a hover or a click
/// resolves to one day instead of being mapped back through plot coordinates.
///
/// The server omits days with no traffic — it does not know which calendar the
/// client is drawing — so `fill` reinstates them as zeroes. Without that, a
/// quiet week would close the gap and shift every later column.
struct ContributionGraph: View {
    let days: [DayActivity]
    /// Days to draw, counting back from today.
    let span: Int
    /// The currently selected day, if the period is a single one.
    let selected: String?
    let onSelect: (DayActivity) -> Void

    /// Cell geometry, matching GitHub's proportions: a small square with a
    /// gap narrower than the square itself.
    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    @State private var hovered: DayActivity?

    /// Columns of one calendar week each, oldest first, every column a full
    /// Monday-to-Sunday run.
    private var weeks: [[DayActivity?]] { Self.weeks(days, span: span) }

    /// The busiest day, which anchors the shade buckets. Scaling to the
    /// observed maximum rather than a fixed ceiling keeps a quiet week legible
    /// instead of uniformly pale.
    private var peak: Int { max(days.map(\.billedTokens).max() ?? 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // `.leading` on both axes, and the whole calendar pinned left with a
            // trailing spacer: the grid is a fixed size (a cell is 11pt, not a
            // share of the width), so letting the row distribute slack pushes it
            // to the far edge away from its own weekday labels.
            HStack(alignment: .top, spacing: gap) {
                weekdayLabels
                VStack(alignment: .leading, spacing: 2) {
                    monthLabels
                    grid
                }
                Spacer(minLength: 0)
            }
            footer
        }
        // The calendar is intrinsically sized; let the surrounding column give
        // it exactly that and keep the slack on the trailing edge.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Grid

    private var grid: some View {
        HStack(spacing: gap) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { weekday in
                        cellView(week[weekday])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ day: DayActivity?) -> some View {
        if let day {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(shade(day.billedTokens))
                .frame(width: cell, height: cell)
                // The selected day keeps a ring rather than a colour change, so
                // its level stays readable while it is selected.
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(
                            day.date == selected ? Color.primary : .clear,
                            lineWidth: 1.5
                        )
                )
                .contentShape(Rectangle())
                .onTapGesture { onSelect(day) }
                .onHover { hovered = $0 ? day : (hovered?.date == day.date ? nil : hovered) }
                .help(Self.tooltip(day))
        } else {
            // A day before the range starts: holds the column's shape without
            // claiming there was no traffic.
            Color.clear.frame(width: cell, height: cell)
        }
    }

    // MARK: - Labels

    private var weekdayLabels: some View {
        // Mon/Wed/Fri only, as GitHub does — seven labels crowd an 11pt row.
        VStack(spacing: gap) {
            // Matches the month row above the grid (11pt + the VStack's 2pt
            // spacing), so row N of the labels lines up with row N of the cells.
            Color.clear.frame(height: 13)
            ForEach(0..<7, id: \.self) { weekday in
                Group {
                    if weekday % 2 == 0 {
                        Text(Self.weekdayName(weekday))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 26, height: cell, alignment: .trailing)
            }
        }
        // Without this the column takes its width from the widest *available*
        // space rather than its content, and the grid beside it gets pushed to
        // the far edge — the labels end up nowhere near the rows they name.
        .frame(width: 26)
    }

    private var monthLabels: some View {
        // One slot per column, blank unless that column opens a new month, so a
        // name sits above the week its month actually starts in.
        //
        // A month name is far wider than the 11pt column it labels, so each slot
        // is an overlay pinned to the column's leading edge rather than a sized
        // frame: constraining the text to the column width makes it wrap one
        // character per line ("A / p / r").
        HStack(spacing: gap) {
            ForEach(Array(monthColumns.enumerated()), id: \.offset) { _, label in
                Color.clear
                    .frame(width: cell, height: 11)
                    .overlay(alignment: .leading) {
                        if let label {
                            Text(label)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
            }
        }
    }

    /// A month name for each column that begins a new month, `nil` otherwise.
    private var monthColumns: [String?] {
        var seen: String?
        return weeks.map { week -> String? in
            guard let first = week.compactMap({ $0 }).first, let date = first.day else {
                return nil
            }
            let name = Self.monthName(date)
            defer { seen = name }
            // Suppress a label that would sit on top of the previous one.
            return name == seen ? nil : name
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let day = hovered ?? selectedDay {
                Text(Self.tooltip(day))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("\(total) tokens over \(activeDays) active days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Less").font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Self.levelColor(level))
                    .frame(width: cell, height: cell)
            }
            Text("More").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var selectedDay: DayActivity? {
        guard let selected else { return nil }
        return days.first { $0.date == selected }
    }

    private var total: String { TokenBars.compact(days.reduce(0) { $0 + $1.billedTokens }) }
    private var activeDays: Int { days.filter { $0.requests > 0 }.count }

    // MARK: - Shading

    /// Five discrete levels, as GitHub uses. Buckets rather than a continuous
    /// ramp because neighbouring days a few percent apart should read as the
    /// same weight; a continuous scale turns the whole calendar into noise.
    private func shade(_ tokens: Int) -> Color {
        guard tokens > 0 else { return Self.levelColor(0) }
        let ratio = Double(tokens) / Double(peak)
        let level =
            switch ratio {
            case ..<0.25: 1
            case ..<0.50: 2
            case ..<0.75: 3
            default: 4
            }
        return Self.levelColor(level)
    }

    static func levelColor(_ level: Int) -> Color {
        switch level {
        case 0:  return Color(nsColor: .quaternaryLabelColor).opacity(0.25)
        case 1:  return .accentColor.opacity(0.30)
        case 2:  return .accentColor.opacity(0.52)
        case 3:  return .accentColor.opacity(0.76)
        default: return .accentColor
        }
    }

    // MARK: - Tooltip

    /// The exact figures for one day — a shade says "busy", not "how much".
    static func tooltip(_ day: DayActivity) -> String {
        guard day.requests > 0 else {
            return "No traffic on \(GuardrailsPeriod.pretty(day.date))"
        }
        var parts = [
            "\(day.billedTokens.formatted()) tokens",
            "\(day.requests) request\(day.requests == 1 ? "" : "s")",
        ]
        if day.usageRequests > 0, day.cachedTokens > 0 {
            let hit = Double(day.cachedTokens) / Double(max(day.promptTokens, 1))
            parts.append("\(Int((hit * 100).rounded()))% cached")
        }
        // Says "measured" only when it was: a request whose backend reported no
        // usage still cost a call, and a zero there is not the same as no data.
        if day.usageRequests < day.requests {
            parts.append("\(day.requests - day.usageRequests) unmeasured")
        }
        if day.errors > 0 {
            parts.append("\(day.errors) error\(day.errors == 1 ? "" : "s")")
        }
        return "\(GuardrailsPeriod.pretty(day.date)) — " + parts.joined(separator: ", ")
    }

    // MARK: - Calendar

    /// UTC, matching the buckets the server groups by. Using the local calendar
    /// would place a day's cell on a different weekday than the figures it
    /// carries were summed over.
    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Monday = 0 … Sunday = 6.
    static func weekday(of date: Date) -> Int {
        (utc.component(.weekday, from: date) + 5) % 7
    }

    private static func weekdayName(_ index: Int) -> String {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][max(0, min(6, index))]
    }

    private static func monthName(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM"
        return f.string(from: date)
    }

    /// Bucket `span` days into calendar weeks, oldest column first.
    ///
    /// Each column is a full Monday-to-Sunday array, with `nil` for days that
    /// fall outside the range — so the first column is padded at its head and
    /// the last at its tail, and every row of the grid is the same weekday.
    /// That alignment is the whole point of the layout; without it a column
    /// straddles two weeks and the rows stop meaning anything.
    static func weeks(_ days: [DayActivity], span: Int) -> [[DayActivity?]] {
        let cal = utc
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(span - 1), to: today) else {
            return []
        }

        var columns: [[DayActivity?]] = []
        var column = [DayActivity?](repeating: nil, count: 7)
        var cursor = start

        while cursor <= today {
            let weekdayIndex = weekday(of: cursor)
            let key = DayActivity.formatter.string(from: cursor)
            column[weekdayIndex] = byDate[key] ?? DayActivity(date: key)
            // Sunday closes the column.
            if weekdayIndex == 6 {
                columns.append(column)
                column = [DayActivity?](repeating: nil, count: 7)
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        // The current, partial week.
        if column.contains(where: { $0 != nil }) { columns.append(column) }
        return columns
    }
}
