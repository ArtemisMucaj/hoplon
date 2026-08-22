import SwiftUI
import AppKit

/// Replaces the standard rounded-border text field with one that does not
/// accept first responder status automatically when the window appears.
/// The user can still click into it to edit — clicking sets firstResponder
/// explicitly, bypassing this flag for the key-view loop only.
private struct PortField: NSViewRepresentable {
    @Binding var value: Int

    func makeNSView(context: Context) -> NSTextField {
        let tf = NoAutoFocusTextField()
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.alignment = .right
        tf.formatter = {
            let f = NumberFormatter()
            f.numberStyle = .none
            f.usesGroupingSeparator = false
            f.allowsFloats = false
            f.minimum = 1
            f.maximum = 65535
            return f
        }()
        tf.delegate = context.coordinator
        tf.integerValue = value
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.integerValue != value { nsView.integerValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PortField
        init(_ parent: PortField) { self.parent = parent }
        func controlTextDidEndEditing(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                parent.value = tf.integerValue
            }
        }
    }

    /// Refuses to become first responder via the window's key-view loop
    /// (which is how SwiftUI auto-focuses the first field on appear), but
    /// still accepts focus on an explicit user click.
    private final class NoAutoFocusTextField: NSTextField {
        override var acceptsFirstResponder: Bool {
            guard let event = NSApp.currentEvent else { return false }
            return event.type == .leftMouseDown || event.type == .rightMouseDown
        }
    }
}

// MARK: - Close button

/// A native-style close control: a small red circle that reveals its ✗ glyph
/// only on hover, like a macOS window's traffic-light close button.
private struct CloseTrafficLight: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(red: 0.99, green: 0.35, blue: 0.33))
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.black.opacity(0.55))
                    .opacity(hovering ? 1 : 0)
            }
            .frame(width: 13, height: 13)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close settings")
    }
}

// MARK: - Settings window

/// A row in the Settings sidebar: a top-level service, or a Memory sub-pane
/// nested beneath it (Process / Dream) — mirroring the main window's nested
/// sidebar.
enum SettingsItem: Hashable {
    case service(AppSection)
    case guardrailsPane(GuardrailsPane)
    case memoryPane(MemoryPane)
    case codePane(CodePane)
    case commandLine
}

/// The Guardrails settings sub-panes.
enum GuardrailsPane: String, CaseIterable, Identifiable, Hashable {
    case process, providers
    /// Namespaced — see the note on `CodePane.id`.
    var id: String { "guardrails.\(rawValue)" }
    var title: String {
        switch self {
        case .process:   return "Process"
        case .providers: return "Providers"
        }
    }
    var icon: String {
        switch self {
        case .process:   return "gearshape.2"
        case .providers: return "server.rack"
        }
    }
}

/// The Code Intelligence settings sub-panes.
enum CodePane: String, CaseIterable, Identifiable, Hashable {
    case process, llm
    /// Namespaced: `MemoryPane` has cases of the same raw value, and both
    /// enums' rows live in ONE `List`. A bare `rawValue` makes "code.llm" and
    /// "memory.llm" collide, and SwiftUI then treats them as one row — both
    /// highlight together and each shows the other's pane.
    var id: String { "code.\(rawValue)" }
    var title: String {
        switch self {
        case .process: return "Process"
        case .llm:     return "LLM"
        }
    }
    var icon: String {
        switch self {
        case .process: return "gearshape.2"
        case .llm:     return "sparkles"
        }
    }
}

/// The Memory settings sub-panes.
enum MemoryPane: String, CaseIterable, Identifiable, Hashable {
    case process, llm, dream
    /// Namespaced — see the note on `CodePane.id`.
    var id: String { "memory.\(rawValue)" }
    var title: String {
        switch self {
        case .process: return "Process"
        case .llm:     return "LLM"
        case .dream:   return "Dream"
        }
    }
    var icon: String {
        switch self {
        case .process: return "gearshape.2"
        case .llm:     return "sparkles"
        case .dream:   return "moon.stars"
        }
    }
}

/// The Settings window: a sidebar picks a service (or a Memory sub-pane), its
/// pane fills the detail. Changes apply **immediately** — every field binds
/// straight to `AppState`, whose setters persist and restart the affected
/// service — so there is no Done/Apply step. A top bar carries only a red Close
/// button.
struct SettingsView: View {
    @Environment(AppState.self) var state
    @Environment(\.dismiss) var dismiss

    @State private var selection: SettingsItem? = .service(.proxy)

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            NavigationSplitView {
                List(selection: $selection) {
                    Section("Services") {
                        serviceRow(.proxy)
                        serviceRow(.guardrails)
                        // Guardrails sub-panes, nested like the main UI.
                        ForEach(GuardrailsPane.allCases) { pane in
                            guardrailsPaneRow(pane)
                        }
                        serviceRow(.memory)
                        // Memory sub-panes, nested like the main UI.
                        ForEach(MemoryPane.allCases) { pane in
                            memoryPaneRow(pane)
                        }
                        serviceRow(.code)
                        // Code Intelligence sub-panes, nested like the main UI.
                        ForEach(CodePane.allCases) { pane in
                            codePaneRow(pane)
                        }
                    }
                    Section("Tools") {
                        HStack {
                            Label("CLI & Skills", systemImage: "terminal")
                            Spacer()
                        }
                        .tag(SettingsItem.commandLine)
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
                .toolbar(removing: .sidebarToggle)
            } detail: {
                detailPane
            }
        }
        // Wide enough for the LLM panes: a 220pt sidebar, a job label, and a
        // fixed-width model picker beside it. At 720 the picker pushed the
        // section's own controls off the right edge.
        .frame(minWidth: 820, idealWidth: 880, minHeight: 480, idealHeight: 620)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            CloseTrafficLight { dismiss() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            if let warning = crossServicePortConflict {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Sidebar rows

    @ViewBuilder
    private func serviceRow(_ section: AppSection) -> some View {
        HStack {
            Label(section.label, systemImage: section.systemImage)
            Spacer()
            if let status = state.status(for: section), status != .stopped {
                StatusDot(status: status, size: 8)
            }
        }
        .tag(SettingsItem.service(section))
    }

    @ViewBuilder
    private func guardrailsPaneRow(_ pane: GuardrailsPane) -> some View {
        HStack(spacing: 8) {
            Image(systemName: pane.icon).font(.caption2).foregroundStyle(.secondary).frame(width: 14)
            Text(pane.title).lineLimit(1)
            Spacer()
        }
        .padding(.leading, 18)
        .tag(SettingsItem.guardrailsPane(pane))
    }

    @ViewBuilder
    private func memoryPaneRow(_ pane: MemoryPane) -> some View {
        HStack(spacing: 8) {
            Image(systemName: pane.icon).font(.caption2).foregroundStyle(.secondary).frame(width: 14)
            Text(pane.title).lineLimit(1)
            Spacer()
        }
        .padding(.leading, 18)
        .tag(SettingsItem.memoryPane(pane))
    }

    @ViewBuilder
    private func codePaneRow(_ pane: CodePane) -> some View {
        HStack(spacing: 8) {
            Image(systemName: pane.icon).font(.caption2).foregroundStyle(.secondary).frame(width: 14)
            Text(pane.title).lineLimit(1)
            Spacer()
        }
        .padding(.leading, 18)
        .tag(SettingsItem.codePane(pane))
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .service(.proxy):      ProxySettingsPane()
        case .service(.guardrails): GuardrailsSettingsPane()     // section row → Process
        case .guardrailsPane(.process):   GuardrailsSettingsPane()
        case .guardrailsPane(.providers): GuardrailsProvidersPane()
        case .service(.memory):     MemoryProcessPane()      // section row → Process
        case .service(.code):       CodeProcessPane()         // section row → Process
        case .memoryPane(.process): MemoryProcessPane()
        case .memoryPane(.llm):     MemoryLlmPane()
        case .memoryPane(.dream):   MemoryDreamPane()
        case .codePane(.process):   CodeProcessPane()
        case .codePane(.llm):       CodeLlmPane()
        case .commandLine:          CommandLinePane()
        case nil:                   ContentUnavailableView("Select a Setting", systemImage: "gearshape")
        }
    }

    // MARK: Live cross-service port validation (advisory)

    /// A human-readable warning when two enabled services would bind the same
    /// port. Advisory only — settings apply live, so the user sees and fixes it
    /// immediately rather than being blocked behind a Done button.
    private var crossServicePortConflict: String? {
        var used: [Int: String] = [:]
        func claim(_ port: Int, _ owner: String) -> String? {
            if let other = used[port], other != owner {
                return "Port \(port) is used by both \(owner) and \(other)."
            }
            used[port] = owner
            return nil
        }
        if let e = claim(state.port, "MCP Proxy") { return e }
        if let e = claim(state.port + 1, "MCP Proxy API") { return e }
        if state.guardrailsEnabled {
            if let e = claim(state.guardrailsPort, "Guardrails") { return e }
            if let e = claim(state.guardrailsAdminPort, "Guardrails admin") { return e }
        }
        if state.memoryEnabled {
            if let e = claim(state.memoryPort, "Memory") { return e }
        }
        if state.codesearchEnabled {
            if let e = claim(state.codesearchMcpPort, "Code Intelligence MCP") { return e }
            if let e = claim(state.codesearchMgmtPort, "Code Intelligence API") { return e }
        }
        return nil
    }
}

// MARK: - Proxy pane

private struct ProxySettingsPane: View {
    @Environment(AppState.self) var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("MCP Proxy Server") {
                LabeledContent("Port") {
                    PortField(value: $state.port).frame(width: 80, height: 22)
                }
                Text("Panoply serves MCP on this port; its REST management API binds port + 1 automatically. Changing the port restarts the proxy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Toggle("CodeMode", isOn: $state.codeMode)
                if state.codeMode {
                    Text("The LLM writes sandboxed Python scripts to batch tool calls instead of calling tools one at a time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Proxy")
    }
}

// MARK: - Guardrails pane

private struct GuardrailsSettingsPane: View {
    @Environment(AppState.self) var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Guardrails Proxy") {
                Toggle("Enabled", isOn: $state.guardrailsEnabled)
                Text("Transparent proxy that repairs malformed tool calls from local OpenAI-compatible model servers (e.g. LM Studio).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if state.guardrailsEnabled {
                Section("Endpoints") {
                    LabeledContent("Listen Port") {
                        PortField(value: $state.guardrailsPort).frame(width: 80, height: 22)
                    }
                    LabeledContent("Admin Port") {
                        PortField(value: $state.guardrailsAdminPort).frame(width: 80, height: 22)
                    }
                    Text("Point your client at http://127.0.0.1:\(String(state.guardrailsPort))/v1. Metrics are served on the admin port.")
                        .font(.caption).foregroundStyle(.secondary)
                    // Shown only until the proxy has written its config. After
                    // that the file wins over the flags, so the field would be
                    // a text box that looks like configuration and changes
                    // nothing — the proxy keeps being passed a value it
                    // ignores. Providers move to Guardrails ▸ Providers, which
                    // edits the file the proxy actually reads.
                    if !state.guardrailsHasConfig {
                        LabeledContent("First backend") {
                            TextField("", text: $state.guardrailsBackend, prompt: Text("http://127.0.0.1:1234"))
                                .textFieldStyle(.roundedBorder)
                        }
                        Text("Seeds the configuration the first time the proxy runs. After that, providers are managed under Guardrails ▸ Providers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // Nothing here once the proxy owns its configuration: the
                    // Providers pane is one row away in the sidebar, so a line
                    // pointing at it is a signpost to somewhere already in view.
                    if state.guardrailsPort == state.guardrailsAdminPort {
                        Label("Listen and Admin ports must be different.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Guardrails")
    }
}

// MARK: - Memory: Process pane

private struct MemoryProcessPane: View {
    @Environment(AppState.self) var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Memory Service") {
                Toggle("Enabled", isOn: $state.memoryEnabled)
                Text("Runs `memory-rs serve`: long-term memory over imported assistant sessions, with hybrid recall.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if state.memoryEnabled {
                Section("Endpoint") {
                    LabeledContent("Port") {
                        PortField(value: $state.memoryPort).frame(width: 80, height: 22)
                    }
                    Toggle("Bind publicly (0.0.0.0)", isOn: $state.memoryPublic)
                    // One port, two surfaces — worth stating, since every other
                    // service here takes two ports.
                    Text("Serves both surfaces on one port: the REST API the app drives, and the MCP endpoint at http://127.0.0.1:\(String(state.memoryPort))/mcp.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Agent access") {
                    Toggle("Serve through the MCP proxy", isOn: $state.registerMemoryWithProxy)
                    Text("Keeps a `memory` entry in the proxy's servers.json pointing at this service, so agents reach memory tools through the single proxy endpoint.")
                        .font(.caption).foregroundStyle(.secondary)
                    if ProxyRegistration.memory.hasUserDefinedEntry(in: state.servers) {
                        Label("servers.json already defines a `memory` server of your own — Hoplon is leaving it alone.",
                              systemImage: "info.circle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Storage") {
                    // memory-rs owns its data directory; surface it read-only so
                    // "where did my memories go" has an answer in the UI.
                    LabeledContent("Data directory") {
                        Text(state.memoryManager.stats?.dataDir ?? "~/.memory-rs")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Process")
    }
}

// MARK: - Memory: LLM pane

/// memory-rs's own LLM endpoints. Needs the server running: the config lives in
/// its config.json and is read/written through its management API.
private struct MemoryLlmPane: View {
    @Environment(AppState.self) var state
    private var manager: MemoryManager { state.memoryManager }

    var body: some View {
        Group {
            if manager.isRunning {
                MemoryLlmView().environment(state)
            } else {
                EmptyStateView(
                    icon: "sparkles",
                    title: "Memory is stopped",
                    message: "Start Memory to configure its LLM endpoints and discover models.",
                    actionTitle: state.memoryEnabled ? nil : "Enable",
                    action: state.memoryEnabled ? nil : { state.memoryEnabled = true }
                )
            }
        }
        .navigationTitle("LLM")
    }
}

// MARK: - Memory: Dream pane

/// The dream scheduler's settings. Needs the server running: the config lives
/// in memory-rs's config.json and is read/written through its management API,
/// so there is nothing to show (or save) while the service is stopped.
private struct MemoryDreamPane: View {
    @Environment(AppState.self) var state
    private var manager: MemoryManager { state.memoryManager }

    var body: some View {
        Group {
            if manager.isRunning {
                DreamSettingsView().environment(state)
            } else {
                EmptyStateView(
                    icon: "moon.stars",
                    title: "Memory is stopped",
                    message: "Start Memory to configure dreaming and auto-import.",
                    actionTitle: state.memoryEnabled ? nil : "Enable",
                    action: state.memoryEnabled ? nil : { state.memoryEnabled = true }
                )
            }
        }
        .navigationTitle("Dream")
    }
}

// MARK: - Code Intelligence: Process pane

private struct CodeProcessPane: View {
    @Environment(AppState.self) var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Service") {
                Toggle("Enabled", isOn: $state.codesearchEnabled)
                Text("Runs `codesearch serve`: an MCP server plus a REST management API for semantic search, call graphs, and community detection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if state.codesearchEnabled {
                Section("Endpoints") {
                    LabeledContent("MCP Port") {
                        PortField(value: $state.codesearchMcpPort).frame(width: 80, height: 22)
                    }
                    LabeledContent("Management Port") {
                        PortField(value: $state.codesearchMgmtPort).frame(width: 80, height: 22)
                    }
                    Toggle("Bind publicly (0.0.0.0)", isOn: $state.codesearchPublic)
                    Text("Point MCP clients at http://127.0.0.1:\(String(state.codesearchMcpPort))/mcp. The app drives the management API on port \(String(state.codesearchMgmtPort)).")
                        .font(.caption).foregroundStyle(.secondary)
                    if state.codesearchMcpPort == state.codesearchMgmtPort {
                        Label("MCP and Management ports must be different.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Agent access") {
                    Toggle("Serve through the MCP proxy", isOn: $state.registerCodesearchWithProxy)
                    Text("Keeps a `codesearch` entry in the proxy's servers.json pointing at this service, so agents reach code search and call-graph tools through the single proxy endpoint.")
                        .font(.caption).foregroundStyle(.secondary)
                    if ProxyRegistration.codesearch.hasUserDefinedEntry(in: state.servers) {
                        Label("servers.json already defines a `codesearch` server of your own — Hoplon is leaving it alone.",
                              systemImage: "info.circle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Process")
    }
}

// MARK: - Code Intelligence: LLM pane

/// codesearch's LLM backends — endpoint management and model discovery. Needs
/// the server running: the endpoints live in its config and are read/written
/// through the management API, so there is nothing to show while it's stopped.
private struct CodeLlmPane: View {
    @Environment(AppState.self) var state
    private var manager: CodesearchManager { state.codesearchManager }

    var body: some View {
        Group {
            if manager.isRunning {
                LlmView().environment(state)
            } else {
                EmptyStateView(
                    icon: "sparkles",
                    title: "Code Intelligence is stopped",
                    message: "Start Code Intelligence to configure its LLM endpoints and discover models.",
                    actionTitle: state.codesearchEnabled ? nil : "Enable",
                    action: state.codesearchEnabled ? nil : { state.codesearchEnabled = true }
                )
            }
        }
        .navigationTitle("LLM")
    }
}

// MARK: - Tools: CLI & Skills pane

/// Two halves of the same job — making the bundled services usable *outside* this
/// app. The top half symlinks the CLIs into `~/.local/bin`; the bottom half
/// installs the agent skills that document them into `~/.agents/skills`.
///
/// The links point into the app bundle, so they track the current binary but go
/// stale if the app is moved — each row surfaces that and its toggle repairs it.
private struct CommandLinePane: View {
    @Environment(AppState.self) var state
    private var manager: CliLinkManager { state.cliLinkManager }

    var body: some View {
        Form {
            Section("Command-Line Tools") {
                Text("Symlinked into \(manager.binDirectoryPath).")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(CliLinkManager.tools) { tool in
                    toolRow(tool)
                }
            }

            AgentSkillsSection()

            if !manager.binDirOnPath {
                Section("PATH") {
                    Label("\(manager.binDirectoryPath) isn't on your PATH, so the commands won't be found until you add it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    HStack {
                        Text(manager.pathExportLine)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            copyToPasteboard(manager.pathExportLine)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                    Text("Add this line to your shell profile (e.g. ~/.zshrc), then open a new terminal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let error = manager.lastError {
                Section {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("CLI & Skills")
        .onAppear {
            manager.refresh()
            state.skillManager.refresh()
        }
    }

    @ViewBuilder
    private func toolRow(_ tool: CliLinkManager.Tool) -> some View {
        let installed = manager.states[tool.commandName] == .linked
        LabeledContent {
            Toggle("", isOn: Binding(
                get: { installed },
                set: { on in
                    if on { manager.install(tool) } else { manager.remove(tool) }
                }
            ))
            .labelsHidden()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.commandName).font(.body)
                switch manager.states[tool.commandName] {
                case .linked:
                    Text("Installed").font(.caption).foregroundStyle(.green)
                case .stale(let reason):
                    Text(reason).font(.caption).foregroundStyle(.orange)
                case .notLinked, .none:
                    Text("Not installed").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        // Stale links (wrong target / leftover from a moved app) get an explicit
        // repair affordance — flipping the toggle would also work, but naming it
        // "Repair" tells the user what happened.
        if case .stale = manager.states[tool.commandName] {
            HStack {
                Spacer()
                Button("Repair Link") { manager.install(tool) }
                    .controlSize(.small)
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Tools: Agent Skills section

/// Installs the memory-rs / codesearch skills bundled with this build into
/// `~/.agents/skills`, one variant per service.
///
/// The picker is three-way (None / MCP / CLI) rather than a toggle plus a style
/// switch, because the three states are what the user is actually choosing
/// between: no skill, or exactly one of two mutually exclusive ones. Selecting a
/// variant removes the other — see `SkillInstallManager` for why both at once is
/// a trap.
private struct AgentSkillsSection: View {
    @Environment(AppState.self) var state
    private var manager: SkillInstallManager { state.skillManager }

    private typealias Variant = SkillInstallManager.SkillVariant

    var body: some View {
        Section("Agent Skills") {
            if manager.hasBundledSkills {
                Text("Installed into \(manager.skillsDirectoryPath), which any harness can read — and which the proxy mounts as MCP resources. One per service: picking MCP removes the CLI skill, and the other way round.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(SkillInstallManager.families) { family in
                    familyRow(family)
                }
            } else {
                // The fetch scripts populate Resources/; a bundle built without
                // them has nothing to install and should say why.
                Label("This build doesn't bundle any skills. Run scripts/fetch_binaries.sh and rebuild.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            if let error = manager.lastError {
                ErrorCard(message: error)
            }
        }
    }

    @ViewBuilder
    private func familyRow(_ family: SkillInstallManager.Family) -> some View {
        let installed = manager.installedVariant(family)

        LabeledContent {
            Picker("", selection: Binding<Variant?>(
                get: { installed },
                set: { variant in
                    if let variant { manager.install(family, variant: variant) }
                    else { manager.remove(family) }
                }
            )) {
                Text("None").tag(Optional<Variant>.none)
                ForEach(Variant.allCases) { variant in
                    Text(variant.title)
                        // A variant missing from this build can't be selected —
                        // better a dead segment than an error on tap.
                        .help(manager.bundledSkill(family, variant) == nil
                              ? "Not bundled with this build."
                              : variant.blurb)
                        // Outermost, so tag lookup doesn't have to see through
                        // another modifier to find it.
                        .tag(Optional(variant))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(family.title).font(.body)
                subtitle(family, installed: installed)
            }
        }

        // An update is its own action: the picker already reads as "MCP is on",
        // so re-tapping the selected segment wouldn't be discoverable.
        if let installed,
           case .managed(let marker, let upToDate) = manager.state(family, installed),
           !upToDate,
           let bundled = manager.bundledSkill(family, installed) {
            HStack {
                Text("Bundled: \(bundled.provenance) · installed: \(marker.tag == "local" ? "local checkout" : marker.tag) · \(String(marker.commit.prefix(7)))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Update") { manager.install(family, variant: installed) }
                    .controlSize(.small)
            }
        }

        // The CLI skill's whole playbook is shelling out to a command that isn't
        // on PATH until the section above installs it. Cheap to notice, annoying
        // to debug from the agent's side.
        if installed == .cli, state.cliLinkManager.states[family.cliCommand] != .linked {
            Label("The \(family.cliCommand) command isn't installed above, so this skill's commands won't run.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }

        // A skill directory we don't own blocks that variant. Say so once, naming
        // it, rather than letting the segment look broken.
        ForEach(manager.foreignNames(family), id: \.self) { name in
            Label("~/.agents/skills/\(name) already exists and wasn't installed by Hoplon — it's left alone.",
                  systemImage: "info.circle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func subtitle(_ family: SkillInstallManager.Family,
                         installed: SkillInstallManager.SkillVariant?) -> some View {
        if let installed, case .managed(_, let upToDate) = manager.state(family, installed) {
            let name = family.name(for: installed)
            if upToDate {
                Text("\(name) · \(manager.bundledSkill(family, installed)?.provenance ?? "installed")")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Text("\(name) · update available")
                    .font(.caption).foregroundStyle(.orange)
            }
        } else {
            Text("Not installed").font(.caption).foregroundStyle(.secondary)
        }
    }
}
