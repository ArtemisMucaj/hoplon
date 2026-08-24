import SwiftUI

/// LLM backend configuration for codesearch serve: bind each LLM job to a
/// provider + model, and manage the inference servers those come from (OpenAI
/// `/v1/models`, GitHub Copilot). Model ids also feed the per-request override
/// on the Call Graph explain stream.
///
/// No server is "the active one" on this screen — every job names its own pair,
/// so the list below is inventory, not a selection.
struct LlmView: View {
    @Environment(AppState.self) var state

    @State private var endpoints: LlmEndpointsResponse?
    @State private var endpointsError: String?
    @State private var isLoadingEndpoints = false
    @State private var endpointsTask: Task<Void, Never>?

    // Model discovery. OpenAI models are loaded PER configured endpoint (keyed
    // by endpoint name); Copilot has a single list.
    @State private var endpointModels: [String: ModelList] = [:]
    @State private var copilotModels = ModelList()

    /// Discovered models for one backend/endpoint, with its own loading/error state.
    struct ModelList {
        var models: [LlmModel] = []
        var error: String?
        var isLoading = false
        var loaded = false
    }

    @State private var editingEndpoint: LlmEndpoint?
    @State private var showAddSheet = false

    /// The server's backend target and pinned Copilot model. Nothing here sets
    /// them any more — they are read so a Copilot job whose model list hasn't
    /// loaded still shows the model that will actually run.
    @State private var activeTarget: LlmTargetResponse?

    // GitHub Copilot device-flow login (driven by the management API).
    @State private var copilotLogin: CopilotLoginStatus?
    @State private var isStartingLogin = false
    @State private var loginPollTask: Task<Void, Never>?

    /// Per-usage bindings — the first section, and the reason most people open
    /// this screen.
    @State private var usages: [LlmUsage] = []
    @State private var isSavingUsage = false

    private var manager: CodesearchManager { state.codesearchManager }

    /// Whether Copilot needs authentication (the models call reported it, or a
    /// login attempt failed).
    private var copilotNeedsAuth: Bool {
        if case .failed = copilotLogin?.state { return true }
        if let e = copilotModels.error?.lowercased(), e.contains("not authenticated") { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                usagesSection
                serversSection
            }
            .padding()
        }
        .navigationTitle("LLM")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    loadEndpoints(reloadModels: true)
                    loadCopilotModels()
                    loadTarget()
                    loadUsages()
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(isLoadingEndpoints)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            EndpointEditorView(existing: nil) { name, request in
                await save(name: name, request: request)
            }
        }
        .sheet(item: $editingEndpoint) { endpoint in
            EndpointEditorView(existing: endpoint) { name, request in
                await save(name: name, request: request)
            }
        }
        // Load everything on open (models included) so the page is populated
        // without a manual "Load Models" click.
        .onAppear {
            if endpoints == nil { loadEndpoints(reloadModels: true) }
            if !copilotModels.loaded { loadCopilotModels() }
            if activeTarget == nil { loadTarget() }
            if usages.isEmpty { loadUsages() }
        }
        .onDisappear {
            endpointsTask?.cancel(); isLoadingEndpoints = false
            loginPollTask?.cancel()
        }
    }

    // MARK: - Usages

    @ViewBuilder
    private var usagesSection: some View {
        LlmUsagesSection(
            usages: usages,
            choices: chatChoices,
            // codesearch has no embedding usage; the parameter is satisfied for
            // the shared component's sake.
            embeddingChoices: chatChoices,
            isBusy: isSavingUsage
        ) { usage, choice in
            Task { await bindUsage(usage, to: choice) }
        }
    }

    /// Every (provider, model) pair that can answer a job: each registered
    /// endpoint crossed with its discovered models, plus Copilot when signed in.
    private var chatChoices: [LlmChoice] {
        var out: [LlmChoice] = []
        for endpoint in endpoints?.sortedEndpoints ?? [] {
            let models = endpointModels[endpoint.name]?.models.map(\.id) ?? []
            if models.isEmpty {
                // Not probed yet (or unreachable) — still offer the endpoint so
                // its configured model can be selected.
                out.append(LlmChoice(endpoint: endpoint.name, model: endpoint.model))
            } else {
                out.append(contentsOf: models.map { LlmChoice(endpoint: endpoint.name, model: $0) })
            }
        }
        if !copilotNeedsAuth {
            let models = copilotModels.models.map(\.id)
            out.append(contentsOf: models.isEmpty
                       ? [LlmChoice(endpoint: "copilot", model: activeTarget?.copilotModel)]
                       : models.map { LlmChoice(endpoint: "copilot", model: $0) })
        }
        return out
    }

    private func loadUsages() {
        Task {
            if let list = try? await manager.makeClient().llmUsages() { usages = list }
        }
    }

    /// Persist one usage's binding.
    private func bindUsage(_ usage: LlmUsage, to choice: LlmChoice) async {
        isSavingUsage = true
        defer { isSavingUsage = false }
        do {
            let updated = try await manager.makeClient().setLlmUsage(
                usage.id, endpoint: choice.endpoint, model: choice.model
            )
            if let idx = usages.firstIndex(where: { $0.id == updated.id }) {
                usages[idx] = updated
            }
        } catch {
            endpointsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Inference servers

    /// The registered servers, Copilot included, each folded to one row.
    ///
    /// Inventory, not a selection: no row is "the active one" now that every
    /// job names its own provider and model above.
    @ViewBuilder
    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Inference servers") {
                if isLoadingEndpoints { ProgressView().controlSize(.small) }
                Button { showAddSheet = true } label: { Label("Add", systemImage: "plus") }
                    .controlSize(.small)
            }

            if let endpointsError {
                Label(endpointsError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }

            CardContainer {
                VStack(spacing: 0) {
                    ForEach(endpoints?.sortedEndpoints ?? []) { endpoint in
                        endpointRow(endpoint)
                        Divider()
                    }
                    copilotRow
                }
            }

            if let endpoints, endpoints.endpoints.isEmpty {
                Text("No endpoint yet — codesearch falls back to the OPENAI_* environment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func endpointRow(_ endpoint: LlmEndpoint) -> some View {
        let list = endpointModels[endpoint.name] ?? ModelList()
        LlmProviderRow(
            name: endpoint.name,
            subtitle: endpoint.baseUrl,
            hasKey: endpoint.hasKey,
            isLoading: list.isLoading,
            error: list.error,
            models: list.models.map { LlmModelRow(id: $0.id, detail: $0.name) },
            loaded: list.loaded
        ) {
            Button { loadModels(for: endpoint) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Reload models")
            Button { editingEndpoint = endpoint } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("Edit endpoint")
            Button(role: .destructive) {
                Task { await remove(endpoint) }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Remove endpoint")
        }
    }

    /// Remove one endpoint, mirroring the Memory pane. The refreshed list comes
    /// back from the server, so the active endpoint the server picked after the
    /// removal is whatever renders — the view never guesses it.
    private func remove(_ endpoint: LlmEndpoint) async {
        do {
            let response = try await manager.makeClient().deleteLlmEndpoint(name: endpoint.name)
            endpoints = response
            endpointModels.removeValue(forKey: endpoint.name)
            // A sheet open on the endpoint we just removed would re-create it on
            // Save, since the editor persists with PUT.
            if editingEndpoint?.name == endpoint.name { editingEndpoint = nil }
            endpointsError = nil
            // Usage bindings live on the server, not in anything derived from
            // `endpoints`: removing an endpoint drops the bindings that named
            // it, so the usages above fall back to inheriting the active one.
            // Re-read them rather than trying to recompute the fallback here.
            loadUsages()
        } catch {
            endpointsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Copilot as one more server in the list — a sign-in row until the device
    /// flow completes, then a normal collapsed row.
    @ViewBuilder
    private var copilotRow: some View {
        if copilotNeedsAuth || isPendingLogin {
            CopilotSignInRow(login: copilotLogin, isStarting: isStartingLogin) {
                Task { await startCopilotLogin() }
            }
        } else {
            LlmProviderRow(
                name: "GitHub Copilot",
                subtitle: "chat only · your Copilot subscription",
                isLoading: copilotModels.isLoading,
                error: copilotModels.error,
                models: copilotModels.models.map { LlmModelRow(id: $0.id, detail: $0.name) },
                loaded: copilotModels.loaded
            ) {
                Button { loadCopilotModels() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload Copilot models")
            }
        }
    }

    /// True while a device-flow login is pending (waiting on the browser step).
    private var isPendingLogin: Bool {
        if case .pending = copilotLogin?.state { return true }
        return isStartingLogin
    }

    // MARK: - Actions

    private func loadEndpoints(reloadModels: Bool) {
        endpointsTask?.cancel()
        isLoadingEndpoints = true
        endpointsError = nil
        let client = manager.makeClient()
        endpointsTask = Task {
            do {
                let response = try await client.llmEndpoints()
                if Task.isCancelled { return }
                await MainActor.run {
                    endpoints = response
                    isLoadingEndpoints = false
                    if reloadModels {
                        for endpoint in response.endpoints { loadModels(for: endpoint) }
                    }
                }
            } catch is CancellationError {
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    endpointsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    isLoadingEndpoints = false
                }
            }
        }
    }

    /// Load one OpenAI endpoint's models into `endpointModels[name]`. When the
    /// endpoint has no model pinned yet, auto-pin the first discovered model so
    /// there's always a concrete selection (instead of the server's implicit
    /// default, which the UI can't reflect).
    private func loadModels(for endpoint: LlmEndpoint) {
        let name = endpoint.name
        let hasNoModel = (endpoint.model ?? "").isEmpty
        endpointModels[name, default: ModelList()].isLoading = true
        endpointModels[name]?.error = nil
        let client = manager.makeClient()
        Task {
            do {
                let response = try await client.llmModels(target: .openai, endpoint: name)
                await MainActor.run { endpointModels[name] = ModelList(models: response.models, error: nil, isLoading: false, loaded: true) }
                // Pin the default only if still unpinned (the user may have
                // selected one in the meantime) and models are available.
                if hasNoModel, let first = response.models.first,
                   (endpoints?.endpoints.first(where: { $0.name == name })?.model ?? "").isEmpty {
                    await pinModel(first.id, for: endpoint)
                }
            } catch is CancellationError {
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { endpointModels[name] = ModelList(models: [], error: message, isLoading: false, loaded: true) }
            }
        }
    }

    private func loadCopilotModels() {
        copilotModels.isLoading = true; copilotModels.error = nil
        let client = manager.makeClient()
        Task {
            do {
                let response = try await client.llmModels(target: .copilot)
                await MainActor.run { copilotModels = ModelList(models: response.models, error: nil, isLoading: false, loaded: true) }
            } catch is CancellationError {
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { copilotModels = ModelList(models: [], error: message, isLoading: false, loaded: true) }
            }
        }
    }

    // MARK: - Copilot login

    /// Start the device flow, then poll until it resolves. On success, reload
    /// the Copilot models so they replace the sign-in card.
    private func startCopilotLogin() async {
        isStartingLogin = true
        do {
            let initial = try await manager.makeClient().startCopilotLogin()
            copilotLogin = initial
            isStartingLogin = false
            if initial.state == .pending {
                // Open the verification page for convenience.
                if let uri = initial.verificationUri, let url = URL(string: uri) {
                    NSWorkspace.shared.open(url)
                }
                pollCopilotLogin()
            }
        } catch {
            isStartingLogin = false
            copilotLogin = nil
            copilotModels.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func pollCopilotLogin() {
        loginPollTask?.cancel()
        loginPollTask = Task {
            let client = manager.makeClient()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                guard let status = try? await client.copilotLoginStatus() else { continue }
                await MainActor.run { copilotLogin = status }
                switch status.state {
                case .authorized:
                    await MainActor.run { copilotLogin = nil; loadCopilotModels() }
                    return
                case .failed:
                    return
                default:
                    break
                }
            }
        }
    }

    /// Pin a model on an endpoint that has none, so its configured model is a
    /// concrete id rather than the server's implicit default (which the UI
    /// can't reflect). Never changes which endpoint the server treats as
    /// active — that is not a choice this screen makes.
    private func pinModel(_ modelID: String, for endpoint: LlmEndpoint) async {
        do {
            let response = try await manager.makeClient().upsertLlmEndpoint(
                name: endpoint.name,
                LlmUpsertEndpointRequest(baseUrl: endpoint.baseUrl, model: modelID, apiKey: nil,
                                         setActive: endpoint.active)
            )
            await MainActor.run { endpoints = response }
        } catch {
            await MainActor.run {
                endpointsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Load which backend is live and which Copilot model is pinned — read-only
    /// here, and only so a Copilot job can name its model before the model list
    /// arrives.
    private func loadTarget() {
        let client = manager.makeClient()
        Task {
            if let target = try? await client.llmTarget() {
                await MainActor.run { activeTarget = target }
            }
        }
    }

    /// Shared save path for add + edit. Returns whether the save succeeded so
    /// the sheet stays open on failure (letting the user correct/retry) and only
    /// dismisses once the endpoint is persisted. Errors surface on the page.
    private func save(name: String, request: LlmUpsertEndpointRequest) async -> Bool {
        var request = request
        // Nothing on this screen picks a default server any more, but the
        // server still resolves unbound jobs through one — so the first
        // endpoint registered silently becomes it, rather than leaving every
        // job on the OPENAI_* fallback.
        if endpoints?.active == nil { request.setActive = true }
        do {
            let response = try await manager.makeClient().upsertLlmEndpoint(name: name, request)
            await MainActor.run {
                endpoints = response
                endpointsError = nil
                // Refresh the saved endpoint's models (base URL may have changed).
                if let endpoint = response.endpoints.first(where: { $0.name == name }) {
                    loadModels(for: endpoint)
                }
            }
            return true
        } catch {
            await MainActor.run {
                endpointsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return false
        }
    }
}

// MARK: - Add / edit sheet

/// Transactional editor for one endpoint (sheets are for transactions). The
/// name is fixed when editing — it's the config key.
struct EndpointEditorView: View {
    let existing: LlmEndpoint?
    /// Returns whether the save succeeded, so this editor dismisses only on
    /// success and stays open (with the typed values intact) on failure.
    let onSave: (String, LlmUpsertEndpointRequest) async -> Bool
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var baseUrl: String
    @State private var model: String
    @State private var apiKey = ""
    @State private var isSaving = false

    init(existing: LlmEndpoint?, onSave: @escaping (String, LlmUpsertEndpointRequest) async -> Bool) {
        self.existing = existing
        self.onSave = onSave
        _name      = State(initialValue: existing?.name ?? "")
        // codesearch appends `/v1/...` itself, so the base must NOT include it
        // (a trailing `/v1` yields `/v1/v1/models` and a 500). Default and
        // prompt reflect the bare host.
        _baseUrl   = State(initialValue: existing?.baseUrl ?? "http://127.0.0.1:1234")
        _model     = State(initialValue: existing?.model ?? "")
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !baseUrl.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Add Endpoint" : "Edit \(existing!.name)")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Name", text: $name)
                    .disabled(existing != nil)
                TextField("Base URL", text: $baseUrl, prompt: Text("http://127.0.0.1:1234"))
                TextField("Model (optional)", text: $model)
                SecureField(existing?.hasKey == true ? "API key (leave blank to keep current)" : "API key (optional)",
                            text: $apiKey)
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(existing == nil ? "Add" : "Save") {
                    isSaving = true
                    // Strip a trailing `/v1` the user may have pasted —
                    // codesearch adds it, so keeping it breaks model discovery.
                    var cleanedBase = baseUrl.trimmingCharacters(in: .whitespaces)
                    while cleanedBase.hasSuffix("/") { cleanedBase.removeLast() }
                    if cleanedBase.hasSuffix("/v1") { cleanedBase.removeLast(3) }
                    while cleanedBase.hasSuffix("/") { cleanedBase.removeLast() }
                    let request = LlmUpsertEndpointRequest(
                        baseUrl: cleanedBase,
                        model: model.isEmpty ? nil : model,
                        apiKey: apiKey.isEmpty ? nil : apiKey,
                        // The owning pane decides this: the first endpoint
                        // registered becomes the fallback, nothing else does.
                        setActive: existing?.active ?? false
                    )
                    let endpointName = name.trimmingCharacters(in: .whitespaces)
                    Task {
                        let success = await onSave(endpointName, request)
                        await MainActor.run {
                            isSaving = false
                            if success { dismiss() }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || isSaving)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
