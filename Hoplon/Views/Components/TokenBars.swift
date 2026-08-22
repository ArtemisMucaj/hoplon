import Charts
import SwiftUI

/// Per-model token spend, split into what was served from the prompt cache and
/// what was billed at full rate, plus the completion tokens.
///
/// One bar per **(provider, model)** pair, never per model id: the proxy routes
/// to several providers, and Copilot and a local server can both serve
/// `qwen2.5-7b`. Collapsing those would average a degrading provider against a
/// healthy one.
///
/// The split is the point. A single "total tokens" bar cannot show that most of
/// a large prompt was a cache hit, which is the difference between an expensive
/// workload and a cheap one.
struct TokenBars: View {
    let models: [ModelStat]

    /// One stacked segment.
    private struct Segment: Identifiable {
        let id: String
        let label: String
        let kind: String
        let tokens: Int
    }

    private var segments: [Segment] {
        models.flatMap { model -> [Segment] in
            guard let usage = model.usage else { return [] }
            return [
                Segment(id: "\(model.id)|cached", label: model.label,
                        kind: "Cached prompt", tokens: usage.cachedTokens),
                Segment(id: "\(model.id)|prompt", label: model.label,
                        kind: "Billed prompt", tokens: usage.uncachedPromptTokens),
                Segment(id: "\(model.id)|completion", label: model.label,
                        kind: "Completion", tokens: usage.completionTokens),
            ]
        }
    }

    /// Tallest bar, so every row's width is comparable.
    private var rowHeight: CGFloat { 34 }

    @State private var hovered: ModelStat?

    /// The model whose bar sits under `point`.
    ///
    /// Resolved through the y scale rather than by dividing the height: the
    /// chart reserves space for the legend and axis, so arithmetic on the frame
    /// drifts by a row near the edges.
    private func model(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> ModelStat? {
        guard let plot = proxy.plotFrame else { return nil }
        let origin = geometry[plot].origin
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let label: String = proxy.value(atY: local.y) else { return nil }
        return models.first { $0.label == label }
    }

    /// One line carrying every figure the bar encodes, exactly.
    static func summary(_ model: ModelStat) -> String {
        guard let u = model.usage else { return model.label }
        var parts = [
            "\(u.billedTokens.formatted()) tokens",
            "\(u.cachedTokens.formatted()) cached",
            "\(u.uncachedPromptTokens.formatted()) billed prompt",
            "\(u.completionTokens.formatted()) completion",
        ]
        if let hit = u.cacheHitRate {
            parts.append("\(Int((hit * 100).rounded()))% cache hit")
        }
        parts.append("\(u.requests.formatted()) request\(u.requests == 1 ? "" : "s")")
        return "\(model.label) — " + parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart(segments) { segment in
                BarMark(
                    x: .value("Tokens", segment.tokens),
                    y: .value("Model", segment.label)
                )
                .foregroundStyle(by: .value("Kind", segment.kind))
                .cornerRadius(3)
                .accessibilityLabel("\(segment.label), \(segment.kind)")
                .accessibilityValue(segment.tokens.formatted())
            }
            .chartForegroundStyleScale([
                "Cached prompt": Color.teal,
                "Billed prompt": Color.accentColor,
                "Completion": Color.purple,
            ])
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let tokens = value.as(Int.self) {
                            Text(TokenBars.compact(tokens)).font(.caption2)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(preset: .extended, position: .leading) { _ in
                    AxisValueLabel(horizontalSpacing: 8).font(.caption)
                }
            }
            .chartLegend(position: .bottom, spacing: 12)
            // Hover readout. A stacked bar shows proportion, not amount, and
            // the axis only gives a rounded scale — so the exact split has to
            // be reachable with the pointer. `.help()` on a `BarMark` does
            // nothing (a mark is not a view), and an accessibility label only
            // reaches VoiceOver; the overlay is what a mouse can actually hit.
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                hovered = model(at: point, proxy: proxy, geometry: geo)
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: max(CGFloat(models.count) * rowHeight + 44, 120))

            // Reserves its line whether or not anything is hovered, so the
            // rows below do not jump as the pointer crosses the chart.
            Text(hovered.map { Self.summary($0) } ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            perModelDetail
        }
    }

    /// The figures a bar cannot carry: hit rate, retry multiplier, and the
    /// deduplicated conversation total where one exists.
    private var perModelDetail: some View {
        VStack(spacing: 0) {
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                if let usage = model.usage {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.label)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        stat("tokens", Self.compact(usage.billedTokens))
                            .help(Self.tokenBreakdown(usage))
                        stat("cache", usage.cacheHitRate.map { Self.percent($0) } ?? "—")
                            .help(Self.cacheBreakdown(usage))
                        stat("calls/req", usage.callsPerRequest.map { String(format: "%.2f", $0) } ?? "—")
                            .help(Self.callsBreakdown(usage))
                        stat("distinct", distinct(usage))
                            .help(distinctHelp(usage))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    // The whole row is a hit target, so the stat tooltips fire
                    // anywhere along it rather than only on the digits, and
                    // hovering here highlights the matching bar above.
                    .contentShape(Rectangle())
                    .onHover { hovered = $0 ? model : (hovered?.id == model.id ? nil : hovered) }
                    .background(
                        hovered?.id == model.id
                            ? Color.accentColor.opacity(0.06) : Color.clear
                    )
                    if index != models.count - 1 { Divider() }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title.uppercased()).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value).font(.callout).monospacedDigit()
        }
        .frame(width: 78, alignment: .trailing)
    }

    /// Prompt tokens with resent transcript prefixes counted once.
    ///
    /// Prefixed `~` when the proxy *inferred* the conversation edges from
    /// message prefixes rather than being told them: the figure is real but
    /// approximate, and presenting a heuristic as exact would overstate it.
    private func distinct(_ usage: ModelUsage) -> String {
        guard let distinct = usage.distinctPromptTokens else { return "—" }
        return (usage.inferredConversations ? "~" : "") + Self.compact(distinct)
    }

    private func distinctHelp(_ usage: ModelUsage) -> String {
        guard usage.distinctPromptTokens != nil else {
            return "Prompt tokens counting a resent transcript once. Unavailable: "
                + "this traffic carries no conversation key."
        }
        let base = "Prompt tokens with resent transcript prefixes counted once, over "
            + "\(usage.conversations ?? 0) conversation(s)."
        return usage.inferredConversations
            ? base + " Approximate — conversations were inferred from message prefixes."
            : base
    }

    /// Exact token counts behind the compacted figure. `compact` renders
    /// "1.4M", which is right for a table and useless for a comparison.
    static func tokenBreakdown(_ u: ModelUsage) -> String {
        """
        \(u.billedTokens.formatted()) billed tokens
        \(u.promptTokens.formatted()) prompt (\(u.cachedTokens.formatted()) cached, \
        \(u.uncachedPromptTokens.formatted()) billed at full rate)
        \(u.completionTokens.formatted()) completion
        over \(u.requests.formatted()) measured request\(u.requests == 1 ? "" : "s")
        """
    }

    static func cacheBreakdown(_ u: ModelUsage) -> String {
        guard u.cacheHitRate != nil else {
            return "No prompt tokens measured for this model."
        }
        return """
        \(u.cachedTokens.formatted()) of \(u.promptTokens.formatted()) prompt tokens \
        served from the prompt cache
        """
    }

    static func callsBreakdown(_ u: ModelUsage) -> String {
        """
        \(u.billedCalls.formatted()) backend call\(u.billedCalls == 1 ? "" : "s") \
        over \(u.requests.formatted()) request\(u.requests == 1 ? "" : "s") — \
        the multiplier corrective retries add to the bill
        """
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fk", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
