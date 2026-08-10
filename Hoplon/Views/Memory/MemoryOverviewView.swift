import SwiftUI

/// The Memory section's landing page: what's in the store, how it's grouped,
/// and how agents reach it. Namespaces are the one structural thing a human
/// edits here — they decide which projects recall spans — so they get the most
/// space and are creatable/deletable inline.
struct MemoryOverviewView: View {
    @Environment(AppState.self) var state
    @Environment(NavigationModel.self) var nav

    private var manager: MemoryManager { state.memoryManager }

    /// Naming a new namespace, in a sheet — the same flow as Code Intelligence,
    /// so both sections are created the same way rather than one inline and one
    /// through a dialog.
    @State private var isNamingNamespace = false
    @State private var newNamespace = ""
    @State private var isCreating = false
    @State private var actionError: String?

    private let squareColumns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statsSection
                namespacesSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Memory")
        .sheet(isPresented: $isNamingNamespace) { namespaceNameSheet }
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

    /// Namespaces as a grid of clickable squares — the same shape as Code
    /// Intelligence's landing, so the two sections read as one app. Opening a
    /// square goes to that namespace's page, where its projects are managed and
    /// it can be deleted; the grid itself carries no per-card actions.
    @ViewBuilder
    private var namespacesSection: some View {
        SectionHeader("Namespaces") {
            Button {
                newNamespace = ""
                actionError = nil
                isNamingNamespace = true
            } label: {
                Label("New Namespace", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }

        if let actionError {
            Text(actionError).font(.caption).foregroundStyle(.red)
        }

        if manager.namespaces.isEmpty {
            EmptyStateView(
                icon: "tray",
                title: "No namespaces yet",
                message: "Create a namespace, then add the projects whose memories it should span."
            )
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            LazyVGrid(columns: squareColumns, spacing: 16) {
                ForEach(manager.namespaces) { ns in
                    MemoryNamespaceSquare(
                        namespace: ns,
                        onOpen: { nav.sidebarSelection = .memoryNamespace(ns.name) }
                    )
                }
            }
        }
    }

    /// Name the namespace and create it. Mirrors Code Intelligence's sheet, down
    /// to the button title, so neither section teaches a flow the other breaks.
    private var namespaceNameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New namespace").font(.headline)
            Text("A namespace groups projects so recall can span a multi-repo effort instead of stopping at one repository. It starts empty — add projects to it from its page.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $newNamespace)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }

            // The sheet stays open on failure, so the reason has to show here.
            if let actionError {
                Text(actionError)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { isNamingNamespace = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button {
                    create()
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedNew.isEmpty || isCreating)
            }
        }
        .padding(20)
        .frame(width: 420)
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
                isNamingNamespace = false
                newNamespace = ""
                manager.refresh()
                // Land on the new namespace so adding its first project is
                // the next thing in front of you.
                nav.sidebarSelection = .memoryNamespace(name)
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Namespace square

/// One memory namespace as a clickable square card. Deliberately the same card
/// as Code Intelligence's `NamespaceSquare` — hover lift, accent border,
/// pointing-hand cursor — differing only in the stat it shows (projects, not
/// repos/files/chunks) and its accent colour, which matches the Memory section.
private struct MemoryNamespaceSquare: View {
    let namespace: MemoryNamespace
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(.orange)
                    Text(namespace.name)
                        .font(.headline)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0.35)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.count(namespace.projectCount))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Text("project\(namespace.projectCount == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
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
        .pointerStyle(.link)
        .help("Open \(namespace.name)")
    }
}
