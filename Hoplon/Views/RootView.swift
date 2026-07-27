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
            CodeIntelligencePlaceholderView()
        case nil:
            ContentUnavailableView("Select a Section", systemImage: "sidebar.left")
        }
    }
}

// MARK: - Sidebar

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

    var body: some View {
        List(selection: $selection) {
            Section("Services") {
                // Proxy, with its live servers nested beneath it.
                sectionRow(.proxy)
                ForEach(proxiedServers, id: \.self) { name in
                    proxyServerRow(name)
                }

                sectionRow(.guardrails)

                // Memory, with its namespaces and browsers nested while running.
                sectionRow(.memory)
                if memoryRunning {
                    ForEach(namespaces) { ns in
                        namespaceRow(ns)
                    }
                    ForEach(MemoryTab.browsable) { tab in
                        memoryTabRow(tab)
                    }
                }

                sectionRow(.code)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Hoplon")
    }

    @ViewBuilder
    private func sectionRow(_ section: AppSection) -> some View {
        HStack {
            Label(section.label, systemImage: section.systemImage)
                .lineLimit(1)
            Spacer(minLength: 8)
            if section.isImplemented {
                if let status = state.status(for: section), status != .stopped {
                    StatusDot(status: status, size: 8)
                }
            } else {
                // No manager behind this row yet — say so rather than showing a
                // status dot that would imply it's merely stopped.
                Text("soon")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        // Pin the row to fill from the leading edge so a width squeeze truncates
        // the label on the trailing edge instead of clipping it off the left.
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(section.isImplemented ? .primary : .secondary)
        .tag(SidebarItem.section(section))
    }

    /// One nested proxied-server row under Proxy, with its live tool count.
    @ViewBuilder
    private func proxyServerRow(_ name: String) -> some View {
        let toolCount = state.discoveredTools[name]?.count ?? 0
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
            }
        }
        .padding(.leading, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tag(SidebarItem.proxyServer(name))
        .help("\(name) · \(toolCount) tool\(toolCount == 1 ? "" : "s")")
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

// MARK: - Code Intelligence placeholder

/// codesearch is being reworked upstream, so this section is intentionally
/// inert: it explains what will live here rather than shipping UI wired to an
/// API that is about to change.
struct CodeIntelligencePlaceholderView: View {
    var body: some View {
        EmptyStateView(
            icon: AppSection.code.systemImage,
            title: "Code Intelligence isn't wired up yet",
            message: "codesearch is being reworked. Once its API settles, this section will supervise "
                + "the codesearch binary and surface semantic search, call-graph analysis and community "
                + "detection — the memory features it used to carry now live in the Memory section."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
