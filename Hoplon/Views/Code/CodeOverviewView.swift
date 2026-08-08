import SwiftUI
import AppKit

/// Code Intelligence landing overview: index-wide stats plus the indexed
/// namespaces shown as a grid of clickable squares. This is what the section
/// shows before you drill into Memory or Import Sessions from the sidebar — an
/// at-a-glance map of what codesearch has indexed. Clicking a namespace square
/// opens its deep-dive (with a back button); the drilled namespace is held on
/// `NavigationModel` so the 5s status poll can't drop it. Data comes from the
/// management API's `/api/stats` and `/api/repositories`, already polled by
/// `CodesearchManager`.
struct CodeOverviewView: View {
    @Environment(AppState.self) var state
    @Environment(NavigationModel.self) var nav

    private var manager: CodesearchManager { state.codesearchManager }
    private var stats: CodesearchStats? { manager.stats }
    private var repositories: [Repository] { manager.repositories }

    /// Repositories grouped by namespace (a repo without one lands under "—"),
    /// each group sorted by name.
    private var namespaces: [(namespace: String, repos: [Repository])] {
        let grouped = Dictionary(grouping: repositories) { $0.namespace ?? "—" }
        return grouped
            .map { (namespace: $0.key, repos: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.namespace < $1.namespace }
    }

    private let statColumns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
    private let squareColumns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    /// The namespace whose Overview page is open, drilled from a landing square.
    /// Local (not `nav.selectedNamespace`) so it's independent of the sidebar —
    /// a landing square opens the Overview here, while a sidebar namespace row
    /// opens the community graph. The two entry points don't cross-select.
    @State private var openedNamespace: String?

    /// Naming a new namespace. The name is free text (it is a DuckDB schema
    /// name, not a path), but the *folder* that follows is picked — that is
    /// where a typo would silently index nothing.
    @State private var isNamingNamespace = false
    @State private var newNamespaceName = ""

    var body: some View {
        Group {
            if let ns = openedNamespace {
                NamespaceDeepDiveView(
                    namespace: ns,
                    repos: repositories.filter { ($0.namespace ?? "—") == ns },
                    onBack: { openedNamespace = nil }
                )
            } else {
                landing
            }
        }
        // Any sidebar navigation (into a namespace graph, a sub-tab, or back to
        // the section root) leaves this landing overview — drop the drilled
        // Overview so returning here shows the grid, not a stale page.
        .onChange(of: nav.sidebarSelection) { _, _ in openedNamespace = nil }
        .sheet(isPresented: $isNamingNamespace) { namespaceNameSheet }
    }

    /// Name the namespace, then pick the first repository folder for it. The
    /// namespace is created as part of indexing, so an empty one is never left
    /// behind if the user cancels at the folder step.
    private var namespaceNameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New namespace").font(.headline)
            Text("A namespace groups repositories that belong to one effort, so search and graphs can span them together.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $newNamespaceName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirmNewNamespace() }

            HStack {
                Spacer()
                Button("Cancel") { isNamingNamespace = false }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Folder…") { confirmNewNamespace() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedNamespace.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var trimmedNamespace: String {
        newNamespaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func confirmNewNamespace() {
        let name = trimmedNamespace
        guard !name.isEmpty else { return }
        isNamingNamespace = false
        addRepository(to: name)
    }

    /// Prompt for a repository folder and index it into `namespace`.
    private func addRepository(to namespace: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the repository folder to index into “\(namespace)”"
        panel.prompt = "Index"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        manager.index(folder: url, into: namespace)
    }

    private var landing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statsGrid
                namespacesSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { manager.refresh() }
    }

    // MARK: - Stats

    private var statsGrid: some View {
        LazyVGrid(columns: statColumns, spacing: 12) {
            MetricCard(title: "Namespaces", value: "\(namespaces.count)", systemImage: "square.stack.3d.up")
            MetricCard(title: "Repositories", value: countString(stats?.repositories ?? repositories.count), systemImage: "folder")
            MetricCard(title: "Files", value: countString(stats?.totalFiles), systemImage: "doc")
            MetricCard(title: "Chunks", value: countString(stats?.totalChunks), systemImage: "square.grid.3x3")
        }
    }

    private func countString(_ value: Int?) -> String {
        value.map { Format.count($0) } ?? "—"
    }

    // MARK: - Namespaces grid

    @ViewBuilder
    private var namespacesSection: some View {
        SectionHeader("Indexed namespaces") {
            Button { newNamespaceName = "" ; isNamingNamespace = true } label: {
                Label("New Namespace", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(manager.indexingPath != nil)
        }

        if let path = manager.indexingPath {
            CardContainer {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Indexing \((path as NSString).lastPathComponent)")
                            .font(.callout)
                        Text(manager.indexingStage ?? "working")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
            }
        }

        if let error = manager.indexError {
            Text(error).font(.caption).foregroundStyle(.red)
        }

        if repositories.isEmpty {
            EmptyStateView(
                icon: "tray",
                title: "Nothing indexed yet",
                message: "Create a namespace, then add the repository folders it should cover."
            )
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            LazyVGrid(columns: squareColumns, spacing: 16) {
                ForEach(namespaces, id: \.namespace) { group in
                    NamespaceSquare(
                        namespace: group.namespace,
                        repos: group.repos,
                        onOpen: { openedNamespace = group.namespace }
                    )
                    // The square is one big button, so an inline add control
                    // would compete with its hit target. A context menu keeps
                    // the card a single tap target and still lets an existing
                    // namespace grow.
                    .contextMenu {
                        Button("Add Repository…") { addRepository(to: group.namespace) }
                            .disabled(manager.indexingPath != nil)
                    }
                }
            }
        }
    }
}

// MARK: - Namespace square

/// One namespace rendered as a clickable square card: name + the three core
/// counts (repos / files / chunks). Signals interactivity on hover (lift +
/// accent border + pointing-hand cursor) so it reads as a button, and opens the
/// namespace deep-dive on click.
private struct NamespaceSquare: View {
    let namespace: String
    let repos: [Repository]
    let onOpen: () -> Void

    @State private var hovering = false

    private var fileCount: Int { repos.reduce(0) { $0 + $1.fileCount } }
    private var chunkCount: Int { repos.reduce(0) { $0 + $1.chunkCount } }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(.tint)
                    Text(namespace)
                        .font(.headline)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0.35)
                }
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    stat(Format.count(repos.count), "repo\(repos.count == 1 ? "" : "s")")
                    stat(Format.count(fileCount), "files")
                    stat(Format.count(chunkCount), "chunks")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(hovering ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: hovering ? 1.5 : 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: hovering ? 6 : 0, y: 2)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        // The pointing-hand cursor is the OS-standard "this is clickable" cue.
        .pointerStyle(.link)
        .help("Open \(namespace)")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Namespace deep-dive (placeholder)

/// The namespace deep-dive, reached by clicking a namespace square (or a sidebar
/// namespace row). A back chevron returns to the landing grid. Shows the
/// namespace overview: features, couplings, cross-service channels, and repos.
private struct NamespaceDeepDiveView: View {
    let namespace: String
    let repos: [Repository]
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to namespaces")
                Text(namespace)
                    .font(.headline)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()

            NamespaceInsightView(namespace: namespace, repos: repos)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
