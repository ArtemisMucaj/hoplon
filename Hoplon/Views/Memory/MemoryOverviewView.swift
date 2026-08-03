import SwiftUI

/// The Memory section's landing page: what's in the store, how it's grouped,
/// and how agents reach it. Namespaces are the one structural thing a human
/// edits here — they decide which projects recall spans — so they get the most
/// space and are creatable/deletable inline.
struct MemoryOverviewView: View {
    @Environment(AppState.self) var state
    @Environment(NavigationModel.self) var nav

    private var manager: MemoryManager { state.memoryManager }

    @State private var newNamespace = ""
    @State private var isCreating = false
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statsSection
                namespacesSection
                if let actionError {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Memory")
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Store")
            HStack(spacing: 12) {
                MetricCard(title: "Memories", value: metric(manager.stats?.totalMemories),
                           color: .indigo, systemImage: "brain")
                MetricCard(title: "Entities", value: metric(manager.stats?.totalEntities),
                           color: .teal, systemImage: "at")
                MetricCard(title: "Links", value: metric(manager.stats?.totalEdges),
                           color: .purple, systemImage: "link")
                MetricCard(title: "Sessions", value: metric(manager.stats?.totalSessions),
                           color: .cyan, systemImage: "bubble.left.and.text.bubble.right")
            }
            HStack(spacing: 12) {
                MetricCard(title: "Conflicts", value: Format.count(manager.conflictCount),
                           color: manager.conflictCount > 0 ? .orange : .secondary,
                           systemImage: "exclamationmark.triangle")
                MetricCard(title: "History", value: metric(manager.stats?.historyCount),
                           color: .secondary, systemImage: "clock.arrow.circlepath")
                MetricCard(title: "Nodes", value: metric(manager.stats?.totalNodes),
                           color: .orange, systemImage: "point.3.filled.connected.trianglepath.dotted")
                MetricCard(title: "Namespaces", value: Format.count(manager.namespaces.count),
                           color: .green, systemImage: "square.stack.3d.up")
            }

            // Per-kind breakdown, when the store has anything in it.
            if let byKind = manager.stats?.memoriesByKind, !byKind.isEmpty {
                CardContainer {
                    VStack(spacing: 0) {
                        ForEach(Array(byKind.enumerated()), id: \.offset) { idx, entry in
                            HStack(spacing: 10) {
                                Image(systemName: MemoryKind(rawValue: entry.0)?.icon ?? "circle")
                                    .foregroundStyle(.indigo)
                                    .frame(width: 18)
                                Text(MemoryKind(rawValue: entry.0)?.label ?? entry.0.capitalized)
                                    .font(.callout)
                                Spacer()
                                Text(Format.count(entry.1))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            if idx < byKind.count - 1 { Divider() }
                        }
                    }
                }
            }

            if let dir = manager.stats?.dataDir {
                Text(dir)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    private func metric(_ value: Int?) -> String {
        value.map { Format.count($0) } ?? "—"
    }

    // MARK: - Namespaces

    @ViewBuilder
    private var namespacesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Namespaces") {
                HStack(spacing: 6) {
                    TextField("New namespace", text: $newNamespace)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit { create() }
                    Button {
                        create()
                    } label: {
                        if isCreating {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Add", systemImage: "plus")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(trimmedNew.isEmpty || isCreating)
                }
            }

            Text("A namespace groups projects so recall can span a multi-repo effort instead of stopping at one repository.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if manager.namespaces.isEmpty {
                CardContainer {
                    Text("No namespaces yet — memories are scoped per project until you group some.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                CardContainer {
                    VStack(spacing: 0) {
                        ForEach(Array(manager.namespaces.enumerated()), id: \.element.id) { idx, ns in
                            namespaceRow(ns)
                            if idx < manager.namespaces.count - 1 { Divider() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func namespaceRow(_ ns: MemoryNamespace) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(ns.name).font(.callout.weight(.medium))
                Text("\(ns.projectCount) project\(ns.projectCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { nav.sidebarSelection = .memoryNamespace(ns.name) }
                .buttonStyle(.borderless)
            Button(role: .destructive) {
                delete(ns)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete “\(ns.name)” (its projects and memories are kept)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { nav.sidebarSelection = .memoryNamespace(ns.name) }
    }

    // MARK: - Actions

    private var trimmedNew: String {
        newNamespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        let name = trimmedNew
        guard !name.isEmpty, !isCreating else { return }
        isCreating = true
        actionError = nil
        Task {
            defer { isCreating = false }
            do {
                _ = try await manager.makeClient().createNamespace(name)
                newNamespace = ""
                manager.refresh()
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func delete(_ ns: MemoryNamespace) {
        actionError = nil
        Task {
            do {
                _ = try await manager.makeClient().deleteNamespace(ns.name)
                if nav.selectedMemoryNamespace == ns.name { nav.selectedMemoryNamespace = nil }
                manager.refresh()
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
