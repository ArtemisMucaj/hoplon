import SwiftUI

/// The namespace Overview tab: high-signal architecture insight aggregated
/// across the namespace's repositories — entry-point features, cross-service
/// channels, the repos + language mix, cross-repo dependencies, and a couplings
/// (architectural-risk) summary. Everything is fetched lazily on appear; each
/// section degrades to a friendly "none" state rather than an error.
struct NamespaceInsightView: View {
    let namespace: String
    let repos: [Repository]

    @Environment(AppState.self) private var state

    @State private var features: [CodeFeature] = []
    @State private var channels: ChannelGraph?
    @State private var couplingByRepo: [String: CouplingReport] = [:]
    @State private var loading = true

    // Per-section expand flags — lists show a capped preview with a "Show more".
    @State private var expandFeatures = false
    @State private var expandCouplings = false
    @State private var expandChannels = false
    @State private var expandProducers = false
    @State private var expandConsumers = false

    /// Community id → LLM display name (else id), per repo — so coupling rows
    /// can say WHICH module is fragile, not just show a hash id.
    @State private var clusterNamesByRepo: [String: [String: String]] = [:]
    /// Per-row disclosure for the couplings list — keyed `repo|communityId`.
    @State private var expandedCoupling: Set<String> = []
    /// Feature ids whose explanation body is collapsed. A long explanation is a
    /// lot of vertical space, so the user can fold it away and keep scanning.
    @State private var collapsedExplanations: Set<String> = []
    /// Per-row disclosure for the features list — keyed by feature id.
    @State private var expandedFeature: Set<String> = []
    /// Features whose expanded call flow shows the FULL path instead of the
    /// preview — keyed by feature id (flat-list fallback only).
    @State private var expandedCallFlow: Set<String> = []
    /// Open nodes in the call-flow TREES — keyed `featureId|symbol`. The root
    /// uses inverted membership (present = collapsed) so it starts open
    /// without seeding state per feature.
    @State private var expandedCallNode: Set<String> = []

    /// Call-flow nodes shown before the per-feature "Show all" kicks in.
    private let callFlowPreview = 8

    private let previewCount = 10

    private var repoNames: [String] { repos.map(\.name).sorted() }
    private var totalFiles: Int { repos.reduce(0) { $0 + $1.fileCount } }
    private var totalChunks: Int { repos.reduce(0) { $0 + $1.chunkCount } }

    /// Aggregated language → file count across the namespace's repos.
    private var languages: [(language: String, fileCount: Int)] {
        var acc: [String: Int] = [:]
        for r in repos { for (lang, stat) in r.languages { acc[lang, default: 0] += stat.fileCount } }
        return acc.map { (language: $0.key, fileCount: $0.value) }.sorted { $0.fileCount > $1.fileCount }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statsRow
                featuresSection
                couplingsSection
                channelsSection
                reposSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
    }

    // MARK: - Stats

    private var statsRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
            MetricCard(title: "Repositories", value: "\(repos.count)", systemImage: "folder")
            MetricCard(title: "Files", value: Format.count(totalFiles), systemImage: "doc")
            MetricCard(title: "Chunks", value: Format.count(totalChunks), systemImage: "square.grid.3x3")
            MetricCard(title: "Features", value: loading ? "…" : "\(features.count)", systemImage: "bolt")
        }
    }

    // MARK: - Features

    @ViewBuilder
    private var featuresSection: some View {
        SectionHeader("Features")
        if loading {
            loadingRow
        } else if features.isEmpty {
            emptyRow("No entry-point features detected in this namespace.")
        } else {
            Text("Entry points ranked by how much of the codebase they transitively drive. Click a row for the call flow.")
                .font(.caption).foregroundStyle(.secondary)
            let shown = expandFeatures ? features : Array(features.prefix(previewCount))
            CardContainer {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { idx, f in
                        featureRow(f)
                        if idx < shown.count - 1 { Divider() }
                    }
                    showMoreFooter(total: features.count, expanded: $expandFeatures)
                }
            }
        }
    }

    private func featureRow(_ f: CodeFeature) -> some View {
        let isOpen = expandedFeature.contains(f.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { expandedFeature.remove(f.id) } else { expandedFeature.insert(f.id) }
            } label: {
                HStack(spacing: 10) {
                    CriticalityDot(value: f.criticality)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.shortName).font(.callout.weight(.medium)).lineLimit(1)
                        Text(f.entryPoint).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if repos.count > 1 { Badge(text: f.repositoryName, color: .secondary) }
                    Text("drives \(f.reach) symbols · depth \(f.depth)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", f.criticality * 100))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 40, alignment: .trailing)
                        .help("Criticality — a weighted mix of reach (symbols driven), call-chain depth, and file spread")
                    // An LLM explanation streaming in the background stays
                    // visible even with the row collapsed.
                    if state.codesearchManager.featureExplain.isRunning(f.id) {
                        ProgressView().controlSize(.mini)
                            .help("LLM explanation in progress…")
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
            if isOpen {
                featureDetail(f)
                    .padding(.leading, 34).padding(.trailing, 12).padding(.bottom, 10)
            }
        }
    }

    /// Expanded feature detail: the raw signals behind the score, then the
    /// actual call flow (BFS order, indented by depth) with file:line hooks.
    @ViewBuilder
    private func featureDetail(_ f: CodeFeature) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From \(f.shortName), \(f.reach) symbols across \(f.fileCount) files are reachable, up to \(f.depth) calls deep.")
                .font(.caption).foregroundStyle(.secondary)
            explainSection(f)
            if !f.path.isEmpty, let root = f.path.first,
               f.path.count > 1, f.path.dropFirst().allSatisfy({ $0.caller != nil }) {
                // Parentage available → a real collapsible call tree. Only the
                // entry point starts open; every arrow expands on click.
                let children = Dictionary(grouping: f.path.filter { $0.caller != nil },
                                          by: { $0.caller ?? "" })
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Text("Call flow").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Button("Expand all") {
                            expandedCallNode.formUnion(children.keys.map { "\(f.id)|\($0)" })
                            expandedCallNode.remove("\(f.id)|\(root.symbol)")   // root: inverted (open by default)
                        }
                        Button("Collapse all") {
                            expandedCallNode = expandedCallNode.filter { !$0.hasPrefix("\(f.id)|") }
                            expandedCallNode.insert("\(f.id)|\(root.symbol)")   // root: inverted → closed
                        }
                    }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.blue)
                    CallFlowNode(featureId: f.id, node: root, children: children,
                                 level: 0, expanded: $expandedCallNode)
                }
            } else if !f.path.isEmpty {
                // No parentage (older server payload): the flat BFS list.
                let flowOpen = expandedCallFlow.contains(f.id)
                let nodes = flowOpen ? f.path : Array(f.path.prefix(callFlowPreview))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Call flow").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                        HStack(spacing: 6) {
                            Text(String(repeating: "   ", count: node.depth) + (node.depth == 0 ? "▶" : "→"))
                                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            Text(shortSymbol(node.symbol))
                                .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                .help(node.symbol)
                            Spacer()
                            Text("\((node.filePath as NSString).lastPathComponent):\(node.line)")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    if f.path.count > callFlowPreview {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if flowOpen { expandedCallFlow.remove(f.id) } else { expandedCallFlow.insert(f.id) }
                            }
                        } label: {
                            Label(flowOpen ? "Show less" : "Show all \(f.path.count) calls",
                                  systemImage: flowOpen ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain).foregroundStyle(.blue)
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    /// "Vendor\Models\Home#method" → "Home#method".
    private func shortSymbol(_ fqn: String) -> String {
        fqn.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? fqn
    }

    // MARK: - Feature explanation (LLM)

    /// The explain block inside an expanded feature: a kick-off button, or the
    /// in-flight/finished explanation. State lives on `FeatureExplainManager`
    /// (app-scoped), so the stream keeps running when the user leaves the page
    /// and the text is waiting on return.
    @ViewBuilder
    private func explainSection(_ f: CodeFeature) -> some View {
        let manager = state.codesearchManager.featureExplain!
        if let st = manager.state(for: f.id) {
            let collapsed = collapsedExplanations.contains(f.id)
            let hasText = !st.text.isEmpty
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if st.phase == .running {
                        ThinkingIndicator(label: "Thinking")
                    } else {
                        // The title doubles as the collapse toggle once there's a
                        // body to fold; a chevron shows the state.
                        Button {
                            toggleCollapsed(f.id)
                        } label: {
                            HStack(spacing: 5) {
                                if hasText {
                                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                                Label("Explanation", systemImage: "sparkles")
                                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasText)
                    }
                    Spacer()
                    // Regenerate: bypass the server cache and recompute — for a
                    // bad answer or after switching to a different model.
                    if st.phase != .running, hasText {
                        Button {
                            regenerateExplain(f)
                        } label: {
                            Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Regenerate with the active model (ignores the cached answer)")
                    }
                    if hasText {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(st.text, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy the explanation")
                    }
                    // Only a Cancel affordance while streaming — a finished
                    // explanation is dismissed by collapsing it, so no ✕ needed.
                    if st.phase == .running {
                        Button {
                            manager.dismiss(featureId: f.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel the explanation")
                    }
                }
                if case .failed(let message) = st.phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Try again") { startExplain(f) }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.blue)
                }
                if hasText && !collapsed {
                    // Long explanations scroll inside a capped box instead of
                    // stretching the whole feature row to arm's length.
                    ScrollView {
                        ExplanationView(text: st.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
        } else {
            Button {
                startExplain(f)
            } label: {
                Label("Explain", systemImage: "sparkles").font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Stream an LLM explanation of this feature's call flow — it keeps running if you leave this page")
        }
    }

    private func startExplain(_ f: CodeFeature, regenerate: Bool = false) {
        state.codesearchManager.featureExplain.explain(
            featureId: f.id,
            symbol: f.entryPoint,
            repository: f.repositoryName.isEmpty ? nil : f.repositoryName,
            regenerate: regenerate
        )
    }

    /// Recompute the explanation, ignoring the server-side cache — used after a
    /// bad answer or a model switch. Reveals the body so the fresh stream shows.
    private func regenerateExplain(_ f: CodeFeature) {
        collapsedExplanations.remove(f.id)
        startExplain(f, regenerate: true)
    }

    private func toggleCollapsed(_ id: String) {
        if collapsedExplanations.contains(id) {
            collapsedExplanations.remove(id)
        } else {
            collapsedExplanations.insert(id)
        }
    }

    /// A "Show all N / Show less" footer row, shown only when a list exceeds the
    /// preview cap. So nothing is ever silently truncated.
    @ViewBuilder
    private func showMoreFooter(total: Int, expanded: Binding<Bool>) -> some View {
        if total > previewCount {
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down").font(.caption2)
                    Text(expanded.wrappedValue ? "Show less" : "Show all \(total)").font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    // MARK: - Channels

    @ViewBuilder
    private var channelsSection: some View {
        SectionHeader("Channels")
        if loading {
            loadingRow
        } else if let ch = channels, !ch.isEmpty {
            // Matched links, when any.
            if !ch.edges.isEmpty {
                let shown = expandChannels ? ch.edges : Array(ch.edges.prefix(previewCount))
                CardContainer {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { idx, e in
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.right.circle.fill").foregroundStyle(.green)
                                if !e.proto.isEmpty { Badge(text: e.proto.uppercased(), color: protocolColor(e.proto)) }
                                Text(e.channel).font(.callout.weight(.medium)).lineLimit(1)
                                Spacer()
                                Text("\((e.producer.filePath as NSString).lastPathComponent) → \((e.consumer.filePath as NSString).lastPathComponent)")
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            if idx < shown.count - 1 { Divider() }
                        }
                        showMoreFooter(total: ch.edges.count, expanded: $expandChannels)
                    }
                }
            }
            // Unmatched producers/consumers — always listed (a produced-but-never-
            // consumed channel, or vice versa, is a real integration gap).
            endpointList("Producers with no consumer", ch.unmatchedProducers,
                         icon: "arrow.up.forward.circle", expanded: $expandProducers)
            endpointList("Consumers with no producer", ch.unmatchedConsumers,
                         icon: "arrow.down.forward.circle", expanded: $expandConsumers)
        } else {
            emptyRow("No channels detected in this namespace.")
        }
    }

    @ViewBuilder
    private func endpointList(_ title: String, _ items: [ChannelEndpoint], icon: String, expanded: Binding<Bool>) -> some View {
        if !items.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption).foregroundStyle(.orange)
                Text("\(title) · \(items.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            let shown = expanded.wrappedValue ? items : Array(items.prefix(previewCount))
            CardContainer {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { idx, ep in
                        HStack(spacing: 8) {
                            if !ep.proto.isEmpty { Badge(text: ep.proto.uppercased(), color: protocolColor(ep.proto)) }
                            Text(ep.channel.isEmpty ? ep.enclosingSymbol : ep.channel)
                                .font(.callout).lineLimit(1)
                            if let m = ep.method, !m.isEmpty, m != "ANY" {
                                Text(m).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text((ep.filePath as NSString).lastPathComponent)
                                .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        if idx < shown.count - 1 { Divider() }
                    }
                    showMoreFooter(total: items.count, expanded: expanded)
                }
            }
        }
    }

    // MARK: - Couplings

    private var fragile: [(repo: String, coupling: CommunityCoupling)] {
        couplingByRepo.flatMap { repo, report in
            report.communities.filter { !$0.couplers.isEmpty }.map { (repo: repo, coupling: $0) }
        }
        // Most impactful first: the more verified couplers a community needs to
        // hold together, the more entangled it is. Strength breaks ties.
        .sorted {
            if $0.coupling.couplers.count != $1.coupling.couplers.count {
                return $0.coupling.couplers.count > $1.coupling.couplers.count
            }
            return ($0.coupling.couplers.first?.couplingStrength ?? 0)
                > ($1.coupling.couplers.first?.couplingStrength ?? 0)
        }
    }

    /// The fragile community's user-facing name: its LLM display name when the
    /// clusters endpoint has one, else the stable id.
    private func communityLabel(repo: String, id: String) -> String {
        clusterNamesByRepo[repo]?[id] ?? id
    }

    /// Tooltip for the community pill(s): full identity, so the tight pill text
    /// never has to carry it. When the name splits into two pills, spell out
    /// that both are halves of ONE fragile community.
    private func communityPillHelp(_ item: (repo: String, coupling: CommunityCoupling)) -> String {
        let c = item.coupling
        let label = communityLabel(repo: item.repo, id: c.communityId)
        if label == c.communityId {
            return "Community \(c.communityId) · \(c.size) files — no LLM-generated name yet"
        }
        var s = "\(label) — community \(c.communityId) · \(c.size) files"
        if label.contains(" & ") {
            s += ". One fragile community — its name describes the two welded halves."
        }
        return s
    }

    /// Last two path components — enough to tell the many same-named files
    /// (`Base.php`…) apart without printing whole paths in a list row.
    private func shortPath(_ raw: String) -> String {
        raw.split(separator: "/").suffix(2).joined(separator: "/")
    }

    @ViewBuilder
    private var couplingsSection: some View {
        SectionHeader("Couplings")
        if loading {
            loadingRow
        } else if fragile.isEmpty {
            emptyRow("No fragile communities — modules are cohesive.")
        } else {
            Text("Elements welding a community's two latent halves together — remove one and the module splits. Click a row for the full picture.")
                .font(.caption).foregroundStyle(.secondary)
            let shown = expandCouplings ? fragile : Array(fragile.prefix(previewCount))
            CardContainer {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { idx, item in
                        couplingRow(item)
                        if idx < shown.count - 1 { Divider() }
                    }
                    showMoreFooter(total: fragile.count, expanded: $expandCouplings)
                }
            }
        }
    }

    private func couplingRow(_ item: (repo: String, coupling: CommunityCoupling)) -> some View {
        let c = item.coupling
        let key = item.repo + "|" + c.communityId
        let isOpen = expandedCoupling.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { expandedCoupling.remove(key) } else { expandedCoupling.insert(key) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.couplers.first.map { $0.elements.map(shortPath).joined(separator: " ↔ ") } ?? "coupler")
                            .font(.callout).lineLimit(1).truncationMode(.middle)
                        // The fragile community as a PILL, not prose — a name
                        // like "Migration And Api Setup" has no visible
                        // boundaries inside a sentence.
                        HStack(spacing: 6) {
                            // One pill per half of the community's name. A
                            // fragile community's LLM name usually describes
                            // its two welded halves ("Migration & Api Setup"),
                            // so each half reads as its own module — the
                            // tooltip clarifies they're one community.
                            let parts = communityLabel(repo: item.repo, id: c.communityId)
                                .components(separatedBy: " & ")
                            HStack(spacing: 4) {
                                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                                    if i > 0 { Text("+").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
                                    Badge(text: part, color: .indigo)
                                        // The pill's OWN tooltip: the
                                        // community's full identity, distinct
                                        // from the line's bridge-explanation
                                        // tooltip below.
                                        .help(communityPillHelp(item))
                                }
                            }
                            Text("Splits the community in two groups of \(c.subBlockA.count) and \(c.subBlockB.count) files")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            if c.couplers.count > 1 {
                                Text("· \(c.couplers.count) couplers")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .help("Remove \(c.couplers.first?.elements.first.map { ($0 as NSString).lastPathComponent } ?? "this coupler") and this community would fall apart into two groups of \(c.subBlockA.count) and \(c.subBlockB.count) files — expand the row to see them")
                    }
                    Spacer()
                    if repos.count > 1 { Badge(text: item.repo, color: .secondary) }
                    Text(String(format: "%.0f%%", (c.couplers.first?.couplingStrength ?? 0) * 100))
                        .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.orange)
                        .help("Coupling strength — how much likelier the community is to fall apart with this element removed")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
            if isOpen {
                couplingDetail(c)
                    .padding(.leading, 34).padding(.trailing, 12).padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func couplingDetail(_ c: CommunityCoupling) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Every verified coupler with its full path — the collapsed row only
            // fits the strongest one's file name.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(c.couplers.prefix(6)) { coupler in
                    HStack(spacing: 8) {
                        Image(systemName: coupler.isEdge ? "link" : "doc.text")
                            .font(.caption2).foregroundStyle(.orange)
                            .frame(width: 12, alignment: .center)
                        Text(coupler.elements.joined(separator: " ↔ "))
                            .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(coupler.elements.joined(separator: " ↔ "))
                        Spacer()
                        Text(String(format: "weld %.0f%% · split chance %.0f%%",
                                    coupler.couplingStrength * 100, coupler.splitProbability * 100))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if c.couplers.count > 6 {
                    Text("+\(c.couplers.count - 6) more").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            subBlock("Splits off group A", c.subBlockA)
            subBlock("Splits off group B", c.subBlockB)
        }
    }

    /// One latent sub-group: its size and a short member preview.
    @ViewBuilder
    private func subBlock(_ label: String, _ members: [String]) -> some View {
        let names = members.map { ($0 as NSString).lastPathComponent }
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label) · \(members.count)")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(names.prefix(6).joined(separator: ", ") + (names.count > 6 ? "  +\(names.count - 6) more" : ""))
                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                .lineLimit(2).truncationMode(.tail)
        }
    }

    // MARK: - Repos + languages

    @ViewBuilder
    private var reposSection: some View {
        SectionHeader("Repositories")
        if !languages.isEmpty {
            HStack(spacing: 6) {
                ForEach(languages.prefix(6), id: \.language) { l in
                    Badge(text: "\(l.language) \(l.fileCount)", color: .blue)
                }
            }
        }
        CardContainer {
            VStack(spacing: 0) {
                ForEach(repos) { repo in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(repo.name).font(.callout.weight(.medium))
                            Text(repo.path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(Format.count(repo.fileCount)) files").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    if repo.id != repos.last?.id { Divider() }
                }
            }
        }
    }

    // MARK: - Shared bits

    private var loadingRow: some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }

    /// A distinct color per transport, so protocols are scannable at a glance.
    private func protocolColor(_ proto: String) -> Color {
        switch proto.lowercased() {
        case "kafka": return .purple
        case "http", "https": return .blue
        case "mqtt": return .teal
        case "amqp": return .orange
        case "grpc": return .green
        default: return .secondary
        }
    }

    // MARK: - Load

    private func load() async {
        guard state.codesearchManager.isRunning else { loading = false; return }
        let client = state.codesearchManager.makeClient()

        // Features: per repo, merged and re-ranked by criticality.
        var merged: [CodeFeature] = []
        for repo in repos {
            if var r = try? await client.features(repository: repo.id) {
                for i in r.features.indices { r.features[i].repositoryName = repo.name }
                merged.append(contentsOf: r.features)
            }
        }
        features = merged.sorted { $0.criticality > $1.criticality }

        // Channels: one namespace-scoped call over all repo names.
        channels = try? await client.channels(repositories: repoNames)

        // Couplings: per repo (file level), for the risk summary — plus that
        // repo's cluster list, whose LLM display names let a coupling row name
        // the fragile module instead of showing a bare community hash.
        for repo in repos {
            if let report = try? await client.couplings(level: .file, repository: repo.id) {
                couplingByRepo[repo.name] = report
            }
            if let graph = try? await client.communities(level: .file, repository: repo.id) {
                clusterNamesByRepo[repo.name] = Dictionary(
                    uniqueKeysWithValues: graph.communities.map { ($0.id, $0.label) }
                )
            }
        }
        loading = false
    }
}

/// One node of a feature's call-flow tree, rendered recursively. Each node
/// with children gets a disclosure arrow; file:line sits inline next to the
/// symbol (a far-right column leaves an unreadable gap in a wide pane). When
/// the BFS hid some of a node's callees (they were first discovered under an
/// earlier node), a dimmed "N elsewhere" hint says so instead of the node
/// silently looking like a leaf.
private struct CallFlowNode: View {
    let featureId: String
    let node: FeatureNode
    let children: [String: [FeatureNode]]
    let level: Int
    @Binding var expanded: Set<String>

    var body: some View {
        let kids = children[node.symbol] ?? []
        let key = "\(featureId)|\(node.symbol)"
        // Root: membership means COLLAPSED, so it starts open. Deeper nodes:
        // membership means open, so they start closed.
        let isOpen = level == 0 ? !expanded.contains(key) : expanded.contains(key)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
                }
            } label: {
                HStack(spacing: 6) {
                    if kids.isEmpty {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 8)).foregroundStyle(.quaternary)
                            .frame(width: 12)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 12)
                    }
                    Text(shortSymbol(node.symbol))
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        .help(node.symbol)
                    Text(node.line > 0
                         ? "\((node.filePath as NSString).lastPathComponent):\(node.line)"
                         : (node.filePath as NSString).lastPathComponent)
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                        .help("Call site — where this symbol is invoked from")
                    // Flag flows that cross into a namespace sibling: file:line
                    // above is the call site (caller's repo), so without this
                    // badge a php-common symbol looks local.
                    if let repo = node.repositoryName {
                        Badge(text: repo, color: .teal)
                            .help("This symbol lives in \(repo), not in this feature's repository")
                    }
                    if !kids.isEmpty && !isOpen {
                        Text("→ \(kids.count)")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.blue)
                    }
                    if node.calleeCount > kids.count {
                        Text("\(node.calleeCount - kids.count) elsewhere")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.quaternary)
                            .help("\(shortSymbol(node.symbol)) calls \(node.calleeCount) symbols in total; \(node.calleeCount - kids.count) of them first appear under an earlier node — each symbol is shown once, beneath whichever caller reached it first")
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(kids.isEmpty)
            if isOpen && !kids.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(kids, id: \.symbol) { kid in
                        CallFlowNode(featureId: featureId, node: kid, children: children,
                                     level: level + 1, expanded: $expanded)
                    }
                }
                .padding(.leading, 14)
                // A hairline guide so deep branches stay traceable to their parent.
                .overlay(alignment: .leading) {
                    Rectangle().fill(.quaternary).frame(width: 1).padding(.leading, 5)
                }
            }
        }
    }

    /// "Vendor\Models\Home#method" → "Home#method".
    private func shortSymbol(_ fqn: String) -> String {
        fqn.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? fqn
    }
}

/// A streamed LLM explanation rendered as titled sections.
///
/// The stream carries raw `<purpose>…</purpose>`-style XML; `ExplanationParser`
/// splits it into sections and each renders as a bold title over its Markdown
/// body. Sections appear as their tags stream in. Text with no recognised tags
/// (errors, or a model that ignored the format) falls back to plain Markdown.
private struct ExplanationView: View {
    let text: String

    var body: some View {
        if let sections = ExplanationParser.parse(text) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        if !section.body.isEmpty {
                            MarkdownText(section.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        } else {
            MarkdownText(text).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Compact "working" indicator: a label with animated trailing dots, driven by
/// TimelineView (no timers, no state). Replaces an earlier full-width bar that
/// dominated the card.
private struct ThinkingIndicator: View {
    let label: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { ctx in
            let dots = Int(ctx.date.timeIntervalSinceReferenceDate / 0.45) % 3 + 1
            Text(label + String(repeating: ".", count: dots))
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}

/// A small filled dot whose color scales with criticality (green→orange→red).
private struct CriticalityDot: View {
    let value: Double
    var body: some View {
        Circle()
            .fill(value > 0.66 ? Color.red : (value > 0.33 ? .orange : .green))
            .frame(width: 8, height: 8)
    }
}
