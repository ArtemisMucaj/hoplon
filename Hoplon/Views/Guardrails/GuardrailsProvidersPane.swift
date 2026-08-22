import SwiftUI

/// Guardrails ▸ Providers — which upstreams the proxy routes to, and which of
/// their models it serves.
///
/// This drives the management API rather than launch flags, because the proxy's
/// `config.json` wins over flags once it exists: a change made here applies to
/// the live registry and is persisted in the same call, so it takes effect
/// without a restart and survives one.
///
/// A hidden model is **not served**, not merely unlisted — it disappears from
/// `/v1/models` and requests naming it are refused. The pane says so, because
/// "hidden" could otherwise read as cosmetic.
struct GuardrailsProvidersPane: View {
    @Environment(AppState.self) var state

    @State private var showingAdd = false
    @State private var newName = ""
    @State private var newBaseURL = ""
    @State private var newUnversioned = false
    @State private var confirmingRemoval: String?

    private var manager: GuardrailsManager { state.guardrailsManager }
    private var providers: GuardrailsProvidersManager { manager.providers }

    var body: some View {
        Form {
            if !manager.isRunning {
                Section {
                    Label(
                        "Start Guardrails to configure its providers.",
                        systemImage: "shield.slash"
                    )
                    .foregroundStyle(.secondary)
                }
            } else if providers.isUnavailable {
                Section {
                    Label(
                        "This proxy was started without a configuration file, so its providers cannot be changed from here.",
                        systemImage: "lock"
                    )
                    .foregroundStyle(.secondary)
                }
            } else {
                if let error = providers.lastError {
                    Section { ErrorCard(message: error) }
                }
                copilotSection
                ForEach(providers.providers) { provider in
                    section(for: provider)
                }
                Section {
                    Button {
                        newName = ""; newBaseURL = ""; newUnversioned = false
                        showingAdd = true
                    } label: {
                        Label("Add Provider", systemImage: "plus")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Providers")
        .task(id: manager.isRunning) {
            guard manager.isRunning else { return }
            providers.adminBase = manager.adminBase
            await providers.load()
            await providers.loadCopilot()
        }
        .onDisappear { providers.stopPolling() }
        .sheet(isPresented: $showingAdd) { addSheet }
        .alert(
            "Remove “\(confirmingRemoval ?? "")”?",
            isPresented: Binding(
                get: { confirmingRemoval != nil },
                set: { if !$0 { confirmingRemoval = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
            Button("Remove", role: .destructive) {
                if let name = confirmingRemoval {
                    Task { await providers.remove(name) }
                }
                confirmingRemoval = nil
            }
        } message: {
            // Removal loses the per-model choices; the models themselves are
            // rediscovered if the provider is added back.
            Text("The proxy stops routing to it, and the exposure choices made for its models are lost.")
        }
    }

    // MARK: - One provider

    @ViewBuilder
    private func section(for provider: ProviderConfig) -> some View {
        Section {
            Toggle("Routed", isOn: Binding(
                get: { provider.enabled },
                set: { value in Task { await providers.setEnabled(provider.name, value) } }
            ))
            .disabled(providers.busy.contains(provider.name))

            Toggle("Expose new models automatically", isOn: Binding(
                get: { provider.exposeByDefault },
                set: { value in
                    Task { await providers.setExposeByDefault(provider.name, value) }
                }
            ))
            .disabled(providers.busy.contains(provider.name))
            .help("A model this provider starts offering is served without a visit to this screen.")

            if provider.models.isEmpty {
                Text("No models discovered. A provider that started after the proxy claims none until the next restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Models (\(provider.exposedCount) of \(provider.models.count) served)") {
                    ForEach(provider.models) { model in
                        row(for: model, in: provider)
                    }
                }
            }

            Button(role: .destructive) {
                confirmingRemoval = provider.name
            } label: {
                Label("Remove Provider", systemImage: "trash")
            }
            .disabled(providers.busy.contains(provider.name))
        } header: {
            HStack {
                Text(provider.name)
                if !provider.enabled {
                    Text("off")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.secondary.opacity(0.2)))
                }
                Spacer()
                Text(provider.baseURL).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(for model: ProviderModel, in provider: ProviderConfig) -> some View {
        Toggle(isOn: Binding(
            get: { model.exposed },
            set: { value in
                Task {
                    await providers.setModelExposed(
                        provider.name, model: model.id, exposed: value
                    )
                }
            }
        )) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.label).lineLimit(1).truncationMode(.middle)
                    if let vendor = model.vendor {
                        Text(vendor).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                // Exposed but not routed means the change is recorded and the
                // model was never discovered — worth distinguishing from a
                // model the proxy is actually serving.
                if model.exposed && !model.routed {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Exposed, but the provider has not reported this model — it is not currently routed.")
                }
            }
        }
        .disabled(!provider.enabled || providers.busy.contains(provider.name))
    }

    // MARK: - Copilot

    @ViewBuilder
    private var copilotSection: some View {
        if !providers.copilotUnavailable {
            Section("GitHub Copilot") {
                if let status = providers.copilot, status.state == .authorized {
                    Label("Authorized", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("The proxy can serve Copilot models using your subscription.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Re-authorize") { Task { await providers.startCopilotLogin() } }
                } else if let status = providers.copilot, status.state == .pending,
                          let code = status.userCode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter this code at GitHub:").font(.caption).foregroundStyle(.secondary)
                        Text(code)
                            .font(.system(.title2, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                        if let uri = status.verificationUri, let url = URL(string: uri) {
                            Link(destination: url) {
                                Label(uri, systemImage: "arrow.up.forward.square")
                            }
                            .font(.callout)
                        }
                        ProgressView().controlSize(.small)
                    }
                    .padding(.vertical, 2)
                } else {
                    if let error = providers.copilot?.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Authorize once to proxy Copilot models with your subscription.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Sign in with GitHub") {
                        Task { await providers.startCopilotLogin() }
                    }
                }
            }
        }
    }

    // MARK: - Add sheet

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Provider").font(.headline)
            Form {
                TextField("Name", text: $newName, prompt: Text("lmstudio"))
                TextField("Base URL", text: $newBaseURL, prompt: Text("http://127.0.0.1:1234"))
                Toggle("Routes served at the root (no /v1)", isOn: $newUnversioned)
                    .help("For upstreams that serve /chat/completions rather than /v1/chat/completions.")
            }
            .formStyle(.grouped)
            Text("The name identifies this provider in the metrics, so it must be unique.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showingAdd = false }
                Button("Add") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = newBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    showingAdd = false
                    Task { await providers.add(name: name, baseURL: url, unversioned: newUnversioned) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || newBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
