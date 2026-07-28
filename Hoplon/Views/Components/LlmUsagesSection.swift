import SwiftUI

/// The "what answers each job" section, shared by both LLM settings panes.
///
/// Both services expose the same `/api/llm/usages` shape, so the section is
/// written once and driven by closures: the owning pane supplies the usages,
/// the selectable (provider, model) pairs, and how to persist a choice.
///
/// This is deliberately the *first* thing on those screens. The endpoint list
/// below answers "which servers do I have"; this answers "which one actually
/// runs my extraction" — the question a user is usually there to settle.
struct LlmUsagesSection: View {
    let usages: [LlmUsage]
    /// Every (provider, model) pair that can be picked, built from the
    /// registered endpoints and their discovered models.
    let choices: [LlmChoice]
    /// Choices valid for an embedding usage — Copilot serves chat only, and an
    /// embedding model must match the store's pinned dimension.
    let embeddingChoices: [LlmChoice]
    var isBusy: Bool = false
    /// Persist a binding. `nil` clears the override so the usage inherits.
    let onSelect: (LlmUsage, LlmChoice?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("What each job uses") {
                if isBusy { ProgressView().controlSize(.small) }
            }
            Text("Each job can run on its own provider and model. Leave one on Inherit to follow the active endpoint.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if usages.isEmpty {
                CardContainer {
                    Text("No LLM jobs reported by this service.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                CardContainer {
                    VStack(spacing: 0) {
                        ForEach(Array(usages.enumerated()), id: \.element.id) { idx, usage in
                            usageRow(usage)
                            if idx < usages.count - 1 { Divider() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func usageRow(_ usage: LlmUsage) -> some View {
        let options = usage.isEmbedding ? embeddingChoices : choices
        // An inherited usage shows what it currently resolves to, but selects
        // the "Inherit" row — otherwise it would read as a deliberate choice.
        let selectedID = usage.inherited
            ? ""
            : LlmChoice(endpoint: usage.endpoint ?? "", model: usage.model).id

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: usage))
                .foregroundStyle(usage.inherited ? Color.secondary : Color.accentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(usage.label).font(.callout.weight(.medium))
                    if usage.requiresRestart {
                        Badge(text: "restart", color: .orange)
                    }
                }
                Text(usage.usageDescription)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // What it resolves to today, so an inherited row still says
                // which model will actually run.
                if usage.inherited, let resolved = resolvedLabel(usage) {
                    Text("follows \(resolved)")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Picker("", selection: Binding(
                get: { selectedID },
                set: { newID in
                    onSelect(usage, options.first { $0.id == newID })
                }
            )) {
                Text("Inherit").tag("")
                ForEach(options) { choice in
                    Text(choice.label).tag(choice.id)
                }
            }
            .labelsHidden()
            .frame(width: 240)
            .disabled(options.isEmpty || isBusy)
            .layoutPriority(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func resolvedLabel(_ usage: LlmUsage) -> String? {
        switch (usage.endpoint, usage.model) {
        case let (endpoint?, model?): return "\(endpoint) · \(model)"
        case let (endpoint?, nil):    return endpoint
        case let (nil, model?):       return model
        default:                      return nil
        }
    }

    private func icon(for usage: LlmUsage) -> String {
        if usage.isEmbedding { return "point.3.filled.connected.trianglepath.dotted" }
        switch usage.id {
        case "extract_memories":   return "sparkles.rectangle.stack"
        case "summarize", "summarize_overview": return "text.append"
        case "consolidate":        return "moon.stars"
        case "explain_code":       return "text.bubble"
        case "label_communities":  return "tag"
        case "expand_queries":     return "magnifyingglass"
        default:                    return "cpu"
        }
    }
}
