import SwiftUI
import AppKit

/// One namespace: the projects it spans, and a scoped search over their
/// memories plus the globals.
///
/// This is where the namespace earns its keep — the search here is the only
/// place in the app that answers "what do we know across this whole effort?",
/// as opposed to the Browse screen's store-wide view.
struct NamespaceDetailView: View {
    let namespace: String

    @Environment(AppState.self) var state
    @Environment(NavigationModel.self) var nav

    private var manager: MemoryManager { state.memoryManager }

    @State private var detail: MemoryNamespaceDetail?
    @State private var isLoading = false
    @State private var loadError: String?

    @State private var actionError: String?
    @State private var isDeleting = false

    @State private var query = ""
    @State private var results: [Memory] = []
    @State private var searchNote: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    projectsSection
                    resultsSection
                    if let actionError {
                        ErrorCard(message: actionError)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: namespace) { await load() }
        .navigationTitle(namespace)
    }

    // MARK: - Header

    /// Title row, laid out like Code Intelligence's namespace page: back chevron,
    /// name, then the primary action and the trash on the trailing edge. The
    /// search field sits below it rather than beside the chevron, so the two
    /// sections' namespace pages have the same header.
    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    nav.sidebarSelection = .section(.memory)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to namespaces")

                Text(namespace)
                    .font(.headline)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()

                Button { pickProject() } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isDeleting)
                .help("Pick a repository folder; its project name comes from the git remote")

                Button(role: .destructive) {
                    deleteNamespace()
                } label: {
                    if isDeleting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .buttonStyle(.borderless)
                // Disabled until the detail loads: the confirmation names the
                // project count, and offering the action before that is known
                // means either a wrong count or a silent guess.
                .disabled(isDeleting || detail == nil)
                .help(detail == nil
                      ? "Loading “\(namespace)”…"
                      : "Delete “\(namespace)” (its projects and memories are kept)")
            }

            SearchBar(text: $query, prompt: "Search across \(namespace)…", isBusy: isSearching) {
                search()
            }
        }
        .padding(12)
        .onChange(of: query) { _, _ in scheduleSearch() }
    }

    // MARK: - Projects

    @ViewBuilder
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // "Add Project" lives in the page header now (beside the trash), the
            // same place Code Intelligence puts "Index Project".
            SectionHeader("Projects")

            Text("Pick a repository folder and its project name is read from the git remote, the same way memory-rs names a session's codebase. Memories carrying one of these projects, plus all global memories, are in scope for this namespace.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoading {
                CardContainer {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(12)
                }
            } else if let loadError {
                CardContainer {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(loadError).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                }
            } else if (detail?.projects ?? []).isEmpty {
                CardContainer {
                    Text("No projects yet — this namespace matches nothing until you add one.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                CardContainer {
                    VStack(spacing: 0) {
                        let projects = detail?.projects ?? []
                        ForEach(Array(projects.enumerated()), id: \.offset) { idx, project in
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.orange).frame(width: 18)
                                Text(project).font(.callout)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button(role: .destructive) {
                                    unassign(project)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove “\(project)” from \(namespace)")
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            if idx < projects.count - 1 { Divider() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Scoped search results

    @ViewBuilder
    private var resultsSection: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Results")
                if let searchNote {
                    Text(searchNote).font(.caption).foregroundStyle(.orange)
                }
                if results.isEmpty && !isSearching {
                    CardContainer {
                        Text("Nothing matched in this namespace.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                } else {
                    CardContainer {
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, item in
                                resultRow(item)
                                if idx < results.count - 1 { Divider() }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ memory: Memory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let kind = memory.kind { Badge(text: kind, color: .indigo) }
                Text(memory.title).font(.callout.weight(.medium))
                    .help(memory.statement ?? "")
                Spacer()
                if let score = memory.score {
                    Text(String(format: "%.2f", score))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.green)
                }
            }
            HStack(spacing: 8) {
                if let project = memory.project {
                    Text(project).font(.caption2).foregroundStyle(.tertiary)
                }
                // Recall carries a compact provenance; surfacing it here is what
                // stops a contested answer looking like a settled one.
                if let p = memory.provenance {
                    if p.supersedesCount > 0 {
                        Text("replaced \(p.supersedesCount)\(p.chainTruncated ? "+" : "")")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if p.corroborations > 0 {
                        Text("corroborated \(p.corroborations)×")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if p.isContested {
                        Label("contested", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Actions

    /// Prompt for a repository folder and assign the project name derived from
    /// it. Deriving beats typing here: the name has to match what memory-rs
    /// stamps on sessions from that directory, and a typed one that doesn't
    /// looks identical to a project that simply has no memories yet.
    private func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the repository folder for this project"
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let project = GitProject.name(for: url) else {
            actionError = "Couldn't derive a project name from \(url.path)."
            return
        }
        assign(project)
    }

    /// Delete this namespace, after confirming.
    ///
    /// Unlike Code Intelligence's delete, this one is *not* destructive to the
    /// contents: memory-rs namespaces only group projects, so removing one drops
    /// the grouping and leaves every project and memory intact. The confirmation
    /// says so — the same trash icon meaning "you lose the index" in one section
    /// and "you lose a grouping" in the other would be a trap otherwise.
    private func deleteNamespace() {
        // Name what is being given up, the way Code Intelligence names its
        // repository count — "only the grouping is removed" is reassuring, but
        // it doesn't say how much grouping.
        //
        // The button is disabled until `detail` loads (see `header`), so this is
        // never the "not loaded yet" case: defaulting to 0 there would have
        // promised "its 0 projects are kept" for a namespace spanning ten.
        guard let projectCount = detail?.projects.count else { return }
        let scope = projectCount == 1
            ? "Its 1 project and that project's memories are kept"
            : "Its \(projectCount) projects and their memories are kept"

        let alert = NSAlert()
        alert.messageText = "Delete the namespace “\(namespace)”?"
        alert.informativeText = "\(scope) — only the grouping is removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isDeleting = true
        actionError = nil
        Task {
            defer { isDeleting = false }
            do {
                // A `{"deleted": false}` is a refusal, not an error — navigating
                // away on it would claim a deletion that never happened.
                guard try await manager.makeClient().deleteNamespace(namespace) else {
                    actionError = "The server didn't delete “\(namespace)”. It may already be gone — try refreshing."
                    return
                }
                manager.refresh()
                // This page's namespace is gone — go back to the Memory landing.
                nav.sidebarSelection = .section(.memory)
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            detail = try await manager.makeClient().namespace(namespace)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func assign(_ project: String) {
        actionError = nil
        Task {
            do {
                _ = try await manager.makeClient().assignProject(project, to: namespace)
                await load()
                manager.refresh()   // project counts live on the namespace list
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func unassign(_ project: String) {
        actionError = nil
        Task {
            do {
                _ = try await manager.makeClient().unassignProject(project, from: namespace)
                await load()
                manager.refresh()
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Debounce live typing so a keystroke doesn't fire a request each time.
    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []; searchNote = nil; isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            await runSearch(trimmed)
        }
    }

    private func search() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask = Task { await runSearch(trimmed) }
    }

    private func runSearch(_ text: String) async {
        isSearching = true
        defer { if !Task.isCancelled { isSearching = false } }
        do {
            let response = try await manager.makeClient().search(query: text, namespace: namespace)
            if Task.isCancelled { return }
            results = response.results
            searchNote = response.note
        } catch {
            if Task.isCancelled { return }
            results = []
            searchNote = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
