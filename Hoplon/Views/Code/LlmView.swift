import SwiftUI

/// LLM backend configuration for codesearch serve: manage the OpenAI-compatible
/// endpoints stored in the server's config (add/update, set active) and discover
/// the chat models each backend offers (OpenAI `/v1/models`, GitHub Copilot).
/// Model ids feed the per-request override on the Call Graph explain stream.
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
    /// Set while activating a specific (endpoint, model) so its row shows a spinner.
    @State private var settingModel: String?

    // The live active backend + pinned Copilot model, so the UI can show which
    // backend answers requests and reflect the selected Copilot model.
    @State private var activeTarget: LlmTargetResponse?
    /// Set while switching the backend to Copilot / pinning a Copilot model, so
    /// that row shows a spinner.
    @State private var settingCopilotModel: String?

    // GitHub Copilot device-flow login (driven by the management API).
    @State private var copilotLogin: CopilotLoginStatus?
    @State private var isStartingLogin = false
    @State private var loginPollTask: Task<Void, Never>?

    private var manager: CodesearchManager { state.codesearchManager }

    /// Whether an OpenAI endpoint is the live backend. An endpoint marked
    /// `active` in config is only the *actual* active provider when the backend
    /// target is also OpenAI — otherwise Copilot (say) is answering and the
    /// endpoint's "active" state is just which one we'd use if we switched back.
    /// Until the target has loaded, assume OpenAI (the server's default) so the
    /// UI doesn't flicker the active endpoint off on first paint.
    private var openaiIsActiveBackend: Bool {
        (activeTarget?.target ?? .openai) == .openai
    }

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
                openaiSection
                copilotSection
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
        }
        .onDisappear {
            endpointsTask?.cancel(); isLoadingEndpoints = false
            loginPollTask?.cancel()
        }
    }

    // MARK: - Endpoints

    // MARK: - OpenAI section (per-endpoint, with models + selection)

    @ViewBuilder
    private var openaiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("OpenAI-compatible endpoints") {
                if activeTarget?.target == .openai {
                    Badge(text: "Active", color: .green)
                }
                Button { showAddSheet = true } label: { Label("Add Endpoint", systemImage: "plus") }
                    .controlSize(.small)
            }
            Text("Each endpoint (LM Studio, vLLM, hosted OpenAI, …) is stored by the codesearch server. Pick a model per endpoint; the active endpoint's model answers query expansion and call-flow explanations. API keys are write-only.")
                .font(.caption).foregroundStyle(.secondary)

            if let endpointsError {
                Label(endpointsError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if let endpoints, endpoints.endpoints.isEmpty {
                CardContainer {
                    Text("No endpoints configured yet. Add one, or the server falls back to the OPENAI_* environment variables.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else if let endpoints {
                ForEach(endpoints.sortedEndpoints) { endpoint in
                    endpointCard(endpoint)
                }
            } else if isLoadingEndpoints {
                HStack { ProgressView().controlSize(.small); Text("Loading endpoints…").foregroundStyle(.secondary) }
            }
        }
    }

    /// One endpoint as a card: header (name + active badge + activate/edit) and
    /// its model list, where tapping a model selects it (and activates the
    /// endpoint) via a config write.
    @ViewBuilder
    private func endpointCard(_ endpoint: LlmEndpoint) -> some View {
        let list = endpointModels[endpoint.name] ?? ModelList()
        // "Active" here means the live provider — this endpoint is the chosen
        // OpenAI one AND OpenAI is the active backend. When Copilot is active,
        // no OpenAI endpoint reads as active.
        let isActive = endpoint.active && openaiIsActiveBackend
        CardContainer {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(endpoint.name).fontWeight(.medium)
                            if isActive { Badge(text: "Active", color: .green) }
                            if endpoint.hasKey {
                                Image(systemName: "key.fill").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(endpoint.baseUrl)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        // Make the current model explicit, since an endpoint can
                        // run with no pinned model (the server picks a default).
                        HStack(spacing: 4) {
                            Text("Model:").font(.caption2).foregroundStyle(.tertiary)
                            if let model = endpoint.model, !model.isEmpty {
                                Text(model).font(.caption2.monospaced()).foregroundStyle(.primary)
                            } else {
                                Text("none — server default").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Spacer()
                    if !isActive {
                        Button("Set Active") { Task { await activate(endpoint.name) } }
                            .controlSize(.small)
                            .help("Use this endpoint — switches the backend to OpenAI")
                    }
                    if list.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { loadModels(for: endpoint) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Reload models")
                    }
                    Button { editingEndpoint = endpoint } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("Edit endpoint")
                }
                .padding(12)
                Divider()
                // Models
                modelList(list, endpoint: endpoint, endpointIsActive: isActive)
            }
        }
    }

    @ViewBuilder
    private func modelList(_ list: ModelList, endpoint: LlmEndpoint, endpointIsActive: Bool) -> some View {
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
                    // Only the live-active OpenAI endpoint shows a selected model;
                    // otherwise the radios read as unselected (Copilot is active,
                    // or this isn't the chosen endpoint).
                    let isSelected = endpointIsActive && endpoint.model == model.id
                    Button {
                        Task { await selectModel(model.id, for: endpoint) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            Text(model.label).font(.callout)
                            Spacer()
                            if settingModel == "\(endpoint.name)/\(model.id)" {
                                ProgressView().controlSize(.small)
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

    @ViewBuilder
    private var copilotSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("GitHub Copilot models") {
                if activeTarget?.target == .copilot {
                    Badge(text: "Active", color: .green)
                }
                if copilotModels.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { loadCopilotModels() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Reload Copilot models")
                }
            }
            Text("Pick a model to use GitHub Copilot as the active backend — selecting one switches the server to Copilot and answers query expansion and call-flow explanations. The choice persists across restarts.")
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
                            // Selected when Copilot is the active backend AND this
                            // is the pinned model (or, if none is pinned, the row
                            // is just selectable — tapping pins it and activates).
                            let isSelected = activeTarget?.target == .copilot
                                && activeTarget?.copilotModel == model.id
                            Button {
                                Task { await selectCopilotModel(model.id) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    Text(model.label).font(.callout)
                                    Spacer()
                                    if settingCopilotModel == model.id {
                                        ProgressView().controlSize(.small)
                                    } else if model.name != nil {
                                        Text(model.id).font(.caption.monospaced())
                                            .foregroundStyle(.secondary).textSelection(.enabled)
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

    /// True while a device-flow login is pending (waiting on the browser step).
    private var isPendingLogin: Bool {
        if case .pending = copilotLogin?.state { return true }
        return isStartingLogin
    }

    /// The sign-in card: a "Sign in" button, or the device code + a link to the
    /// verification page while pending, or the failure reason.
    @ViewBuilder
    private var copilotLoginCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                if let login = copilotLogin, login.state == .pending, let code = login.userCode {
                    Text("Sign in to GitHub Copilot").font(.callout.weight(.medium))
                    Text("1. Open the page below.  2. Enter this code:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Text(code)
                            .font(.title3.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy code")
                        if let uri = login.verificationUri, let url = URL(string: uri) {
                            Link(destination: url) { Label("Open GitHub", systemImage: "arrow.up.right.square") }
                        }
                    }
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for authorization…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    if case .failed = copilotLogin?.state, let err = copilotLogin?.error {
                        Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("GitHub Copilot isn't connected yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await startCopilotLogin() }
                    } label: {
                        Label("Sign in to GitHub Copilot", systemImage: "person.badge.key")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isStartingLogin)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
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
                    await selectModel(first.id, for: endpoint, activate: false)
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

    /// Select a model for an endpoint — writes it through the config API, then
    /// refreshes. `activate` also makes the endpoint active: `true` for a user
    /// tap (pick a model → use it), `false` for auto-pinning a default (which
    /// shouldn't change which endpoint is active).
    private func selectModel(_ modelID: String, for endpoint: LlmEndpoint, activate: Bool = true) async {
        settingModel = "\(endpoint.name)/\(modelID)"
        defer { settingModel = nil }
        do {
            let response = try await manager.makeClient().upsertLlmEndpoint(
                name: endpoint.name,
                LlmUpsertEndpointRequest(baseUrl: endpoint.baseUrl, model: modelID, apiKey: nil,
                                         setActive: activate || endpoint.active)
            )
            await MainActor.run { endpoints = response }
            // A user tap picks this model to *use*, so the backend must be
            // OpenAI too — otherwise Copilot could stay active while the UI
            // shows a freshly-picked OpenAI model. Auto-pin (activate=false)
            // never changes the backend.
            if activate { await setBackend(.openai) }
        } catch {
            await MainActor.run {
                endpointsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func activate(_ name: String) async {
        do {
            let response = try await manager.makeClient().setActiveLlmEndpoint(name: name)
            await MainActor.run {
                endpoints = response
                // Activating an OpenAI endpoint also makes OpenAI the backend, so
                // switch the target too — otherwise the server could stay on
                // Copilot while the UI shows a freshly-activated OpenAI endpoint.
                Task { await setBackend(.openai) }
            }
        } catch {
            await MainActor.run {
                endpointsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Load which backend is live and which Copilot model is pinned.
    private func loadTarget() {
        let client = manager.makeClient()
        Task {
            if let target = try? await client.llmTarget() {
                await MainActor.run { activeTarget = target }
            }
        }
    }

    /// Switch the active backend (no model change). Used when activating an
    /// OpenAI endpoint so the backend follows the selection.
    private func setBackend(_ backend: LlmBackend) async {
        guard activeTarget?.target != backend else { return }
        if let updated = try? await manager.makeClient().setLlmTarget(backend) {
            await MainActor.run { activeTarget = updated }
        }
    }

    /// Pick a Copilot model: pin it and switch the active backend to Copilot in
    /// one gesture (mirroring how tapping an OpenAI model activates its endpoint).
    private func selectCopilotModel(_ modelID: String) async {
        await MainActor.run { settingCopilotModel = modelID }
        defer { Task { @MainActor in settingCopilotModel = nil } }
        do {
            let client = manager.makeClient()
            // Pin the model, then make Copilot the active backend. The second
            // call returns the authoritative target we render from.
            _ = try await client.setCopilotModel(modelID)
            let updated = try await client.setLlmTarget(.copilot)
            await MainActor.run { activeTarget = updated }
        } catch {
            await MainActor.run {
                copilotModels.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Shared save path for add + edit. Returns whether the save succeeded so
    /// the sheet stays open on failure (letting the user correct/retry) and only
    /// dismisses once the endpoint is persisted. Errors surface on the page.
    private func save(name: String, request: LlmUpsertEndpointRequest) async -> Bool {
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
    @State private var setActive: Bool
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
        _setActive = State(initialValue: existing?.active ?? false)
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
                Toggle("Set as active endpoint", isOn: $setActive)
                    .disabled(existing?.active == true)
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
        .frame(width: 420)
    }
}
