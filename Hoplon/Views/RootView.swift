import SwiftUI
import AppKit

/// Pins the host `NSWindow`'s `contentMinSize` so the window can't be dragged
/// narrower than the app's real content minimum. SwiftUI's
/// `.windowResizability(.contentMinSize)` alone is insufficient here:
/// NavigationSplitView reports a smaller intrinsic minimum than our `.frame`,
/// so the window still shrinks and clips the sidebar / trailing toolbar buttons.
/// Setting it on the NSWindow directly is the reliable floor.
private struct WindowMinSizeEnforcer: NSViewRepresentable {
    let minSize: NSSize

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.contentMinSize = minSize }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.contentMinSize = minSize }
    }
}

/// Top-level window: a TWO-column split — an always-on nav sidebar picks the
/// section (or a nested proxy server / memory sub-tab), and the detail column
/// fills the rest. The sidebar is pinned open (never collapsible) and Proxy is
/// the landing section.
struct RootView: View {
    @Environment(AppState.self) var state
    @Environment(NavigationModel.self) var nav
    @State private var showSettings = false
    /// Pinned open — the sidebar is never collapsed.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $nav.sidebarSelection)
                // FIXED width (min == ideal == max): a flexible sidebar column
                // lets NavigationSplitView resize/collapse the rail during detail
                // transitions, which slides it partway off the window edge as a
                // detached panel. Pinning the width stops that.
                .navigationSplitViewColumnWidth(240)
                // Defeat the collapse toggle: if anything drives it toward
                // `.detailOnly`, snap it back so the rail stays visible.
                .onChange(of: columnVisibility) { _, newValue in
                    if newValue != .all { columnVisibility = .all }
                }
                // The sidebar is always on, so the automatic collapse button in
                // the toolbar does nothing — remove it.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detailColumn
                // Clip to the pane so a wide toolbar/header can't render past the
                // detail column's bounds.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(state)
        }
        // The floor is the fixed sidebar (240) plus the widest detail content:
        // the memory browser's two-pane split atop the service header's
        // Refresh/Stop buttons. Below this the toolbar overflows the pane.
        .frame(minWidth: 1120, minHeight: 600)
        // SwiftUI's `.windowResizability(.contentMinSize)` lets NavigationSplitView
        // report a smaller minimum than the frame above, so the window still drags
        // narrower and clips. Pin the NSWindow's contentMinSize directly.
        .background(WindowMinSizeEnforcer(minSize: NSSize(width: 1120, height: 600)))
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        switch nav.section {
        case .proxy:
            ProxyDetailView()
        case .guardrails:
            GuardrailsView()
        case .memory:
            MemoryDetailView()
        case .code:
            CodeDetailView()
        case nil:
            ContentUnavailableView("Select a Section", systemImage: "sidebar.left")
        }
    }
}

// MARK: - Sidebar

/// A sidebar row identity that stays unique across sections.
///
/// Every nested row in the sidebar's single `List` is keyed by a bare name — a
/// proxied server, a memory namespace, an indexed code namespace — and those
/// name-spaces overlap: a repository and a memory namespace can both be called
/// "netatmo". Two rows sharing an id makes SwiftUI treat them as one: both
/// highlight together and each shows the other's detail. Prefixing with the
/// owning section keeps them distinct.
private struct SidebarRow<Value>: Identifiable {
    let id: String
    let value: Value
}

/// The always-on navigation rail. Services are top-level rows; under Proxy each
/// MCP server the running proxy is serving appears as a nested row, and under
/// Memory each namespace plus the Browse/Import screens. Nested rows are only
/// present while the owning service is running — they mirror what's actually up.
struct SidebarView: View {
    @Environment(AppState.self) var state
    @Binding var selection: SidebarItem?

    private var proxiedServers: [String] { state.proxiedServerNames }
    private var memoryRunning: Bool { state.memoryManager.isRunning }
    private var namespaces: [MemoryNamespace] { state.memoryManager.namespaces }
    private var codeRunning: Bool { state.codesearchManager.isRunning }

    /// Indexed namespaces, sorted — mirrors the landing grid's grouping so the
    /// sidebar rows and the overview agree.
    private var codeNamespaces: [String] {
        let names = state.codesearchManager.repositories.map { $0.namespace ?? "—" }
        return Array(Set(names)).sorted()
    }

    var body: some View {
        List(selection: $selection) {
            Section("Services") {
                // Proxy, with its live servers nested beneath it.
                sectionRow(.proxy)
                ForEach(keyed(proxiedServers, "proxy")) { row in
                    proxyServerRow(row.value)
                }

                sectionRow(.guardrails)

                // Memory, with its namespaces and browsers nested while running.
                sectionRow(.memory)
                if memoryRunning {
                    ForEach(namespaces.map { SidebarRow(id: "memoryNs.\($0.name)", value: $0) }) { row in
                        namespaceRow(row.value)
                    }
                    ForEach(keyed(MemoryTab.browsable.map(\.rawValue), "memoryTab")) { row in
                        if let tab = MemoryTab(rawValue: row.value) { memoryTabRow(tab) }
                    }
                }

                // Code Intelligence, with its indexed namespaces nested beneath
                // it while it's running.
                sectionRow(.code)
                if codeRunning {
                    ForEach(keyed(codeNamespaces, "codeNs")) { row in
                        codeNamespaceRow(row.value)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Hoplon")
    }

    private func keyed(_ values: [String], _ section: String) -> [SidebarRow<String>] {
        values.map { SidebarRow(id: "\(section).\($0)", value: $0) }
    }

    @ViewBuilder
    private func sectionRow(_ section: AppSection) -> some View {
        HStack {
            Label(section.label, systemImage: section.systemImage)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let status = state.status(for: section), status != .stopped {
                StatusDot(status: status, size: 8)
            }
        }
        // Pin the row to fill from the leading edge so a width squeeze truncates
        // the label on the trailing edge instead of clipping it off the left.
        .frame(maxWidth: .infinity, alignment: .leading)
        .tag(SidebarItem.section(section))
    }

    /// One nested namespace row under Code Intelligence — opens that
    /// namespace's community graph (the same page the landing grid reaches).
    @ViewBuilder
    private func codeNamespaceRow(_ namespace: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(namespace)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
        }
        .padding(.leading, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tag(SidebarItem.codeNamespace(namespace))
        .help(namespace)
    }

    /// One nested proxied-server row under Proxy. Shows the live tool count once
    /// discovered; while none are discovered (discovery pending, OAuth not done,
    /// or the backend is unreachable) it shows a warning dot instead, so a
    /// configured-but-not-connected server is visible rather than absent.
    @ViewBuilder
    private func proxyServerRow(_ name: String) -> some View {
        let toolCount = state.discoveredTools[name]?.count ?? 0
        // `discoveredTools[name]` is present-but-empty once a probe completed
        // with zero tools; absent means "not discovered yet / failed".
        let discovered = state.discoveredTools[name] != nil
        let needsAuth = state.servers[name]?.isOAuth ?? false
        HStack(spacing: 8) {
            Image(systemName: "circle.grid.2x1.fill")
                .font(.system(size: 6))
                .foregroundStyle(.tertiary)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if toolCount > 0 {
                Text("\(toolCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if !discovered {
                // Not connected yet — amber for OAuth (actionable: sign in),
                // grey otherwise (pending / unreachable).
                Image(systemName: needsAuth ? "lock.fill" : "exclamationmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(needsAuth ? .orange : .secondary)
            }
        }
        .padding(.leading, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tag(SidebarItem.proxyServer(name))
        .help(rowHelp(name: name, toolCount: toolCount, discovered: discovered, needsAuth: needsAuth))
    }

    private func rowHelp(name: String, toolCount: Int, discovered: Bool, needsAuth: Bool) -> String {
        if toolCount > 0 {
            return "\(name) · \(toolCount) tool\(toolCount == 1 ? "" : "s")"
        }
        if needsAuth {
            return "\(name) · needs authentication (OAuth not completed)"
        }
        if !discovered {
            return "\(name) · not connected (discovery pending or backend unreachable)"
        }
        return "\(name) · no tools"
    }

    /// One nested namespace row under Memory — opens that namespace's projects.
    @ViewBuilder
    private func namespaceRow(_ ns: MemoryNamespace) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(ns.name)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if ns.projectCount > 0 {
                Text("\(ns.projectCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tag(SidebarItem.memoryNamespace(ns.name))
        .help("\(ns.name) · \(ns.projectCount) project\(ns.projectCount == 1 ? "" : "s")")
    }

    /// One nested Memory sub-tab (Browse / Import).
    @ViewBuilder
    private func memoryTabRow(_ tab: MemoryTab) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tab.icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(tab.title)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.leading, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tag(SidebarItem.memoryTab(tab))
    }
}
