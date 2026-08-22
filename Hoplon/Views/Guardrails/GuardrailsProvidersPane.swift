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
    @State private var confirmingRemoval: String?
    @State private var enablingCopilot = false

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
                ForEach(providers.providers) { provider in
                    section(for: provider)
                }
                Section {
                    Button {
                        newName = ""; newBaseURL = ""
                        showingAdd = true
                    } label: {
                        Label("Add Provider", systemImage: "plus")
                    }
                }
                // Below the providers and the add button, because it is a way
                // to *get* a provider — not a peer of the ones already there.
                // Once Copilot is configured it appears in the list above like
                // any other, so this section removes itself rather than
                // offering to set up something already set up.
                copilotSection
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
                // Shown inline rather than behind a disclosure: choosing which
                // models a provider serves is the main thing this pane is for,
                // so it should not need a click to find.
                HStack {
                    Text("Models")
                    Text("\(provider.exposedCount) of \(provider.models.count) served")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("All") {
                        Task {
                            await providers.setModelsExposed(
                                provider.name, models: provider.models.map(\.id), exposed: true
                            )
                        }
                    }
                    .controlSize(.small)
                    .disabled(provider.exposedCount == provider.models.count)
                    Button("None") {
                        Task {
                            await providers.setModelsExposed(
                                provider.name, models: provider.models.map(\.id), exposed: false
                            )
                        }
                    }
                    .controlSize(.small)
                    .disabled(provider.exposedCount == 0)
                }
                .disabled(providers.busy.contains(provider.name))

                // Keyed by (provider, model), not the bare model id: every
                // provider's rows live in ONE `Form`, and two providers can
                // serve the same id (Copilot and a local server both offering
                // `qwen2.5-7b`). Sharing an id makes SwiftUI treat them as one
                // row — the same trap the sidebar hit.
                ForEach(provider.identifiedModels, id: \.rowID) { entry in
                    row(for: entry.model, in: provider)
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

    /// Copilot as an inventory row, matching the LLM panes: the same
    /// `CopilotSignInRow` drives the same server-side device flow, so it reads
    /// and behaves identically wherever it appears.
    ///
    /// Always shown, never gated on the proxy already running with `--copilot`.
    /// Those routes 404 until the flag is set, so a section that hid itself
    /// when they did would be invisible exactly when a user goes looking for
    /// it — which is what "where is the GitHub Copilot setting?" means.
    ///
    /// Signing in *is* the decision to proxy Copilot: it sets the flag, waits
    /// for the proxy to come back, and then starts the device flow. Which of
    /// its models are served is afterwards the same per-model choice every
    /// other provider gets, in the section below.
    /// True once guardrails has registered the Copilot provider — which only
    /// happens after a successful device-flow login.
    private var copilotConfigured: Bool {
        providers.providers.contains { $0.name == GuardrailsProvidersManager.copilotProvider }
    }

    @ViewBuilder
    private var copilotSection: some View {
        // Gone entirely once Copilot is a provider like any other: its section
        // above already carries the routing toggle and the model list, so a
        // second "set up Copilot" block would invite setting up what is set up.
        if !copilotConfigured {
            Section("GitHub Copilot") {
                CopilotSignInRow(login: providers.copilot, isStarting: enablingCopilot) {
                    signInToCopilot()
                }
                if !state.guardrailsCopilot {
                    Text("Signing in restarts the proxy so it can carry your Copilot credential.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Turn on `--copilot` if it is off, then start the device flow.
    ///
    /// The flag has to be set before the login routes exist at all, and setting
    /// it restarts the proxy — so the flow waits for the admin server to answer
    /// again rather than firing a request at a port that is still rebinding.
    private func signInToCopilot() {
        guard !enablingCopilot else { return }
        if state.guardrailsCopilot {
            Task { await providers.startCopilotLogin() }
            return
        }
        enablingCopilot = true
        state.guardrailsCopilot = true
        Task {
            defer { enablingCopilot = false }
            // Wait for the restarted proxy, then reload through the new port.
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if manager.isRunning, await providers.isReachable() { break }
            }
            providers.adminBase = manager.adminBase
            await providers.startCopilotLogin()
            await providers.load()
            // The provider only exists once the flow completes, so refresh
            // again when it does — otherwise its models never appear without a
            // manual revisit.
            await providers.reloadWhenCopilotLands()
        }
    }

    // MARK: - Add sheet

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Provider").font(.headline)
            Form {
                TextField("Name", text: $newName, prompt: Text("lmstudio"))
                TextField("Base URL", text: $newBaseURL, prompt: Text("http://127.0.0.1:1234"))
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
                    Task { await providers.add(name: name, baseURL: url) }
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
