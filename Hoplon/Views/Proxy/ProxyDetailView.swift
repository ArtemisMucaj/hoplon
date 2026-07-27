import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// One tool the proxy itself exposes to clients (not a proxied backend tool —
/// those are behind `call_tool`). Panoply presents a fixed 3-tool workflow so an
/// agent orients before searching.
private struct ProxyOwnTool: Identifiable {
    let name: String
    let step: String
    let description: String
    var id: String { name }
}

/// The Proxy landing: an overview of the proxy's **own** surface — the three
/// synthetic tools it exposes (the `load_tools → search_tools → call_tool`
/// workflow) and the skills it mounts as resources — plus the config presets.
/// The backend server list is not shown here; servers live in the sidebar, and
/// selecting one there opens its editor.
struct ProxyOverviewView: View {
    @Environment(AppState.self) var state

    /// The proxy's fixed synthetic tools, with the descriptions the server
    /// advertises. These are what a connected MCP client actually sees.
    private let ownTools: [ProxyOwnTool] = [
        ProxyOwnTool(
            name: "load_tools", step: "Step 1",
            description: "Returns a cheap overview of which backend servers are proxied and what each is for — so an agent can orient before searching. Executes nothing."),
        ProxyOwnTool(
            name: "search_tools", step: "Step 2",
            description: "Find a specific backend tool by keyword. Returns matching tool names + schemas to call next."),
        ProxyOwnTool(
            name: "call_tool", step: "Step 3",
            description: "Execute a backend tool by name with its arguments. This is the only way proxied tools are invoked."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                toolsSection
                resourcesSection
                presetsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if state.proxyManager.isRunning { state.fetchPresets() } }
        .navigationTitle("Proxy")
        .overlay {
            if state.servers.isEmpty {
                EmptyStateView(
                    icon: "hexagon",
                    title: "No servers configured",
                    message: "Add servers to ~/.panoply/servers.json",
                    actionTitle: "Open Config File",
                    action: { ProxyDetailView.openConfigFile(state: state) }
                )
            }
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Proxy tools")
            CardContainer {
                VStack(spacing: 0) {
                    ForEach(Array(ownTools.enumerated()), id: \.element.id) { idx, tool in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(tool.name).font(.callout.weight(.semibold)).monospaced()
                                Badge(text: tool.step, color: .accentColor)
                            }
                            Text(tool.description)
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        if idx < ownTools.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Resources")
            CardContainer {
                HStack(spacing: 10) {
                    Image(systemName: "books.vertical.fill").foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Skills").font(.callout.weight(.medium))
                        Text("Agent skills mounted from ~/.claude/skills and ~/.agents/skills, exposed to clients as MCP resources when connecting with ?skills=true.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Config Presets") {
                Button { ProxyDetailView.pickPresetFile(state: state) } label: {
                    Label("Add Preset", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!state.proxyManager.isRunning)
                .help(state.proxyManager.isRunning ? "Add a new preset" : "Start the proxy to manage presets")
            }
            CardContainer {
                VStack(spacing: 0) {
                    DefaultPresetRowView().padding(.horizontal, 12).padding(.vertical, 6)
                    ForEach(state.presets) { preset in
                        Divider()
                        PresetRowView(preset: preset).padding(.horizontal, 12).padding(.vertical, 6)
                    }
                }
            }
        }
    }
}

// MARK: - Proxy detail

/// Detail column for the MCP Proxy section: the selected server's editor, or
/// the proxy overview when nothing is selected. Owns the proxy toolbar
/// (edit-config, start/stop).
struct ProxyDetailView: View {
    @Environment(AppState.self) var state
    @Environment(NavigationModel.self) var nav
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        @Bindable var nav = nav
        VStack(spacing: 0) {
            // Shared running header — identical to Guardrails & Memory.
            ServiceHeader(
                systemImage: AppSection.proxy.systemImage,
                status: state.proxyStatus,
                subtitle: state.proxyManager.isRunning
                    ? state.proxyManager.endpoint
                    : "Aggregates MCP servers behind 3 tools"
            ) {
                serverControl
            }
            Divider()

            // State-driven master/detail in ONE pane (no NavigationStack): the
            // selected server's editor, else the overview. A sidebar
            // nested-server tap and a list-row tap both just set
            // `nav.selectedServer`, so both open the editor.
            if let name = nav.selectedServer, let server = state.servers[name] {
                ServerDetailView(name: name, server: server, onBack: { nav.selectedServer = nil })
                    .id(name)
            } else {
                ProxyOverviewView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Self.openConfigFile(state: state) } label: {
                    Label("Edit Config", systemImage: "doc.text")
                }
                .help("Open servers.json in a text editor")
            }
        }
        .alert("Error Starting Proxy", isPresented: $showError) {
            Button("OK", role: .cancel) { showError = false }
        } message: {
            Text(errorMessage)
        }
    }

    @ViewBuilder
    private var serverControl: some View {
        if state.proxyManager.isStarting {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7).controlSize(.small)
                Text("Starting…").font(.callout)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.orange.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if state.proxyManager.isRunning {
            Button { state.stopProxy() } label: {
                Label("Stop Proxy", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.glassProminent).tint(.red)
            .help("Stop the MCP proxy")
        } else {
            Button {
                state.startProxy()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let error = state.proxyManager.lastError {
                        errorMessage = error
                        showError = true
                    }
                }
            } label: {
                Label("Start Proxy", systemImage: "play.circle.fill")
            }
            .buttonStyle(.glassProminent).tint(.green)
            .help("Start the MCP proxy")
        }
    }

    @MainActor
    static func openConfigFile(state: AppState) {
        let configURL = state.configURL
        if !FileManager.default.fileExists(atPath: configURL.path) {
            state.saveConfig()
        }
        NSWorkspace.shared.open(configURL)
    }

    /// Prompt for a servers.json file and register it as a config preset.
    @MainActor
    static func pickPresetFile(state: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.showsHiddenFiles = true
        panel.message = "Select a servers.json config file"
        panel.prompt = "Add Preset"
        if panel.runModal() == .OK, let url = panel.url {
            state.addPreset(name: url.deletingPathExtension().lastPathComponent, filePath: url.path)
        }
    }
}

// MARK: - Server row

/// One backend MCP server, as shown in the server list.
struct ServerRowView: View {
    let name: String
    let server: MCPServer
    @Environment(AppState.self) var state

    var isEnabled: Bool { server.enabled ?? true }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .fontWeight(.medium)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                Text(server.displayType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if server.isOAuth {
                Image(systemName: "key.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            Toggle("", isOn: Binding(
                get: { server.enabled ?? true },
                set: { newValue in
                    state.servers[name]?.enabled = newValue
                    state.postServerToggle(server: name, enabled: newValue)
                }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}
