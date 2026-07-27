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

/// The Settings window: a sidebar picks a service, its pane fills the detail.
/// Changes apply **immediately** — every field binds straight to `AppState`,
/// whose setters persist and restart the affected service — so there is no
/// Done/Apply step. A top bar carries only a red Close button.
struct SettingsView: View {
    @Environment(AppState.self) var state
    @Environment(\.dismiss) var dismiss

    @State private var selection: AppSection? = .proxy

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            NavigationSplitView {
                List(selection: $selection) {
                    Section("Services") {
                        serviceRow(.proxy)
                        serviceRow(.guardrails)
                        serviceRow(.memory)
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
                .toolbar(removing: .sidebarToggle)
            } detail: {
                detailPane
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 620)
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
        .tag(section)
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .proxy:      ProxySettingsPane()
        case .guardrails: GuardrailsSettingsPane()
        case .memory:     MemorySettingsPane()
        case .code:       CodeIntelligencePlaceholderView()
        case nil:         ContentUnavailableView("Select a Setting", systemImage: "gearshape")
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
                    // Just the text box — the backend URL is the field's value,
                    // so a separate LabeledContent label would echo it twice.
                    TextField("Backend URL", text: $state.guardrailsBackend, prompt: Text("http://127.0.0.1:1234"))
                        .textFieldStyle(.roundedBorder)
                    Text("Point your client at http://127.0.0.1:\(state.guardrailsPort)/v1. Metrics are served on the admin port.")
                        .font(.caption).foregroundStyle(.secondary)
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

// MARK: - Memory pane

private struct MemorySettingsPane: View {
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
                    Text("Serves both surfaces on one port: the REST API the app drives, and the MCP endpoint at http://127.0.0.1:\(state.memoryPort)/mcp.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Agent access") {
                    Toggle("Serve through the MCP proxy", isOn: $state.registerMemoryWithProxy)
                    Text("Keeps a `memory` entry in the proxy's servers.json pointing at this service, so agents reach memory tools through the single proxy endpoint.")
                        .font(.caption).foregroundStyle(.secondary)
                    if ProxyRegistration.hasUserDefinedEntry(in: state.servers) {
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
        .navigationTitle("Memory")
    }
}
