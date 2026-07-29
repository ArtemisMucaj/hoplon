import SwiftUI

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

    @State private var newProject = ""
    @State private var actionError: String?

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
                        Text(actionError).font(.caption).foregroundStyle(.red)
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

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                nav.sidebarSelection = .section(.memory)
            } label: {
                Label("Memory", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

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
            SectionHeader("Projects") {
                HStack(spacing: 6) {
                    TextField("Add project", text: $newProject)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit { assign() }
                    Button { assign() } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(.borderless)
                        .disabled(trimmedProject.isEmpty)
                }
            }

            Text("A project is how memory-rs names a codebase — normally its git owner/repo. Memories carrying one of these projects, plus all global memories, are in scope for this namespace.")
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

    private var trimmedProject: String {
        newProject.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func assign() {
        let project = trimmedProject
        guard !project.isEmpty else { return }
        actionError = nil
        Task {
            do {
                _ = try await manager.makeClient().assignProject(project, to: namespace)
                newProject = ""
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
