import SwiftUI

/// Dedicated screen for the guardrails proxy: live running/stopped status,
/// start/stop controls, session activity sparkline, and the metrics rollup
/// served by the admin `/stats` endpoint (sortable tables).
struct GuardrailsView: View {
    @Environment(AppState.self) var state

    @State private var modelSort: [KeyPathComparator<ModelStat>] = [
        KeyPathComparator(\ModelStat.total, order: .reverse)
    ]
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
        } else if let stats = manager.stats, !stats.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summaryCards(stats)
                    if !stats.perModel.isEmpty { perModelSection(stats.perModel) }
                    if !stats.errors.isEmpty { errorsSection(stats.errors) }
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

    // MARK: - Summary cards

    private func summaryCards(_ stats: GuardrailsStats) -> some View {
        HStack(spacing: 12) {
            MetricCard(title: "Requests", value: "\(stats.totalRequests)", color: .blue)
            MetricCard(title: "Tool Calls", value: "\(stats.totalToolCalls)", color: .purple)
            MetricCard(title: "Succeeded", value: "\(stats.totalSucceeded)", color: .green)
            MetricCard(title: "Errors", value: "\(stats.totalErrors)", color: .orange)
            MetricCard(
                title: "Success Rate",
                value: stats.overallSuccessRate.map { Self.percent($0) } ?? "—",
                color: .teal
            )
        }
    }

    // MARK: - Per-model table

    private func perModelSection(_ rows: [ModelStat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per Model").font(.headline)
            Table(rows.sorted(using: modelSort), sortOrder: $modelSort) {
                TableColumn("Model", value: \.model) { row in
                    Text(row.model).lineLimit(1).truncationMode(.middle)
                }
                TableColumn("Total", value: \.total) { row in
                    Text("\(row.total)").monospacedDigit()
                }
                .width(min: 50, ideal: 60)
                TableColumn("Tools", value: \.toolCalls) { row in
                    Text("\(row.toolCalls)").monospacedDigit()
                }
                .width(min: 50, ideal: 60)
                TableColumn("OK", value: \.succeeded) { row in
                    Text("\(row.succeeded)").monospacedDigit()
                }
                .width(min: 50, ideal: 60)
                TableColumn("Errors", value: \.errors) { row in
                    Text("\(row.errors)")
                        .monospacedDigit()
                        .foregroundStyle(row.errors > 0 ? Color.orange : Color.primary)
                }
                .width(min: 50, ideal: 60)
                TableColumn("Rate") { row in
                    Text(row.successRate.map { Self.percent($0) } ?? "—").monospacedDigit()
                }
                .width(min: 56, ideal: 64)
            }
            .frame(height: tableHeight(rows: rows.count))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Errors table

    private func errorsSection(_ rows: [ErrorStat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Errors").font(.headline)
            Table(rows.sorted(using: errorSort), sortOrder: $errorSort) {
                TableColumn("Category", value: \.errorCategory) { row in
                    Text(row.errorCategory).help(row.detail ?? "")
                }
                TableColumn("Tool") { row in
                    Text(row.toolName ?? "—").foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 140)
                TableColumn("Model", value: \.model) { row in
                    Text(row.model).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .width(min: 100, ideal: 140)
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
