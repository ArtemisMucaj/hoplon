import SwiftUI

struct ServerDetailView: View {
    let name: String
    let server: MCPServer
    let onBack: (() -> Void)?
    @Environment(AppState.self) var state
    @State private var newEnvKey = ""
    @State private var newEnvValue = ""
    @State private var newHeaderKey = ""
    @State private var newHeaderValue = ""
    @State private var stagedServer: MCPServer
    @State private var hasChanges = false
    // Keys that existed in the config file when the view was opened — shown
    // read-only with an obfuscated value so the user can see what's set
    // without being able to accidentally change it here. @State latches the
    // value at first init so re-renders after applyChanges() don't promote
    // newly added headers into the read-only set.
    @State private var configFileHeaderKeys: Set<String>

    // Stable-identity wrapper for args to avoid index-based ForEach issues
    struct ArgItem: Identifiable {
        let id: UUID
        var value: String
    }
    @State private var argItems: [ArgItem] = []

    init(name: String, server: MCPServer, onBack: (() -> Void)? = nil) {
        self.name = name
        self.server = server
        self.onBack = onBack
        _stagedServer = State(initialValue: server)
        _argItems = State(initialValue: (server.args ?? []).map { ArgItem(id: UUID(), value: $0) })
        _configFileHeaderKeys = State(initialValue: Set(server.headers?.keys.map { $0 } ?? []))
    }

    private func binding<T: Equatable>(for keyPath: WritableKeyPath<MCPServer, T>) -> Binding<T> {
        Binding(
            get: { stagedServer[keyPath: keyPath] },
            set: { newValue in
                stagedServer[keyPath: keyPath] = newValue
                hasChanges = true
            }
        )
    }

    private func optionalStringBinding(for keyPath: WritableKeyPath<MCPServer, String?>) -> Binding<String> {
        Binding(
            get: { stagedServer[keyPath: keyPath] ?? "" },
            set: { newValue in
                stagedServer[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
                hasChanges = true
            }
        )
    }

    // Header names whose values are secrets and should be masked on screen.
    private func isSensitiveHeader(_ key: String) -> Bool {
        ["authorization", "cookie", "x-api-key"].contains(key.lowercased())
    }

    // Trim and validate an HTTP header name (RFC 7230 token). Returns the
    // normalized name, or nil if it's empty or contains illegal characters.
    private func normalizedHeaderName(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let isToken = key.range(
            of: #"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$"#,
            options: .regularExpression
        ) != nil
        return isToken ? key : nil
    }

    private func syncArgsToServer() {
        if argItems.isEmpty {
            stagedServer.args = nil
        } else {
            stagedServer.args = argItems.map { $0.value }
        }
    }

    private func applyChanges() {
        state.servers[name] = stagedServer
        hasChanges = false
        // PUT the full config via the REST API, which hot-swaps the running
        // proxy (rebuilds the inner) without restarting the server process.
        state.putFullConfig()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectionCard
                Divider()
                descriptionCard
                Divider()
                if server.isHTTP { headersCard; Divider() }
                environmentCard
                Divider()
                toolsCard
                Divider()
                statusCard
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(name)
        .navigationSubtitle(server.isOAuth ? "OAuth" : (server.isHTTP ? "HTTP" : "stdio"))
        .onChange(of: server) { _, newServer in
            if !hasChanges {
                stagedServer = newServer
                argItems = (newServer.args ?? []).map { ArgItem(id: UUID(), value: $0) }
            }
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private var connectionCard: some View {
            // Connection
            ServerCard("Connection") {
                if server.isHTTP {
                    TextField("URL", text: optionalStringBinding(for: \.url))
                        .textFieldStyle(.roundedBorder)
                    // Inline label + value (not LabeledContent, which pushes the
                    // value to the far right and reads as disconnected in the
                    // flat layout).
                    HStack(spacing: 6) {
                        Text("Transport").foregroundStyle(.secondary)
                        Text(server.transport ?? "http").fontWeight(.medium)
                    }
                    .font(.callout)
                } else {
                    TextField("Command", text: optionalStringBinding(for: \.command))
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Args")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                argItems.append(ArgItem(id: UUID(), value: ""))
                                syncArgsToServer()
                                hasChanges = true
                            } label: {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.borderless)
                        }

                        if !argItems.isEmpty {
                            ForEach(argItems) { item in
                                HStack {
                                    TextField("Arg", text: Binding(
                                        get: { item.value },
                                        set: { newValue in
                                            if let index = argItems.firstIndex(where: { $0.id == item.id }) {
                                                argItems[index].value = newValue
                                                syncArgsToServer()
                                                hasChanges = true
                                            }
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)

                                    Button {
                                        argItems.removeAll { $0.id == item.id }
                                        syncArgsToServer()
                                        hasChanges = true
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        } else {
                            Text("No arguments")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                    }

                    LabeledContent("Transport", value: "stdio")
                }
            }
    }

    @ViewBuilder
    private var descriptionCard: some View {
            // Description
            ServerCard("Description") {
                TextField(
                    "",
                    text: optionalStringBinding(for: \.description),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .accessibilityLabel("Description")
            } footer: {
                Text("Shown to agents via load_tools so they know which provider to search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    // Headers (HTTP/SSE only) — e.g. Authorization tokens for remote servers.
    @ViewBuilder
    private var headersCard: some View {
                ServerCard("Headers") {
                    if let headers = stagedServer.headers, !headers.isEmpty {
                        ForEach(headers.keys.sorted(), id: \.self) { key in
                            if configFileHeaderKeys.contains(key) {
                                // From config file — show key as label, value obfuscated
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(key)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("••••••••")
                                        .foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                                }
                            } else {
                                HStack {
                                    let valueBinding = Binding(
                                        get: { stagedServer.headers?[key] ?? "" },
                                        set: { newValue in
                                            stagedServer.headers?[key] = newValue
                                            hasChanges = true
                                        }
                                    )
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(key)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if isSensitiveHeader(key) {
                                            SecureField("Value", text: valueBinding)
                                                .textFieldStyle(.roundedBorder)
                                        } else {
                                            TextField("Value", text: valueBinding)
                                                .textFieldStyle(.roundedBorder)
                                        }
                                    }
                                    Button {
                                        stagedServer.headers?.removeValue(forKey: key)
                                        if stagedServer.headers?.isEmpty == true {
                                            stagedServer.headers = nil
                                        }
                                        hasChanges = true
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.borderless)
                                    .padding(.top, 16)
                                }
                            }
                        }
                    }
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Key")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("Header-Name", text: $newHeaderKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 100)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Value")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if isSensitiveHeader(newHeaderKey.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                SecureField("", text: $newHeaderValue)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                TextField("", text: $newHeaderValue)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        Button {
                            guard let key = normalizedHeaderName(newHeaderKey) else { return }
                            if stagedServer.headers == nil {
                                stagedServer.headers = [:]
                            }
                            stagedServer.headers?[key] = newHeaderValue
                            hasChanges = true
                            newHeaderKey = ""
                            newHeaderValue = ""
                        } label: {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.borderless)
                        .disabled(normalizedHeaderName(newHeaderKey) == nil)
                        .padding(.bottom, 4)
                    }
                } footer: {
                    Text("Sent on every request, e.g. Authorization: Bearer <token>.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
    }

    @ViewBuilder
    private var environmentCard: some View {
            // Environment
            ServerCard("Environment") {
                if let env = stagedServer.env, !env.isEmpty {
                    ForEach(env.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(key)
                                .frame(minWidth: 100, alignment: .leading)
                            TextField("Value", text: Binding(
                                get: { stagedServer.env?[key] ?? "" },
                                set: { newValue in
                                    stagedServer.env?[key] = newValue
                                    hasChanges = true
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            Button {
                                stagedServer.env?.removeValue(forKey: key)
                                if stagedServer.env?.isEmpty == true {
                                    stagedServer.env = nil
                                }
                                hasChanges = true
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    TextField("Key", text: $newEnvKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 100)
                    TextField("Value", text: $newEnvValue)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        guard !newEnvKey.isEmpty else { return }
                        if stagedServer.env == nil {
                            stagedServer.env = [:]
                        }
                        stagedServer.env?[newEnvKey] = newEnvValue
                        hasChanges = true
                        newEnvKey = ""
                        newEnvValue = ""
                    } label: {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                    .disabled(newEnvKey.isEmpty)
                }
            }
    }

    @ViewBuilder
    private var toolsCard: some View {
            // Tools
            ServerCard("Tools") {
                if let tools = state.discoveredTools[name], !tools.isEmpty {
                    ForEach(tools) { tool in
                        ToolRowView(
                            serverName: name,
                            tool: tool,
                            isDisabled: state.isToolDisabled(server: name, tool: tool.name)
                        )
                        if tool.id != tools.last?.id { Divider() }
                    }
                } else if state.isDiscoveringTools {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Discovering tools...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No tools discovered yet")
                        .foregroundStyle(.secondary)
                }
            } header: {
                if let tools = state.discoveredTools[name] {
                    let enabled = tools.filter { !state.isToolDisabled(server: name, tool: $0.name) }.count
                    Text("\(enabled)/\(tools.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    state.discoverTools()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(state.isDiscoveringTools || !(server.enabled ?? true))
            }
    }

    @ViewBuilder
    private var statusCard: some View {
            // Status
            ServerCard("Status") {
                LabeledContent("Enabled") {
                    Toggle("", isOn: Binding(
                        get: { stagedServer.enabled ?? true },
                        set: { newValue in
                            stagedServer.enabled = newValue
                            hasChanges = true
                        }
                    ))
                    .labelsHidden()
                }

                if hasChanges {
                    HStack {
                        Spacer()
                        Button("Discard Changes") {
                            // Reset to the current authoritative server state
                            let currentServer = state.servers[name] ?? server
                            stagedServer = currentServer
                            argItems = (currentServer.args ?? []).map { ArgItem(id: UUID(), value: $0) }
                            hasChanges = false
                        }
                        .foregroundStyle(.secondary)

                        Button("Apply") {
                            applyChanges()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
    }
}

/// A titled card section for the server editor. Fills the available width and
/// renders as a rounded container — used instead of a grouped `Form` (which
/// collapsed into a broken flat layout when hosted outside a scroll container).
struct ServerCard<Content: View, Header: View, Footer: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var header: Header
    @ViewBuilder var footer: Footer

    init(_ title: String,
         @ViewBuilder content: () -> Content,
         @ViewBuilder header: () -> Header = { EmptyView() },
         @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.title = title
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        // Flat layout: title, fields, help text, and +/- buttons all share the
        // card's single left edge (no inset background box that would push the
        // fields in from the title). A leading divider gives each section a
        // subtle visual boundary without indenting the content.
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                header
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolRowView: View {
    let serverName: String
    let tool: DiscoveredTool
    let isDisabled: Bool
    @Environment(AppState.self) var state

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .fontWeight(.medium)
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                if !tool.description.isEmpty {
                    Text(tool.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { !isDisabled },
                set: { _ in
                    state.toggleTool(server: serverName, tool: tool.name)
                }
            ))
            .labelsHidden()
        }
    }
}