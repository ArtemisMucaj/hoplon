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

    /// Repositories grouped by namespace, each group sorted by name.
    ///
    /// `id` is the real namespace and `namespace` the label to show — they
    /// differ for unscoped repositories, which group under a "—" placeholder
    /// that is not a namespace anyone can index into.
    ///
    /// Built from the server's namespace list *unioned* with the groups implied
    /// by the repositories. The list alone would miss unscoped repos (they
    /// belong to no namespace); the repositories alone would miss namespaces
    /// with nothing indexed into them yet — which is every namespace right
    /// after it's created, and the whole reason an empty one has to be visible.
    private var namespaces: [(id: String?, namespace: String, repos: [Repository])] {
        let grouped = Dictionary(grouping: repositories) { $0.namespace }
        var groups = grouped.map { (id: $0.key,
                                    namespace: $0.key ?? "—",
                                    repos: $0.value.sorted { $0.name < $1.name }) }

        let known = Set(grouped.keys.compactMap { $0 })
        for ns in manager.namespaces where !known.contains(ns.name) {
            groups.append((id: ns.name, namespace: ns.name, repos: []))
        }

        return groups.sorted { $0.namespace < $1.namespace }
    }

    private let statColumns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
    private let squareColumns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    /// The namespace whose Overview page is open, drilled from a landing square.
    /// Local (not `nav.selectedNamespace`) so it's independent of the sidebar —
    /// a landing square opens the Overview here, while a sidebar namespace row
    /// opens the community graph. The two entry points don't cross-select.
    @State private var openedNamespace: String?

    /// Naming a new namespace. The name is free text (it is a DuckDB schema
    /// name, not a path); the namespace is created empty and filled from its
    /// detail view afterwards.
    @State private var isNamingNamespace = false
    @State private var newNamespaceName = ""
    @State private var isCreatingNamespace = false

    /// The namespace page to show: one drilled from a landing square, or the
    /// namespace the sidebar selected when it has nothing indexed (an empty
    /// namespace has no graph, so `CodeDetailView` routes it here instead).
    private var shownNamespace: String? {
        openedNamespace ?? nav.selectedCodeNamespace
    }

    var body: some View {
        Group {
            if let ns = shownNamespace {
                NamespaceDeepDiveView(
                    namespace: ns,
                    repos: repositories.filter { ($0.namespace ?? "—") == ns },
                    onBack: {
                        openedNamespace = nil
                        // Reached from the sidebar, "back" also has to clear the
                        // selection, or `shownNamespace` re-derives it instantly.
                        nav.selectedCodeNamespace = nil
                    },
                    // "—" is the placeholder for unscoped repositories, not a
                    // real namespace, so it can be neither indexed into nor
                    // deleted.
                    onIndexProject: isRealNamespace(ns) ? { addRepository(to: ns) } : nil,
                    onDelete: isRealNamespace(ns) ? { deleteNamespace(ns) } : nil
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

    /// Name the namespace and create it, empty.
    ///
    /// The folder picker used to follow immediately, so a namespace only ever
    /// came into being as a side effect of indexing. Creating it empty makes it
    /// a container the user fills from its detail view — the same shape as a
    /// Memory namespace, which is created bare and gains projects afterwards.
    private var namespaceNameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New namespace").font(.headline)
            Text("A namespace groups repositories that belong to one effort, so search and graphs can span them together. It starts empty — index projects into it from its page.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $newNamespaceName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirmNewNamespace() }

            // The sheet stays open when creation fails (a duplicate name is the
            // common case), so the reason has to be visible here — the landing
            // page's copy of it is behind this sheet.
            if let error = manager.namespaceError {
                ErrorCard(message: error)
            }

            HStack {
                Spacer()
                Button("Cancel") { isNamingNamespace = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreatingNamespace)
                Button {
                    confirmNewNamespace()
                } label: {
                    if isCreatingNamespace {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedNamespace.isEmpty || isCreatingNamespace)
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
        guard !name.isEmpty, !isCreatingNamespace else { return }
        isCreatingNamespace = true
        Task {
            defer { isCreatingNamespace = false }
            if await manager.createNamespace(name) {
                isNamingNamespace = false
                newNamespaceName = ""
                // Land on the new namespace so the next step — indexing a
                // project into it — is right there.
                openedNamespace = name
            }
        }
    }

    /// Whether `label` is a namespace that exists server-side, as opposed to the
    /// "—" bucket the grid uses for repositories that belong to no namespace.
    private func isRealNamespace(_ label: String) -> Bool { label != "—" }

    /// Delete `namespace` and everything indexed into it, after confirming.
    ///
    /// The server cascades, so this discards every repository in the namespace
    /// along with its chunks, embeddings and cached analyses — potentially a lot
    /// of indexing work. That is worth an explicit confirmation naming what goes.
    private func deleteNamespace(_ namespace: String) {
        let repoCount = repositories.filter { ($0.namespace ?? "—") == namespace }.count

        let alert = NSAlert()
        alert.messageText = "Delete the namespace “\(namespace)”?"
        alert.informativeText = repoCount == 0
            ? "This namespace is empty. It will be removed."
            : "Its \(repoCount) indexed repositor\(repoCount == 1 ? "y" : "ies") will be deleted with it, "
              + "including everything indexed from them. You'll have to index them again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        // Make Delete the destructive-looking default and Escape mean Cancel.
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            if await manager.deleteNamespace(namespace) {
                // The page we're on no longer exists — go back to the grid.
                openedNamespace = nil
                if nav.selectedCodeNamespace == namespace { nav.selectedCodeNamespace = nil }
            }
        }
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
            Button {
                newNamespaceName = ""
                // Don't greet a fresh attempt with the previous one's failure.
                manager.namespaceError = nil
                isNamingNamespace = true
            } label: {
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
            ErrorCard(message: error, title: "Indexing failed")
        }

        if let error = manager.namespaceError {
            ErrorCard(message: error)
        }

        // Keyed on the namespaces, not the repositories: a namespace created but
        // not yet indexed into has no repositories, and testing those would hide
        // every card behind the empty state — the exact case this screen exists
        // to make visible.
        if namespaces.isEmpty {
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
                    //
                    // Only for a real namespace: `group.namespace` is a display
                    // label, and unscoped repositories are grouped under "—".
                    // Indexing into that would create a namespace literally
                    // named "—".
                    .contextMenu {
                        if let real = group.id {
                            Button("Add Repository…") { addRepository(to: real) }
                                .disabled(manager.indexingPath != nil)
                        }
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
///
/// This is also where a namespace is filled and removed: "Index Project" adds a
/// repository to it (the only way to fill a namespace now that creating one no
/// longer forces a folder choice), and the trash deletes it. Both are `nil` for
/// the "—" bucket of unscoped repositories, which isn't a real namespace.
private struct NamespaceDeepDiveView: View {
    @Environment(AppState.self) private var state

    let namespace: String
    let repos: [Repository]
    let onBack: () -> Void
    var onIndexProject: (() -> Void)?
    var onDelete: (() -> Void)?

    private var manager: CodesearchManager { state.codesearchManager }
    private var isDeleting: Bool { manager.deletingNamespace == namespace }

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

                if let onIndexProject {
                    Button(action: onIndexProject) {
                        Label("Index Project", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(manager.indexingPath != nil || isDeleting)
                    .help("Index a repository folder into “\(namespace)”")
                }

                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        if isDeleting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "trash")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(manager.indexingPath != nil || isDeleting)
                    .help("Delete “\(namespace)” and everything indexed into it")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()

            if let path = manager.indexingPath {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Indexing \((path as NSString).lastPathComponent) — \(manager.indexingStage ?? "working")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                Divider()
            }

            if let error = manager.indexError ?? manager.namespaceError {
                ErrorCard(
                    message: error,
                    title: manager.indexError != nil ? "Indexing failed" : nil
                )
                .padding(.horizontal, 20).padding(.vertical, 8)
                Divider()
            }

            // A namespace with nothing in it has no graph, features or
            // couplings to show — point at the one action that changes that
            // instead of rendering a page of empty sections.
            if repos.isEmpty {
                EmptyStateView(
                    icon: "tray",
                    title: "Nothing indexed yet",
                    message: "Index a project folder into “\(namespace)” to build its search index and graphs."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NamespaceInsightView(namespace: namespace, repos: repos)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
