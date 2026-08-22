import Charts
import SwiftUI

/// A GitHub-style contribution calendar: one square per day, columns are weeks,
/// rows are weekdays, shade is that day's token spend.
///
/// Built on Swift Charts' `RectangleMark` rather than a hand-rolled grid so the
/// squares inherit the framework's layout, accessibility and theme handling.
///
/// The server omits days with no traffic — it doesn't know which calendar the
/// client is drawing — so `fill` reinstates them as zeroes. Without that, a
/// quiet week would close the gap and shift every later column, which reads as
/// "no such day" rather than "nothing happened".
struct ContributionGraph: View {
    let days: [DayActivity]
    /// Days to draw, counting back from today.
    let span: Int
    /// The currently selected day, if the period is a single one.
    let selected: String?
    let onSelect: (DayActivity) -> Void

    private var cells: [DayActivity] { Self.fill(days, span: span) }

    /// The busiest day, which anchors the colour scale. Scaling to the maximum
    /// rather than a fixed ceiling keeps a light week legible instead of
    /// uniformly pale.
    private var peak: Int { max(cells.map(\.billedTokens).max() ?? 0, 1) }

    var body: some View {
        Chart(cells) { day in
            if let date = day.day {
                RectangleMark(
                    x: .value("Week", Self.week(of: date)),
                    y: .value("Weekday", Self.weekday(of: date))
                )
                .foregroundStyle(by: .value("Tokens", day.billedTokens))
                .opacity(isDimmed(day) ? 0.35 : 1)
                .cornerRadius(3)
            }
        }
        // A continuous ramp from the control background to the accent colour,
        // so an empty day reads as part of the grid rather than as a hole in it.
        //
        // Anchored to the busiest day rather than left to infer its own bounds:
        // an explicit domain is what makes a quiet week span the whole ramp
        // instead of rendering uniformly pale.
        .chartForegroundStyleScale(
            domain: 0...peak,
            range: Gradient(colors: [
                Color(nsColor: .quaternaryLabelColor).opacity(0.35),
                .accentColor.opacity(0.45),
                .accentColor,
            ])
        )
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(values: [1, 3, 5]) { value in
                AxisValueLabel {
                    if let raw = value.as(Int.self) {
                        Text(Self.weekdayName(raw)).font(.caption2)
                    }
                }
            }
        }
        // The x values are week offsets counting back from this week, so a
        // numeric label would read "-7" rather than a date. The squares are
        // located by their tooltip and the selection chip instead.
        .chartXAxis(.hidden)
        .chartYScale(domain: .automatic(reversed: true))
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        select(at: location, proxy: proxy, geometry: geo)
                    }
            }
        }
        .frame(height: 132)
        .accessibilityLabel("Token spend per day")
    }

    /// A day is dimmed when another one is explicitly selected, so the choice
    /// is visible without moving anything.
    private func isDimmed(_ day: DayActivity) -> Bool {
        guard let selected else { return false }
        return day.date != selected
    }

    private func select(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plot = proxy.plotFrame else { return }
        let origin = geometry[plot].origin
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let week: Int = proxy.value(atX: local.x),
              let weekday: Int = proxy.value(atY: local.y)
        else { return }
        // Match on the same (week, weekday) coordinates the marks are placed
        // at, so a tap resolves to the square actually under the cursor.
        guard let hit = cells.first(where: {
            guard let d = $0.day else { return false }
            return Self.week(of: d) == week && Self.weekday(of: d) == weekday
        }) else { return }
        onSelect(hit)
    }

    // MARK: - Calendar

    /// UTC, matching the buckets the server groups by. Using the local calendar
    /// would place a day's square on a different weekday than the figures it
    /// carries were summed over.
    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Weeks before the current one, negated so the newest column sits right.
    ///
    /// The padding term is the days *remaining* in this week, not today's index
    /// within it. Using the index only lines the columns up when today is a
    /// Monday; on any other day a column straddles two calendar weeks — with
    /// today on a Sunday, that Sunday's own week and the previous Monday-to-
    /// Saturday would share a column.
    private static func week(of date: Date) -> Int {
        let cal = utc
        let start = cal.startOfDay(for: Date())
        let days = cal.dateComponents([.day], from: date, to: start).day ?? 0
        let remainingThisWeek = 6 - ((cal.component(.weekday, from: start) + 5) % 7)
        return -((days + remainingThisWeek) / 7)
    }

    /// Monday = 0 … Sunday = 6.
    private static func weekday(of date: Date) -> Int {
        (utc.component(.weekday, from: date) + 5) % 7
    }

    private static func weekdayName(_ index: Int) -> String {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][max(0, min(6, index))]
    }

    /// Reinstate the days the server omitted, so the calendar is contiguous.
    static func fill(_ days: [DayActivity], span: Int) -> [DayActivity] {
        let cal = utc
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let today = cal.startOfDay(for: Date())
        return (0..<span).compactMap { offset -> DayActivity? in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = DayActivity.formatter.string(from: date)
            return byDate[key] ?? DayActivity(date: key)
        }
    }
}
