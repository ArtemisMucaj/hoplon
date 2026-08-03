import SwiftUI

/// LLM backend configuration for memory-rs serve: bind each memory job to a
/// provider + model, and manage the inference servers those come from.
///
/// Deliberately separate from codesearch's LLM config: the two services often
/// want different backends (a small local model doing memory extraction, a
/// hosted one answering code questions), so each owns its endpoints.
///
/// No server is "the active one" here — memory resolves chat and embeddings
/// independently and every job can name its own pair, so the list below is
/// inventory, not a selection.
struct MemoryLlmView: View {
    @Environment(AppState.self) var state

    @State private var config: MemoryLlmConfig?
    @State private var configError: String?
    @State private var isLoadingConfig = false

    /// Discovered models per endpoint name, each with its own loading/error state.
    @State private var endpointModels: [String: ModelList] = [:]

    struct ModelList {
        var models: [MemoryLlmModel] = []
        var error: String?
        var isLoading = false
        var loaded = false
    }


    @State private var editingEndpoint: MemoryLlmEndpoint?
    @State private var showAddSheet = false

    // GitHub Copilot: model list, device-flow login, and its poll task.
    @State private var copilotModels = ModelList()
    @State private var copilotLogin: CopilotLoginStatus?
    @State private var isStartingLogin = false
    @State private var loginPollTask: Task<Void, Never>?

    /// Per-usage bindings — the first section, and the reason most people open
    /// this screen.
    @State private var usages: [LlmUsage] = []
    @State private var isSavingUsage = false

    private var manager: MemoryManager { state.memoryManager }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                usagesSection
                serversSection
                if let pinned = config?.pinnedEmbedding { pinnedSection(pinned) }
            }
            .padding()
        }
        .navigationTitle("LLM")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    load(reloadModels: true)
                    loadCopilotModels()
                    loadUsages()
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(isLoadingConfig)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            MemoryEndpointEditorView(existing: nil) { name, request in
                await save(name: name, request: request)
            }
        }
        .sheet(item: $editingEndpoint) { endpoint in
            MemoryEndpointEditorView(existing: endpoint) { name, request in
                await save(name: name, request: request)
            }
        }
        // Load everything on open (models included) so the page is populated
        // without a manual click.
        .onAppear {
            if config == nil { load(reloadModels: true) }
            if !copilotModels.loaded { loadCopilotModels() }
            if usages.isEmpty { loadUsages() }
        }
        .onDisappear { loginPollTask?.cancel() }
    }

    // MARK: - Usages

    @ViewBuilder
    private var usagesSection: some View {
        LlmUsagesSection(
            usages: usages,
            choices: chatChoices,
            embeddingChoices: embeddingChoices,
            isBusy: isSavingUsage
        ) { usage, choice in
            Task { await bindUsage(usage, to: choice) }
        }
    }

    /// Every (provider, model) pair that can answer a chat job: each registered
    /// endpoint crossed with the models it reports, plus Copilot when signed in.
    private var chatChoices: [LlmChoice] {
        var out: [LlmChoice] = []
        for endpoint in config?.endpoints ?? [] {
            let models = endpointModels[endpoint.name]?.models.map(\.id) ?? []
            if models.isEmpty {
                // Not probed yet (or unreachable) — still offer the endpoint so
                // its configured model can be selected.
                out.append(LlmChoice(endpoint: endpoint.name, model: endpoint.model))
            } else {
                out.append(contentsOf: models.map { LlmChoice(endpoint: endpoint.name, model: $0) })
            }
        }
        if config?.copilot?.authenticated == true {
            let models = copilotModels.models.map(\.id)
            let name = MemoryLlmConfig.copilotEndpointName
            out.append(contentsOf: models.isEmpty
                       ? [LlmChoice(endpoint: name, model: config?.copilot?.model)]
                       : models.map { LlmChoice(endpoint: name, model: $0) })
        }
        return out
    }

    /// Chat choices minus Copilot: it has no embeddings endpoint, and memory has
    /// no in-process embedder to fall back on.
    private var embeddingChoices: [LlmChoice] {
        chatChoices.filter { $0.endpoint != MemoryLlmConfig.copilotEndpointName }
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
                if isLoadingConfig { ProgressView().controlSize(.small) }
                Button { showAddSheet = true } label: { Label("Add", systemImage: "plus") }
                    .controlSize(.small)
            }

            if let configError {
                Label(configError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }

            CardContainer {
                VStack(spacing: 0) {
                    ForEach(config?.endpoints ?? []) { endpoint in
                        endpointRow(endpoint)
                        Divider()
                    }
                    copilotRow
                }
            }

            if let config, config.endpoints.isEmpty {
                Text("No endpoint yet — memory falls back to the OPENAI_* environment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func endpointRow(_ endpoint: MemoryLlmEndpoint) -> some View {
        let list = endpointModels[endpoint.name] ?? ModelList()
        LlmProviderRow(
            name: endpoint.name,
            subtitle: endpoint.baseUrl,
            hasKey: endpoint.hasApiKey,
            isLoading: list.isLoading,
            error: list.error,
            models: list.models.map { LlmModelRow(id: $0.id, detail: $0.vendor) },
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
                models: copilotModels.models.map { LlmModelRow(id: $0.id, detail: $0.vendor) },
                loaded: copilotModels.loaded
            ) {
                Button { loadCopilotModels() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload Copilot models")
            }
        }
    }

    /// Whether Copilot needs authentication (never logged in, or a login failed).
    private var copilotNeedsAuth: Bool {
        if case .failed = copilotLogin?.state { return true }
        return config?.copilot?.authenticated != true
    }

    private var isPendingLogin: Bool {
        if case .pending = copilotLogin?.state { return true }
        return false
    }

    // MARK: - Pinned embedding warning

    @ViewBuilder
    private func pinnedSection(_ pinned: MemoryPinnedEmbedding) -> some View {
        CardContainer {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                // The one setting here that can strand the store, so it gets a
                // warning rather than a failure at the next launch.
                Text("Embeddings are pinned to \(pinned.model) · \(pinned.dimensions) dimensions. A model of a different width is rejected when memory next opens the store.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    // MARK: - Loading

    /// Load the usage bindings — the first section's data.
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
            configError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func load(reloadModels: Bool) {
        isLoadingConfig = true
        configError = nil
        Task {
            defer { isLoadingConfig = false }
            do {
                let loaded = try await manager.makeClient().llmConfig()
                config = loaded
                if reloadModels {
                    for endpoint in loaded.endpoints { loadModels(for: endpoint) }
                }
            } catch {
                configError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func loadModels(for endpoint: MemoryLlmEndpoint) {
        var list = endpointModels[endpoint.name] ?? ModelList()
        list.isLoading = true
        list.error = nil
        endpointModels[endpoint.name] = list
        Task {
            do {
                let response = try await manager.makeClient().llmModels(endpoint: endpoint.name)
                endpointModels[endpoint.name] = ModelList(
                    models: response.models, error: nil, isLoading: false, loaded: true
                )
            } catch {
                endpointModels[endpoint.name] = ModelList(
                    models: [],
                    error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    isLoading: false,
                    loaded: true
                )
            }
        }
    }

    // MARK: - Copilot actions

    private func loadCopilotModels() {
        copilotModels.isLoading = true
        copilotModels.error = nil
        Task {
            do {
                let response = try await manager.makeClient()
                    .llmModels(endpoint: MemoryLlmConfig.copilotEndpointName)
                copilotModels = ModelList(models: response.models, error: nil, isLoading: false, loaded: true)
            } catch {
                copilotModels = ModelList(
                    models: [],
                    error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    isLoading: false,
                    loaded: true
                )
            }
        }
    }

    /// Start the device flow and poll until it settles. The server persists the
    /// token itself, so on success we just reload config + models.
    private func startCopilotLogin() async {
        isStartingLogin = true
        defer { isStartingLogin = false }
        do {
            copilotLogin = try await manager.makeClient().startCopilotLogin()
        } catch {
            configError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        guard case .pending = copilotLogin?.state else { return }

        loginPollTask?.cancel()
        loginPollTask = Task {
            // The device code is valid for minutes; poll until it resolves or
            // the user leaves the screen (onDisappear cancels us).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                guard let status = try? await manager.makeClient().copilotLoginStatus() else { continue }
                copilotLogin = status
                switch status.state {
                case .authorized:
                    load(reloadModels: false)
                    loadCopilotModels()
                    loadUsages()
                    return
                case .failed, .idle:
                    return
                case .pending:
                    continue
                }
            }
        }
    }

    // MARK: - Actions

    private func save(name: String, request: MemoryLlmUpsertRequest) async -> Bool {
        var request = request
        // Nothing on this screen sets a "default" server any more, but the
        // server still resolves unbound jobs through one — so the first
        // endpoint registered silently becomes it, rather than leaving every
        // job pointing at the OPENAI_* fallback.
        if config?.active == nil { request.setActive = .shared }
        do {
            config = try await manager.makeClient().upsertLlmEndpoint(name: name, request)
            if let endpoint = config?.endpoints.first(where: { $0.name == name }) {
                loadModels(for: endpoint)
            }
            return true
        } catch {
            configError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private func remove(_ endpoint: MemoryLlmEndpoint) async {
        do {
            config = try await manager.makeClient().deleteLlmEndpoint(name: endpoint.name)
            endpointModels.removeValue(forKey: endpoint.name)
        } catch {
            configError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Add / edit sheet

/// Transactional editor for one endpoint (sheets are for transactions). The
/// name is fixed when editing — it's the config key.
struct MemoryEndpointEditorView: View {
    let existing: MemoryLlmEndpoint?
    /// Returns whether the save succeeded, so this editor dismisses only on
    /// success and stays open (with the typed values intact) on failure.
    let onSave: (String, MemoryLlmUpsertRequest) async -> Bool
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var baseUrl: String
    @State private var model: String
    @State private var embeddingModel: String
    @State private var apiKey = ""
    @State private var isSaving = false

    init(existing: MemoryLlmEndpoint?, onSave: @escaping (String, MemoryLlmUpsertRequest) async -> Bool) {
        self.existing = existing
        self.onSave = onSave
        _name           = State(initialValue: existing?.name ?? "")
        // memory-rs appends `/v1/...` itself, so the base must NOT include it
        // (a trailing `/v1` yields `/v1/v1/models`).
        _baseUrl        = State(initialValue: existing?.baseUrl ?? "http://127.0.0.1:1234")
        _model          = State(initialValue: existing?.model ?? "")
        _embeddingModel = State(initialValue: existing?.embeddingModel ?? "")
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
                TextField("Chat model (optional)", text: $model)
                TextField("Embedding model (optional)", text: $embeddingModel)
                SecureField(existing?.hasApiKey == true ? "API key (leave blank to keep current)" : "API key (optional)",
                            text: $apiKey)
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(existing == nil ? "Add" : "Save") {
                    isSaving = true
                    // Strip a trailing `/v1` the user may have pasted — the
                    // server adds it, so keeping it breaks model discovery.
                    var cleanedBase = baseUrl.trimmingCharacters(in: .whitespaces)
                    while cleanedBase.hasSuffix("/") { cleanedBase.removeLast() }
                    if cleanedBase.hasSuffix("/v1") { cleanedBase.removeLast(3) }
                    while cleanedBase.hasSuffix("/") { cleanedBase.removeLast() }
                    let request = MemoryLlmUpsertRequest(
                        baseUrl: cleanedBase,
                        model: model.isEmpty ? nil : model,
                        embeddingModel: embeddingModel.isEmpty ? nil : embeddingModel,
                        apiKey: apiKey.isEmpty ? nil : apiKey
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
        .frame(width: 460)
    }
}
