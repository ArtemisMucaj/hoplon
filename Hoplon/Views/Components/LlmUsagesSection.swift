import SwiftUI

/// The "what answers each job" section, shared by both LLM settings panes.
///
/// Both services expose the same `/api/llm/usages` shape, so the section is
/// written once and driven by closures: the owning pane supplies the usages,
/// the selectable (provider, model) pairs, and how to persist a choice.
///
/// This is deliberately the *first* thing on those screens. The server list
/// below answers "which backends do I have"; this answers "which one actually
/// runs my extraction" — the question a user is usually there to settle.
///
/// Every row names a concrete provider and model, including the ones the server
/// still resolves by inheritance: the dropdown already shows what will run, so
/// spelling that out a second time in prose said nothing the control didn't.
struct LlmUsagesSection: View {
    let usages: [LlmUsage]
    /// Every (provider, model) pair that can be picked, built from the
    /// registered endpoints and their discovered models.
    let choices: [LlmChoice]
    /// Choices valid for an embedding usage — Copilot serves chat only, and an
    /// embedding model must match the store's pinned dimension.
    let embeddingChoices: [LlmChoice]
    var isBusy: Bool = false
    /// Persist a binding.
    let onSelect: (LlmUsage, LlmChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("What each job uses") {
                if isBusy { ProgressView().controlSize(.small) }
            }

            CardContainer {
                if usages.isEmpty {
                    Text("No LLM jobs reported by this service.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
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
        // What runs this job today — an inherited usage still reports the pair
        // it resolves to, so the picker can show it as a normal selection.
        let current = usage.endpoint.map { LlmChoice(endpoint: $0, model: usage.model) }
        let options = optionList(for: usage, including: current)

        HStack(spacing: 10) {
            Image(systemName: icon(for: usage))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            // Natural width, first claim on it: job labels are short, and
            // letting the (much longer) picker compete for their space
            // hyphenates them into "Ex-tract me-mo-ries" and squeezes the
            // badge beside them down to an orange sliver.
            HStack(spacing: 6) {
                Text(usage.label).font(.callout)
                if usage.requiresRestart {
                    Badge(text: "restart", color: .orange)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)

            Spacer(minLength: 8)

            Picker("", selection: Binding(
                get: { current?.id ?? "" },
                set: { newID in
                    if let choice = options.first(where: { $0.id == newID }) {
                        onSelect(usage, choice)
                    }
                }
            )) {
                // Only reachable before any endpoint is registered; without a
                // tag matching the selection the picker would render blank.
                if current == nil { Text("Not set").tag("") }
                ForEach(options) { choice in
                    Text(choice.label).tag(choice.id)
                }
            }
            .labelsHidden()
            // Fixed, so every row's control lines up. Model ids run long and a
            // long one gets cut off — acceptable: the label leads with the
            // model, so what's lost is the endpoint name, not the model.
            .frame(width: 260)
            .disabled(options.isEmpty || isBusy)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // The one-line "what this job is for" lives here rather than under every
        // row: it's read once, and the pane is a settings screen, not a manual.
        .help(usage.usageDescription)
    }

    /// The pickable pairs for one usage, with whatever currently answers it
    /// folded in — a model that has not been discovered (endpoint unreachable,
    /// or pinned by hand) must still show as the selection rather than blank.
    private func optionList(for usage: LlmUsage, including current: LlmChoice?) -> [LlmChoice] {
        var options = usage.isEmbedding ? embeddingChoices : choices
        if let current, !options.contains(where: { $0.id == current.id }) {
            options.insert(current, at: 0)
        }
        return options
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
