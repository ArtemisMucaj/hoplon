import Foundation
import Observation

/// Launches and supervises the bundled `codesearch` binary in `serve` mode,
/// which runs BOTH an MCP HTTP server (`--mcp-port`) and a REST/JSON management
/// API (`--mgmt-port`). Mirrors `GuardrailsManager`: process-group supervision
/// plus periodic polling of the management API's `/health`, `/api/stats`, and
/// `/api/repositories` endpoints that power the Code Intelligence screens.
///
/// The management API surface used by the views (search, memory, indexing,
/// explain) lives in `CodesearchClient`, constructed on demand from `mgmtBase`.
/// This type stays focused on lifecycle + liveness/rollup polling.
@Observable
@MainActor
class CodesearchManager {
    var isRunning = false
    var isStarting = false
    var lastError: String?

    /// Whether the management server answered the most recent `/health` probe.
    var isReachable = false
    var health: CodesearchHealth?
    var stats: CodesearchStats?
    var repositories: [Repository] = []

    /// Progress of a UI-driven index run: the folder being indexed and the last
    /// stage the server reported. `nil` when nothing is indexing. Held here
    /// rather than in a view's `@State` because the 5s status poll re-renders
    /// the detail column and would wipe view-owned state mid-run.
    var indexingPath: String?
    var indexingStage: String?
    /// Error from the last index attempt, cleared when a new one starts.
    var indexError: String?

    private var process: Process?
    private var processSource: DispatchSourceProcess?
    /// Set while a user-initiated `stop()` is in flight, so the exit watcher
    /// distinguishes a deliberate stop from a crash and doesn't raise a spurious
    /// error.
    @ObservationIgnored private var intentionalStop = false
    private var pollTask: Task<Void, Never>?
    /// One shared handle for the child's stdout+stderr — separate handles on
    /// the same file get independent offsets and overwrite each other.
    @ObservationIgnored private var processLogHandle: FileHandle?

    // Configuration (owned/persisted by AppState, pushed down here).
    var mcpPort: Int
    var mgmtPort: Int
    var publicBind: Bool

    /// Base URL of a local OpenAI-compatible server (LM Studio / vLLM) to
    /// auto-register as the LLM endpoint on first reachable poll if codesearch
    /// has none configured. Mirrors the guardrails backend default.
    var llmAutodetectBase: String = "http://127.0.0.1:1234"
    /// Auto-detection runs at most once per process lifetime.
    @ObservationIgnored private var didAttemptLlmAutodetect = false

    /// Poll cadence for the management API, matching GuardrailsManager.
    private let pollInterval: Duration = .seconds(5)
    /// Extra grace on the first probes: `serve` may initialise an embedding
    /// model / DuckDB store before `/health` answers.
    private let firstProbeRetries = 6

    init(mcpPort: Int = 8677, mgmtPort: Int = 8676, publicBind: Bool = false) {
        self.mcpPort = mcpPort
        self.mgmtPort = mgmtPort
        self.publicBind = publicBind
        self.featureExplain = FeatureExplainManager(clientProvider: { [weak self] in
            CodesearchClient(base: self?.mgmtBase ?? "http://127.0.0.1:\(mgmtPort)")
        })
    }

    /// Base URL of the REST/JSON management API.
    var mgmtBase: String { "http://127.0.0.1:\(mgmtPort)" }
    /// The MCP endpoint clients point at (for "copy endpoint").
    var mcpEndpoint: String { "http://127.0.0.1:\(mcpPort)/mcp" }

    /// A client for per-user-action management calls (search, memory, indexing…).
    func makeClient() -> CodesearchClient { CodesearchClient(base: mgmtBase) }

    // Long-term memory moved to memory-rs, so the browse + session-import
    // sub-managers that used to live here are on `MemoryManager` now.

    /// App-scoped LLM feature-explanation state (streams + results by feature
    /// id), so an in-flight explanation keeps streaming after the user leaves
    /// the Overview tab.
    @ObservationIgnored private(set) var featureExplain: FeatureExplainManager!

    // MARK: - Lifecycle

    func startBundled() {
        guard !isRunning && !isStarting else {
            print("⚠️ Codesearch already running or starting - ignoring start request")
            return
        }
        // Re-entrancy guard set synchronously on the main actor (see the same
        // reasoning in GuardrailsManager): a deferred flag would let a second
        // start slip through in the same runloop tick.
        isStarting = true
        lastError = nil
        intentionalStop = false

        guard mcpPort != mgmtPort else {
            isStarting = false
            setError("Codesearch MCP port and management port must differ (both are \(mcpPort)).")
            return
        }

        guard let resourcePath = Bundle.main.resourcePath else {
            isStarting = false
            setError("Could not locate app bundle resources.")
            return
        }

        let binaryPath = (resourcePath as NSString).appendingPathComponent("codesearch")
        let fileManager = FileManager.default

        guard fileManager.isExecutableFile(atPath: binaryPath) else {
            isStarting = false
            setError("Bundled codesearch binary not found at: \(binaryPath)\n\nRebuild the app after running scripts/fetch_binaries.sh")
            return
        }

        print("🔄 Starting codesearch serve (bundled binary)")
        print("📦 Binary: \(binaryPath)")

        let logURL = logFileURL()
        prepareLogFile(at: logURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        var args = [
            "serve",
            "--mcp-port", "\(mcpPort)",
            "--mgmt-port", "\(mgmtPort)",
        ]
        if publicBind { args.append("--public") }
        proc.arguments = args
        proc.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser
        proc.environment = ProxyManager.shellEnvironment
        processLogHandle = logHandle(for: logURL)
        proc.standardOutput = processLogHandle
        proc.standardError  = processLogHandle

        do {
            try proc.run()
            process = proc
            print("✓ Codesearch serve launched (MCP \(mcpEndpoint), mgmt \(mgmtBase))")
            markRunning()
        } catch {
            isStarting = false
            lastError = error.localizedDescription
            print("❌ Failed to start codesearch: \(error)")
        }
    }

    func stop() {
        // Mark this as a deliberate stop so the process-exit watcher doesn't
        // report it as an unexpected crash (it races the cancel below).
        intentionalStop = true
        pollTask?.cancel()
        pollTask = nil
        featureExplain.reset()
        processSource?.cancel()
        processSource = nil
        if let proc = process, proc.isRunning {
            let pgid = proc.processIdentifier
            kill(-pgid, SIGTERM)
            proc.terminate()
        }
        process = nil
        processLogHandle?.closeFile()
        processLogHandle = nil
        isRunning = false
        isStarting = false
        isReachable = false
        health = nil
        stats = nil
        repositories = []
    }

    // MARK: - Polling

    /// Fetch `/health`, `/api/stats`, and `/api/repositories` once.
    func refresh() {
        Task { await refreshOnce() }
    }

    /// Index `folder` into `namespace`, creating the namespace first.
    ///
    /// Creation is a separate call because indexing alone would land the repo
    /// in whatever namespace the server was started with unless the request
    /// names one — and naming one the server has never seen is exactly the case
    /// `POST /api/namespaces` exists to set up. Creating an existing namespace
    /// is a no-op server-side, so this is safe to call for both.
    func index(folder: URL, into namespace: String) {
        guard indexingPath == nil else { return }   // one run at a time
        indexingPath = folder.path
        indexingStage = "starting"
        indexError = nil

        Task {
            defer {
                indexingPath = nil
                indexingStage = nil
            }
            let client = makeClient()
            do {
                try await client.createNamespace(namespace)
            } catch {
                indexError = "Couldn't create namespace “\(namespace)”: \(errorText(error))"
                return
            }

            let request = IndexStreamRequest(
                path: folder.path,
                name: nil,
                namespace: namespace
            )
            do {
                for try await event in client.indexStream(request) {
                    switch event {
                    case let .progress(stage, _):
                        indexingStage = stage
                    case .done:
                        refresh()   // new repo, new counts
                        return
                    case let .failed(message):
                        indexError = message
                        return
                    }
                }
                // The stream ended without a terminal frame: the server closed
                // the connection mid-run. Say so rather than reporting success.
                indexError = "Indexing ended without completing."
            } catch {
                indexError = errorText(error)
            }
        }
    }

    private func errorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func refreshOnce() async {
        let client = makeClient()
        // Health first — it gates isReachable.
        if let h = try? await client.health() {
            health = h
            if !isReachable { isReachable = true }
        } else {
            if isReachable { isReachable = false }
        }
        if let s = try? await client.stats() { stats = s }
        if let repos = try? await client.repositories() { repositories = repos }
        // Once reachable, wire up a local LLM (LM Studio/vLLM) if the user
        // hasn't configured one — so community names and call-flow explanations
        // work out of the box.
        if isReachable { await autodetectLlmEndpointIfNeeded(client: client) }
    }

    /// If codesearch has no LLM endpoint configured and a local OpenAI-compatible
    /// server is listening, register it and set it active. Runs at most once per
    /// process; failures are silent (the LLM tab still lets the user add one).
    private func autodetectLlmEndpointIfNeeded(client: CodesearchClient) async {
        guard !didAttemptLlmAutodetect else { return }
        didAttemptLlmAutodetect = true

        // Don't clobber an existing configuration.
        guard let existing = try? await client.llmEndpoints(), existing.endpoints.isEmpty else { return }

        // Is a local OpenAI-compatible server actually up?
        guard let models = await CodesearchClient.probeOpenAIModels(baseUrl: llmAutodetectBase),
              !models.isEmpty else { return }

        // codesearch appends `/v1/...` itself, so store the *bare* base — a
        // trailing `/v1` here produces `/v1/v1/models` and a parse failure.
        let base = normalizedLlmBase(llmAutodetectBase)
        let request = LlmUpsertEndpointRequest(
            baseUrl: base,
            model: models.first,
            apiKey: nil,
            setActive: true
        )
        _ = try? await client.upsertLlmEndpoint(name: "LM Studio", request)
        print("✓ Auto-registered local LLM endpoint at \(base) (\(models.count) model(s))")
    }

    /// codesearch expects the OpenAI base *without* a trailing `/v1` (it appends
    /// the version + route itself). Strip a trailing slash and `/v1` so a
    /// user- or probe-supplied `.../v1` doesn't become `/v1/v1/models`.
    private func normalizedLlmBase(_ raw: String) -> String {
        var s = raw
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1") { s.removeLast(3) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: - Private

    private func markRunning() {
        isStarting = false
        isRunning = true
        if let pid = process?.processIdentifier { watchProcess(pid) }
        // The process may have died before we got here (port in use, DuckDB lock
        // held by another instance, …). Surface the real reason from the log.
        if let proc = process, !proc.isRunning {
            print("⚠️ Codesearch exited immediately after launch")
            let reason = lastServeLogError()
            markStopped()
            lastError = reason
                ?? "codesearch serve exited on startup. Check that ports \(mcpPort)/\(mgmtPort) are free and no other instance is running."
            return
        }
        print("✅ Codesearch is ready (mgmt \(mgmtBase))")
        startPolling()
    }

    private func markStopped() {
        pollTask?.cancel()
        pollTask = nil
        featureExplain.reset()
        process = nil
        processLogHandle?.closeFile()
        processLogHandle = nil
        isRunning = false
        isStarting = false
        isReachable = false
        processSource?.cancel()
        processSource = nil
        health = nil
        stats = nil
        repositories = []
        // Re-probe for a local LLM the next time it comes up.
        didAttemptLlmAutodetect = false
    }

    /// A single async loop that probes on first launch (with a short backoff so
    /// a slow first boot doesn't flash "unreachable"), then polls every
    /// `pollInterval` until cancelled.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            // First-probe backoff: retry a few times before settling.
            for attempt in 0..<self.firstProbeRetries {
                if Task.isCancelled { return }
                await self.refreshOnce()
                if self.isReachable { break }
                let delay = Duration.milliseconds(500 * (attempt + 1))
                try? await Task.sleep(for: delay)
            }
            // Steady-state polling.
            while !Task.isCancelled {
                try? await Task.sleep(for: self.pollInterval)
                if Task.isCancelled { return }
                await self.refreshOnce()
            }
        }
    }

    private func watchProcess(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // A user-initiated stop already tore everything down — don't
                // report it as a crash.
                if self.intentionalStop { return }
                // An unexpected exit: surface the real reason from the serve log
                // so "it stopped itself" isn't a silent dead end. The most common
                // cause is another process holding the DuckDB lock (a stray CLI, a
                // second app instance, a crashed serve) — a single-writer database.
                let reason = self.lastServeLogError()
                self.markStopped()
                self.lastError = reason ?? "Code Intelligence stopped unexpectedly. See ~/.codesearch/codesearch-serve.log."
            }
        }
        source.resume()
        processSource = source
    }

    /// Extract a human-readable failure reason from the tail of the serve log,
    /// or nil if nothing recognizable is there. Maps the DuckDB lock conflict —
    /// by far the most common startup failure — to actionable guidance.
    private func lastServeLogError() -> String? {
        guard let data = try? Data(contentsOf: logFileURL()),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let tail = text.split(separator: "\n").suffix(20)
        for line in tail.reversed() {
            if line.contains("Conflicting lock") || line.contains("Could not set lock") {
                return "Code Intelligence couldn't start: another process is using its database "
                    + "(~/.codesearch/codesearch.duckdb). Quit any other codesearch instance "
                    + "(or a second copy of this app), then Start again."
            }
            if line.localizedCaseInsensitiveContains("address already in use")
                || line.localizedCaseInsensitiveContains("bind") {
                return "Code Intelligence couldn't start: port \(mcpPort) or \(mgmtPort) is already in use."
            }
            if line.hasPrefix("Error:") {
                return "Code Intelligence stopped: \(line.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces))"
            }
        }
        return nil
    }

    private func setError(_ msg: String) {
        isStarting = false
        lastError = msg
        print("❌ \(msg)")
    }

    private func logFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codesearch/codesearch-serve.log")
    }

    private func prepareLogFile(at url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.truncateFile(atOffset: 0)
            handle.closeFile()
        }
    }

    private func logHandle(for url: URL) -> FileHandle? {
        try? FileHandle(forWritingTo: url)
    }
}
