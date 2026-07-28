import SwiftUI

/// LLM backend configuration for memory-rs serve: manage the OpenAI-compatible
/// endpoints stored in the server's config (add/update, set active) and discover
/// the models each backend offers.
///
/// Deliberately separate from codesearch's LLM config: the two services often
/// want different backends (a small local model doing memory extraction, a
/// hosted one answering code questions), so each owns its endpoints.
///
/// The one structural difference from the codesearch screen is that memory
/// resolves **chat and embeddings independently** — an endpoint can be the chat
/// backend, the embedding backend, or both — so each card's model list has a
/// Chat/Embeddings switch deciding which slot a tapped model fills.
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
                endpointsSection
                copilotSection
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

    // MARK: - Endpoints

    @ViewBuilder
    private var endpointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("OpenAI-compatible endpoints") {
                Button { showAddSheet = true } label: { Label("Add Endpoint", systemImage: "plus") }
                    .controlSize(.small)
            }
            Text("Each endpoint (LM Studio, vLLM, hosted OpenAI, …) is stored by the memory server. Chat and embeddings resolve independently, so one endpoint can answer extraction while another embeds. API keys are write-only.")
                .font(.caption).foregroundStyle(.secondary)

            if let configError {
                Label(configError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if let config, config.endpoints.isEmpty {
                CardContainer {
                    Text("No endpoints configured yet. Add one, or the server falls back to the OPENAI_* environment variables.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else if let config {
                ForEach(config.endpoints) { endpoint in
                    endpointCard(endpoint, config: config)
                }
            } else if isLoadingConfig {
                HStack { ProgressView().controlSize(.small); Text("Loading endpoints…").foregroundStyle(.secondary) }
            }
        }
    }

    /// One endpoint as a card: what it is, and the models it offers.
    ///
    /// Read-only by design — selection moved to the usages section above, so
    /// this answers "which servers do I have and what do they run" without
    /// competing for the same decision.
    @ViewBuilder
    private func endpointCard(_ endpoint: MemoryLlmEndpoint, config: MemoryLlmConfig) -> some View {
        let list = endpointModels[endpoint.name] ?? ModelList()
        // "In use" means some usage resolves here, which is what the badge is
        // for — the roles themselves are no longer edited on this screen.
        let usedBy = usages.filter { $0.endpoint == endpoint.name }

        CardContainer {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: usedBy.isEmpty ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(usedBy.isEmpty ? Color.secondary : Color.green)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(endpoint.name).fontWeight(.medium)
                                .lineLimit(1).truncationMode(.tail)
                            if endpoint.hasApiKey {
                                Image(systemName: "key.fill").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(endpoint.baseUrl)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if !usedBy.isEmpty {
                            Text("used by \(usedBy.map(\.label).joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    HStack(spacing: 6) {
                        if list.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { loadModels(for: endpoint) } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless).help("Reload models")
                        }
                        Button { editingEndpoint = endpoint } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("Edit endpoint")
                        Button(role: .destructive) {
                            Task { await remove(endpoint) }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Remove endpoint")
                    }
                    .fixedSize()
                    .layoutPriority(2)
                }
                .padding(12)
                Divider()
                modelList(list)
            }
        }
    }

    /// The models a provider offers. A plain list: picking one happens in the
    /// usages section above, so there is no selection state here.
    @ViewBuilder
    private func modelList(_ list: ModelList) -> some View {
        if let error = list.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .padding(12)
        } else if list.models.isEmpty {
            Text(list.loaded ? "No models offered by this endpoint." : "Loading models…")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        } else {
            VStack(spacing: 0) {
                ForEach(list.models) { model in
                    HStack(spacing: 8) {
                        Text(model.id).font(.callout)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let vendor = model.vendor {
                            Text(vendor).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    if model.id != list.models.last?.id { Divider() }
                }
            }
        }
    }

    // MARK: - Copilot section

    /// Whether Copilot needs authentication (never logged in, or a login failed).
    private var copilotNeedsAuth: Bool {
        if case .failed = copilotLogin?.state { return true }
        return config?.copilot?.authenticated != true
    }

    private var isPendingLogin: Bool {
        if case .pending = copilotLogin?.state { return true }
        return false
    }

    @ViewBuilder
    private var copilotSection: some View {
        let isActive = config?.copilotIsChatBackend == true
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("GitHub Copilot models") {
                if isActive { Badge(text: "Active", color: .green) }
                if copilotModels.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { loadCopilotModels() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Reload Copilot models")
                }
            }
            Text("Pick a model to use your GitHub Copilot subscription for memory extraction and dreaming — selecting one switches chat to Copilot. Embeddings are unaffected; Copilot serves chat only.")
                .font(.caption).foregroundStyle(.secondary)

            if copilotNeedsAuth || isPendingLogin {
                copilotLoginCard
            } else if let error = copilotModels.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if copilotModels.models.isEmpty {
                CardContainer {
                    Text(copilotModels.loaded ? "No Copilot models available." : "Loading models…")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            } else {
                CardContainer {
                    VStack(spacing: 0) {
                        ForEach(copilotModels.models) { model in
                            HStack(spacing: 8) {
                                Text(model.id).font(.callout)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if let vendor = model.vendor {
                                    Text(vendor).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            if model.id != copilotModels.models.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    /// The device-flow login card: a start button, then the code + verification
    /// URL while pending. The server polls GitHub and persists the token, so the
    /// UI only has to poll status.
    @ViewBuilder
    private var copilotLoginCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                switch copilotLogin?.state {
                case .pending:
                    Text("Sign in to GitHub").font(.callout.weight(.medium))
                    // The user has to type this code on GitHub, so make it big,
                    // monospaced and copyable rather than a caption.
                    HStack(spacing: 10) {
                        Text(copilotLogin?.userCode ?? "…")
                            .font(.title2.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        if let code = copilotLogin?.userCode {
                            CopyButton(text: { code }, help: "Copy the device code")
                        }
                    }
                    if let uri = copilotLogin?.verificationUri, let url = URL(string: uri) {
                        HStack(spacing: 8) {
                            Link("Open \(uri)", destination: url)
                                .font(.callout)
                            ProgressView().controlSize(.small)
                            Text("waiting for authorization…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .failed:
                    Label(copilotLogin?.error ?? "Login failed.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)
                    Button("Try Again") { Task { await startCopilotLogin() } }
                        .disabled(isStartingLogin)
                default:
                    Text("Not signed in to GitHub Copilot.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button {
                            Task { await startCopilotLogin() }
                        } label: {
                            Label("Sign in with GitHub", systemImage: "person.badge.key")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isStartingLogin)
                        if isStartingLogin { ProgressView().controlSize(.small) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    // MARK: - Pinned embedding warning

    @ViewBuilder
    private func pinnedSection(_ pinned: MemoryPinnedEmbedding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Embedding dimension")
            CardContainer {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pinned to \(pinned.model) · \(pinned.dimensions) dimensions")
                            .font(.callout.weight(.medium))
                        // The one setting here that can strand the store, so it
                        // gets an explicit warning rather than a failure at the
                        // next launch.
                        Text("The database was created with this embedding width. Switching to a model that emits a different width is rejected when memory next opens the store — existing vectors would not be comparable.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
            }
        }
    }

    // MARK: - Loading

    /// Load the usage bindings — the first section's data.
    private func loadUsages() {
        Task {
            if let list = try? await manager.makeClient().llmUsages() { usages = list }
        }
    }

    /// Persist one usage's binding. `nil` clears it back to inherit.
    private func bindUsage(_ usage: LlmUsage, to choice: LlmChoice?) async {
        isSavingUsage = true
        defer { isSavingUsage = false }
        do {
            let updated = try await manager.makeClient().setLlmUsage(
                usage.id, endpoint: choice?.endpoint, model: choice?.model
            )
            if let idx = usages.firstIndex(where: { $0.id == updated.id }) {
                usages[idx] = updated
            }
            // The endpoint cards show which usages point at them, so refresh
            // the config too.
            load(reloadModels: false)
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
    @State private var setActive: LlmRole?
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
                Picker("Use for", selection: $setActive) {
                    Text("Don't change").tag(LlmRole?.none)
                    ForEach(LlmRole.allCases) { role in
                        Text(role.label).tag(LlmRole?.some(role))
                    }
                }
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
                        apiKey: apiKey.isEmpty ? nil : apiKey,
                        setActive: setActive
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
