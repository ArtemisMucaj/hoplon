import SwiftUI

/// Dedicated screen for the guardrails proxy: live running/stopped status,
/// start/stop controls, a per-day token calendar, and the metrics rollup served
/// by the admin `/stats` endpoint over the selected period.
struct GuardrailsView: View {
    @Environment(AppState.self) var state

    @State private var errorSort: [KeyPathComparator<ErrorStat>] = [
        KeyPathComparator(\ErrorStat.count, order: .reverse)
    ]

    private var manager: GuardrailsManager { state.guardrailsManager }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Guardrails")
        .onAppear {
            if manager.isRunning { manager.refresh() }
        }
    }

    // MARK: - Header

    private var header: some View {
        ServiceHeader(
            systemImage: "shield.lefthalf.filled",
            status: state.guardrailsStatus,
            subtitle: manager.isRunning
                ? "Proxy \(manager.proxyEndpoint)  ·  Admin \(manager.adminBase)"
                : "OpenAI-compatible tool-call repair proxy"
        ) {
            controls
        }
    }

    @ViewBuilder
    private var controls: some View {
        if manager.isRunning {
            Button {
                manager.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                state.guardrailsEnabled = false
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
        } else if manager.isStarting {
            Button("Starting…") {}.disabled(true)
        } else {
            Button {
                state.guardrailsEnabled = true
            } label: {
                Label("Start", systemImage: "play.circle.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.green)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = manager.lastError, !manager.isRunning, !manager.isStarting {
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Could not start guardrails",
                message: error
            )
        } else if !manager.isRunning && !manager.isStarting {
            EmptyStateView(
                icon: "shield.slash",
                title: "Guardrails is stopped",
                message: "Start the proxy to repair malformed tool calls from your local model and collect metrics."
            )
        } else if manager.stats?.isEmpty == false || !manager.activity.isEmpty {
            // Either source is enough to show the screen. `/stats` and
            // `/activity` are fetched independently, so requiring a rollup hid
            // the calendar whenever the rollup was slower or failing — the
            // graph would sit behind "No metrics yet" with its data already in
            // hand. The rollup-derived sections still render only when there is
            // a rollup.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    activitySection
                    periodPicker
                    if let stats = manager.stats, !stats.isEmpty {
                        summaryCards(stats)
                        if !stats.measured.isEmpty { tokensSection(stats) }
                        if !stats.perModel.isEmpty { perModelSection(stats.perModel) }
                        if !stats.errors.isEmpty { errorsSection(stats.errors) }
                    }
                    if let info = manager.info { infoSection(info) }
                }
                .padding()
            }
        } else {
            EmptyStateView(
                icon: "chart.bar.xaxis",
                title: "No metrics yet",
                message: "Stats appear here once the proxy has handled tool-enabled requests."
            )
        }
    }

    // MARK: - Activity calendar

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily Tokens").font(.headline)
                Spacer()
                // The graph buckets by UTC, because that is what the proxy
                // stamps rows in. Saying so beats silently mislabelling a day.
                Text("UTC days")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ContributionGraph(
                days: manager.activity,
                span: manager.graphDays,
                selected: selectedDay
            ) { day in
                // Tapping the selected day again clears it, so the graph is not
                // a one-way trip into a single-day view.
                if selectedDay == day.date {
                    manager.period = .last30Days
                } else {
                    manager.period = .day(day.date)
                }
            }
        }
    }

    private var selectedDay: String? {
        if case .day(let d) = manager.period { return d }
        return nil
    }

    // MARK: - Period

    private var periodPicker: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(
                get: { manager.period.isRollingWindow ? manager.period : .last30Days },
                set: { manager.period = $0 }
            )) {
                ForEach(GuardrailsPeriod.selectable, id: \.self) { period in
                    Text(period.label).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // A specific day comes from the graph, not this control, so it is
            // shown as a dismissible chip rather than a fourth segment.
            if let day = selectedDay {
                Button {
                    manager.period = .last30Days
                } label: {
                    HStack(spacing: 4) {
                        Text(GuardrailsPeriod.pretty(day))
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .help("Showing one day — click to go back to a rolling window")
            }
            Spacer()
        }
    }

    // MARK: - Summary cards

    private func summaryCards(_ stats: GuardrailsStats) -> some View {
        HStack(spacing: 12) {
            MetricCard(title: "Requests", value: "\(stats.totalRequests)", color: .blue)
                .help("\(stats.totalRequests.formatted()) guarded requests over this period")
            MetricCard(
                title: "Billed Tokens",
                value: TokenBars.compact(stats.totalBilledTokens),
                color: .indigo
            )
            // The card compacts to "2.7M"; the exact count belongs somewhere.
            .help("\(stats.totalBilledTokens.formatted()) tokens billed — prompt plus completion, across every model that reported usage")
            MetricCard(
                title: "Cache Hit",
                value: stats.overallCacheHitRate.map { TokenBars.percent($0) } ?? "—",
                color: .teal
            )
            .help(
                stats.overallCacheHitRate == nil
                    ? "No prompt tokens were measured over this period."
                    : "\(stats.totalCachedTokens.formatted()) of \(stats.totalPromptTokens.formatted()) prompt tokens served from the prompt cache"
            )
            MetricCard(title: "Tool Calls", value: "\(stats.totalToolCalls)", color: .purple)
            MetricCard(title: "Errors", value: "\(stats.totalErrors)", color: .orange)
            MetricCard(
                title: "Success Rate",
                value: stats.overallSuccessRate.map { Self.percent($0) } ?? "—",
                color: .green
            )
        }
    }

    // MARK: - Tokens

    private func tokensSection(_ stats: GuardrailsStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tokens by Model").font(.headline)
            TokenBars(models: stats.measured)
        }
    }

    // MARK: - Per-model table

    private func perModelSection(_ rows: [ModelStat]) -> some View {
        // Sorted once. Sorting inside the `ForEach` re-ran it for every divider
        // check as well, which is O(n log n) per row on every re-render — and
        // the 5s poll re-renders this pane.
        let sorted = rows.sorted { $0.total > $1.total }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Requests by Model").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, row in
                    HStack {
                        Text(row.provider)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        Text(row.model)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        cell("\(row.total)")
                            .help("\(row.total.formatted()) guarded requests")
                        cell("\(row.toolCalls)")
                            .help("\(row.toolCalls.formatted()) of them were a real tool call")
                        cell("\(row.errors)", tint: row.errors > 0 ? .orange : .primary)
                            .help("\(row.errors.formatted()) the guardrails could not repair")
                        cell(row.successRate.map { Self.percent($0) } ?? "—")
                            .help(
                                row.successRate == nil
                                    ? "This model made no tool call, so there is no rate to report."
                                    : "\(row.succeeded.formatted()) of \(row.succeeded + row.errors) tool calls succeeded"
                            )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    if index != sorted.count - 1 { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    headerCell("total")
                    headerCell("tools")
                    headerCell("errors")
                    headerCell("rate")
                }
                .padding(.trailing, 12)
                .offset(y: -16)
            }
            .padding(.top, 16)
        }
    }

    private func cell(_ text: String, tint: Color = .primary) -> some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(tint)
            .frame(width: 62, alignment: .trailing)
    }

    private func headerCell(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .frame(width: 62, alignment: .trailing)
    }

    // MARK: - Errors table

    private func errorsSection(_ rows: [ErrorStat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Errors").font(.headline)
            Table(rows.sorted(using: errorSort), sortOrder: $errorSort) {
                TableColumn("Category") { row in
                    // Optional on the wire: an unfixed failure need not be
                    // categorised, and "—" is honest where "unknown" invents one.
                    Text(row.errorCategory ?? "—").help(row.detail ?? "")
                }
                TableColumn("Tool") { row in
                    Text(row.toolName ?? "—").foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 140)
                TableColumn("Model", value: \.label) { row in
                    Text(row.label).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .width(min: 140, ideal: 190)
                TableColumn("Count", value: \.count) { row in
                    Text("\(row.count)").monospacedDigit()
                }
                .width(min: 50, ideal: 60)
            }
            .frame(height: tableHeight(rows: rows.count))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Tables inside a ScrollView need an explicit height: header + rows, capped.
    private func tableHeight(rows: Int) -> CGFloat {
        min(CGFloat(rows) * 28 + 32, 320)
    }

    // MARK: - Info

    private func infoSection(_ info: GuardrailsInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Proxy Info").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(info.rows.enumerated()), id: \.offset) { idx, row in
                    HStack(alignment: .top) {
                        Text(row.key)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 180, alignment: .leading)
                        Text(row.value)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    if idx != info.rows.count - 1 { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
