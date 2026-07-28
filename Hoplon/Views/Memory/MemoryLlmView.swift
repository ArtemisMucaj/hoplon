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

    /// Which slot a tapped model fills, per endpoint. Chat by default.
    @State private var modelSlot: [String: LlmRole] = [:]
    /// Set while writing a model choice, so that row shows a spinner.
    @State private var settingModel: String?
    /// Set while binding a role, so that button shows a spinner.
    @State private var settingRole: String?

    @State private var editingEndpoint: MemoryLlmEndpoint?
    @State private var showAddSheet = false

    // GitHub Copilot: model list, device-flow login, and its poll task.
    @State private var copilotModels = ModelList()
    @State private var copilotLogin: CopilotLoginStatus?
    @State private var isStartingLogin = false
    @State private var settingCopilotModel: String?
    @State private var loginPollTask: Task<Void, Never>?

    private var manager: MemoryManager { state.memoryManager }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                rolesSection
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
        }
        .onDisappear { loginPollTask?.cancel() }
    }

    // MARK: - Active roles

    /// What actually answers each kind of request, up front.
    ///
    /// Chat and embeddings resolve independently and it matters: Copilot serves
    /// chat but has no embeddings endpoint, and memory-rs has no in-process
    /// embedding backend — so a store whose embedding role points nowhere
    /// reachable can't recall anything. Showing both bindings (and what they
    /// fall back to) makes that visible instead of hiding it in a per-card menu.
    @ViewBuilder
    private var rolesSection: some View {
        if let config {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Active endpoints")
                CardContainer {
                    VStack(spacing: 0) {
                        roleRow(.chat, config: config)
                        Divider()
                        roleRow(.embedding, config: config)
                        Divider()
                        roleRow(.shared, config: config)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func roleRow(_ role: LlmRole, config: MemoryLlmConfig) -> some View {
        let resolved = config.resolved(role)
        let explicit = config.isExplicit(role)
        let model = resolvedModel(role, config: config)

        HStack(spacing: 10) {
            Image(systemName: roleIcon(role))
                .foregroundStyle(resolved == nil ? Color.secondary : Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(role.label).font(.callout.weight(.medium))
                Text(role.help).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                if let resolved {
                    HStack(spacing: 5) {
                        Text(resolved).font(.callout)
                            .lineLimit(1).truncationMode(.middle)
                        // An inherited binding is shown but marked, so it can't
                        // be mistaken for a deliberate per-role choice.
                        if !explicit, role != .shared {
                            Badge(text: "inherited", color: .secondary)
                        }
                    }
                    if let model {
                        Text(model).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    Text(role == .shared ? "none" : "OPENAI_* environment")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 240, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func roleIcon(_ role: LlmRole) -> String {
        switch role {
        case .shared:    return "circle.dashed"
        case .chat:      return "text.bubble"
        case .embedding: return "point.3.filled.connected.trianglepath.dotted"
        }
    }

    /// The model a role will actually use, following the same resolution the
    /// server does (role override → shared default → that endpoint's model).
    private func resolvedModel(_ role: LlmRole, config: MemoryLlmConfig) -> String? {
        guard let name = config.resolved(role) else { return nil }
        if name == MemoryLlmConfig.copilotEndpointName {
            return config.copilot?.model ?? "Copilot default"
        }
        guard let endpoint = config.endpoints.first(where: { $0.name == name }) else { return nil }
        return role == .embedding ? endpoint.embeddingModel : endpoint.model
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

    /// One endpoint as a card: header (name + role badges + bind/edit) and its
    /// model list, where tapping a model fills the selected slot.
    @ViewBuilder
    private func endpointCard(_ endpoint: MemoryLlmEndpoint, config: MemoryLlmConfig) -> some View {
        let list = endpointModels[endpoint.name] ?? ModelList()
        let slot = modelSlot[endpoint.name] ?? .chat
        let boundRoles = LlmRole.allCases.filter {
            config.isExplicit($0) && config.resolved($0) == endpoint.name
        }
        let isActive = !boundRoles.isEmpty

        CardContainer {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(endpoint.name).fontWeight(.medium)
                                .lineLimit(1).truncationMode(.tail)
                            ForEach(boundRoles) { role in
                                Badge(text: role.label, color: .green)
                            }
                            if endpoint.hasApiKey {
                                Image(systemName: "key.fill").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(endpoint.baseUrl)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        // One line each: model ids are long, and side by side
                        // they wrap character-by-character in a narrow sheet.
                        modelLabel("Chat", endpoint.model)
                        modelLabel("Embed", endpoint.embeddingModel)
                    }
                    // The text column is the flexible part — it truncates first,
                    // so the trailing controls keep their intrinsic size instead
                    // of squeezing the name onto two lines.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    HStack(spacing: 6) {
                        roleMenu(endpoint, config: config)
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

                // Which slot a tapped model fills. Memory has two; codesearch
                // has one, which is why that screen has no such switch.
                HStack(spacing: 8) {
                    Text("Set model for").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { slot },
                        set: { modelSlot[endpoint.name] = $0 }
                    )) {
                        Text("Chat").tag(LlmRole.chat)
                        Text("Embeddings").tag(LlmRole.embedding)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()

                modelList(list, endpoint: endpoint, slot: slot)
            }
        }
    }

    /// One "Chat: <model>" line. Fixed-width label so the two lines align, and
    /// the value truncates in the middle — model ids differ at both ends.
    @ViewBuilder
    private func modelLabel(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .leading)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.caption2.monospaced()).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text("server default")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Bind this endpoint to a role. A menu rather than one button per role:
    /// three labelled buttons in the header squeeze the name and URL onto extra
    /// lines in a sheet this narrow.
    @ViewBuilder
    private func roleMenu(_ endpoint: MemoryLlmEndpoint, config: MemoryLlmConfig) -> some View {
        if settingRole?.hasPrefix("\(endpoint.name)/") == true {
            ProgressView().controlSize(.small)
        } else {
            Menu {
                ForEach(LlmRole.allCases) { role in
                    let bound = config.isExplicit(role) && config.resolved(role) == endpoint.name
                    Button {
                        Task { await bind(role: role, name: bound ? nil : endpoint.name, on: endpoint) }
                    } label: {
                        // A tick marks what's already bound, and re-picking it
                        // unbinds — otherwise there's no way back to "inherit".
                        Label(role.label, systemImage: bound ? "checkmark" : "")
                    }
                }
            } label: {
                Label("Use for", systemImage: "arrow.triangle.branch")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Bind this endpoint to chat, embeddings, or as the shared default")
        }
    }

    @ViewBuilder
    private func modelList(_ list: ModelList, endpoint: MemoryLlmEndpoint, slot: LlmRole) -> some View {
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
                    let current = slot == .embedding ? endpoint.embeddingModel : endpoint.model
                    let isSelected = current == model.id
                    Button {
                        Task { await selectModel(model.id, for: endpoint, slot: slot) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            Text(model.id).font(.callout)
                            Spacer()
                            if settingModel == "\(endpoint.name)/\(slot.rawValue)/\(model.id)" {
                                ProgressView().controlSize(.small)
                            } else if let vendor = model.vendor {
                                Text(vendor).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
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
                            let isSelected = isActive && config?.copilot?.model == model.id
                            Button {
                                Task { await selectCopilotModel(model.id) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    Text(model.id).font(.callout)
                                    Spacer()
                                    if settingCopilotModel == model.id {
                                        ProgressView().controlSize(.small)
                                    } else if let vendor = model.vendor {
                                        Text(vendor).font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 12).padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
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
                    return
                case .failed, .idle:
                    return
                case .pending:
                    continue
                }
            }
        }
    }

    /// Pin a Copilot model and switch chat to Copilot, mirroring how selecting
    /// an OpenAI model activates its endpoint.
    private func selectCopilotModel(_ model: String) async {
        settingCopilotModel = model
        defer { settingCopilotModel = nil }
        do {
            let client = manager.makeClient()
            try await client.setCopilotModel(model)
            config = try await client.setLlmActive(
                name: MemoryLlmConfig.copilotEndpointName, role: .chat
            )
        } catch {
            configError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Actions

    /// Bind (or, with `name: nil`, clear) a role. `on` is the endpoint whose
    /// row shows the spinner — with `nil` there's no name to key it by.
    private func bind(role: LlmRole, name: String?, on endpoint: MemoryLlmEndpoint) async {
        settingRole = "\(endpoint.name)/\(role.rawValue)"
        defer { settingRole = nil }
        do {
            config = try await manager.makeClient().setLlmActive(name: name, role: role)
        } catch {
            configError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func selectModel(_ model: String, for endpoint: MemoryLlmEndpoint, slot: LlmRole) async {
        settingModel = "\(endpoint.name)/\(slot.rawValue)/\(model)"
        defer { settingModel = nil }
        do {
            // Send only the slot being changed; the server keeps the other and
            // the stored key (omitting `api_key` leaves it untouched).
            let request = MemoryLlmUpsertRequest(
                baseUrl: endpoint.baseUrl,
                model: slot == .chat ? model : endpoint.model,
                embeddingModel: slot == .embedding ? model : endpoint.embeddingModel,
                apiKey: nil,
                // Picking a model is also a statement of intent to use this
                // endpoint for that role, matching the codesearch screen where
                // selecting a model activates its endpoint.
                setActive: slot
            )
            config = try await manager.makeClient().upsertLlmEndpoint(name: endpoint.name, request)
        } catch {
            configError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

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
