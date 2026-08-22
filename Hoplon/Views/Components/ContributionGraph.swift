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

    /// Gap between cells, and the width reserved for the weekday labels. Both
    /// fixed; the cell itself is derived from whatever width is left.
    private let gap: CGFloat = 3
    private let labelWidth: CGFloat = 30

    /// Width the calendar was actually given, measured rather than assumed.
    @State private var available: CGFloat = 0
    @State private var hovered: DayActivity?

    /// Everything derived from `days`, computed once per change rather than
    /// per access.
    ///
    /// These were computed properties, which SwiftUI re-evaluates on every
    /// read. `cell` read `weeks`, and each of ~371 cells read `cell` twice — so
    /// a single render rebuilt the whole year's calendar (dictionary, date
    /// arithmetic and all) hundreds of times, and did it again on every hover,
    /// because a hover mutates state and re-renders the view. That is what made
    /// the pane feel slow; nothing here touches the database.
    private struct Layout {
        var weeks: [[DayActivity?]] = []
        var monthColumns: [String?] = []
        var peak: Int = 1
    }

    @State private var layout = Layout()

    /// Cell edge, sized so the year's columns exactly fill the available width.
    ///
    /// A fixed 11pt cell leaves the calendar short of its container on a wide
    /// window — the year is all there, drawn smaller than the space allows.
    /// Deriving it instead means the graph grows with the pane, and the bound
    /// keeps it from turning into chunky tiles in a very wide one or vanishing
    /// in a narrow one.
    private var cell: CGFloat {
        let columns = CGFloat(max(layout.weeks.count, 1))
        // Each column now occupies `cell + gap`, so the gaps are inside the
        // per-column pitch rather than between columns.
        let usable = available - labelWidth - columns * gap
        guard usable > 0 else { return 11 }
        return (usable / columns).clamped(to: 8...18)
    }

    private var weeks: [[DayActivity?]] { layout.weeks }
    private var monthColumns: [String?] { layout.monthColumns }
    private var peak: Int { layout.peak }

    /// Rebuild the derived layout. Called when the data or the span changes,
    /// not on every read.
    private func rebuildLayout() {
        let weeks = Self.weeks(days, span: span)
        layout = Layout(
            weeks: weeks,
            monthColumns: Self.monthColumns(for: weeks),
            peak: max(days.map(\.billedTokens).max() ?? 0, 1)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // `.leading` on both axes: the labels sit immediately beside the
            // rows they name, and the grid — now sized to consume the remaining
            // width — starts right after them.
            HStack(alignment: .top, spacing: gap) {
                weekdayLabels
                VStack(alignment: .leading, spacing: 2) {
                    monthLabels
                    grid
                }
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Measure, so the cell size can be derived from the width the parent
        // actually offers rather than guessed at.
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { available = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in available = new }
            }
        )
        .onAppear { rebuildLayout() }
        .onChange(of: days) { _, _ in rebuildLayout() }
        .onChange(of: span) { _, _ in rebuildLayout() }
    }

    // MARK: - Grid

    private var grid: some View {
        // No spacing here: each cell's frame already carries its gap, which is
        // what lets hit areas meet instead of leaving gaps between them.
        HStack(spacing: 0) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: 0) {
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
                // The hit area covers the cell *and* its share of the gaps
                // around it, so moving across the grid hands off from one cell
                // straight to the next. Without it the 3pt gaps are dead space:
                // the pointer leaves a cell, `hovered` clears, and the readout
                // blanks for a frame between every pair of cells.
                //
                // Applied after the visual frame, so only hit-testing grows —
                // the drawn square is unchanged.
                .frame(width: cell + gap, height: cell + gap)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(day) }
                // Hover drives the readout under the grid rather than a
                // per-cell `.help()`. `.help()` built a formatted tooltip
                // string for all ~371 cells on every render, including the
                // renders that hovering itself triggers; the readout formats
                // one string for the cell actually under the pointer.
                .onHover { inside in
                    if inside {
                        if hovered?.date != day.date { hovered = day }
                    } else if hovered?.date == day.date {
                        hovered = nil
                    }
                }
        } else {
            // A day before the range starts: holds the column's shape without
            // claiming there was no traffic. Same footprint as a real cell,
            // gap included, so the columns stay aligned.
            Color.clear.frame(width: cell + gap, height: cell + gap)
        }
    }

    // MARK: - Labels

    private var weekdayLabels: some View {
        // Mon/Wed/Fri only, as GitHub does — seven labels crowd an 11pt row.
        // Spacing 0 and a cell+gap row height, matching the grid's pitch.
        VStack(spacing: 0) {
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
                .frame(width: labelWidth - gap, height: cell + gap, alignment: .trailing)
            }
        }
        // Without this the column takes its width from the widest *available*
        // space rather than its content, and the grid beside it gets pushed to
        // the far edge — the labels end up nowhere near the rows they name.
        .frame(width: labelWidth - gap)
    }

    private var monthLabels: some View {
        // One slot per column, blank unless that column opens a new month, so a
        // name sits above the week its month actually starts in.
        //
        // A month name is far wider than the 11pt column it labels, so each slot
        // is an overlay pinned to the column's leading edge rather than a sized
        // frame: constraining the text to the column width makes it wrap one
        // character per line ("A / p / r").
        HStack(spacing: 0) {
            ForEach(Array(monthColumns.enumerated()), id: \.offset) { _, label in
                Color.clear
                    .frame(width: cell + gap, height: 11)
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
    static func monthColumns(for weeks: [[DayActivity?]]) -> [String?] {
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
            // One `Text` whose content changes, never a branch between two
            // views. Swapping the readout for a summary made the 3pt gaps
            // between cells flash: leaving a cell cleared `hovered`, the
            // summary appeared for one frame, and the next cell replaced it.
            // Empty when nothing is hovered, so the line holds its height and
            // the row below never shifts.
            Text(hovered.map { Self.tooltip($0) }
                    ?? selectedDay.map { Self.tooltip($0) }
                    ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // No implicit animation: a crossfade on a label that tracks the
                // pointer reads as lag, not polish.
                .animation(nil, value: hovered?.date)
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

    /// Built once. A `DateFormatter` is expensive to construct, and this was
    /// making a fresh one per column on every render.
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM"
        return f
    }()

    private static func monthName(_ date: Date) -> String {
        monthFormatter.string(from: date)
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

private extension CGFloat {
    /// Clamp to a closed range — used to keep a derived cell size sane at both
    /// extremes of window width.
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
