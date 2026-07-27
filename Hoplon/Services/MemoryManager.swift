import Foundation
import Observation

/// Launches and supervises the bundled `memory-rs` binary in `serve` mode.
///
/// Unlike the other two services, `memory-rs serve` needs only ONE port: it
/// serves the REST management API and mounts the MCP streamable-HTTP endpoint
/// at `/mcp` on the same listener. Mirrors `GuardrailsManager` otherwise —
/// process-group supervision plus periodic polling of `/health`, `/api/stats`
/// and `/api/namespaces`.
///
/// The per-action API surface used by the views lives in `MemoryClient`,
/// constructed on demand from `apiBase`. This type stays focused on lifecycle
/// and liveness/rollup polling.
@Observable
@MainActor
class MemoryManager {
    var isRunning = false
    var isStarting = false
    var lastError: String?

    /// Whether the server answered the most recent `/health` probe.
    var isReachable = false
    var health: MemoryHealth?
    var stats: MemoryStats?
    var namespaces: [MemoryNamespace] = []

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
    var port: Int
    var publicBind: Bool

    /// Poll cadence, matching the other managers.
    private let pollInterval: Duration = .seconds(5)
    /// Extra grace on the first probes: `serve` opens DuckDB and may initialise
    /// an embedding model before `/health` answers.
    private let firstProbeRetries = 6

    init(port: Int = 8766, publicBind: Bool = false) {
        self.port = port
        self.publicBind = publicBind
        self.browse = MemoryBrowseManager(clientProvider: { [weak self] in
            MemoryClient(base: self?.apiBase ?? "http://127.0.0.1:\(port)")
        })
        self.sessionImport = SessionImportManager(clientProvider: { [weak self] in
            MemoryClient(base: self?.apiBase ?? "http://127.0.0.1:\(port)")
        })
    }

    /// Base URL of the REST/JSON management API.
    var apiBase: String { "http://127.0.0.1:\(port)" }
    /// The MCP endpoint agents point at — same port, `/mcp` path.
    var mcpEndpoint: String { "http://127.0.0.1:\(port)/mcp" }

    /// A client for per-user-action calls (browse, search, import, namespaces…).
    func makeClient() -> MemoryClient { MemoryClient(base: apiBase) }

    /// App-scoped memory-browser state (the built tree + stats), cached so
    /// leaving and returning to the Browse screen doesn't reload, and so a
    /// status-poll re-render can't wipe an in-flight load.
    @ObservationIgnored private(set) var browse: MemoryBrowseManager!

    /// App-scoped import state, so an in-flight import keeps running after the
    /// user leaves the Import screen.
    @ObservationIgnored private(set) var sessionImport: SessionImportManager!

    // MARK: - Lifecycle

    func startBundled() {
        guard !isRunning && !isStarting else {
            print("⚠️ memory-rs already running or starting - ignoring start request")
            return
        }
        // Re-entrancy guard set synchronously on the main actor: a deferred flag
        // would let a second start slip through in the same runloop tick and
        // spawn a duplicate that fails to bind and flaps the service to stopped.
        isStarting = true
        lastError = nil
        intentionalStop = false

        guard let resourcePath = Bundle.main.resourcePath else {
            isStarting = false
            setError("Could not locate app bundle resources.")
            return
        }

        let binaryPath = (resourcePath as NSString).appendingPathComponent("memory-rs")
        let fileManager = FileManager.default

        guard fileManager.isExecutableFile(atPath: binaryPath) else {
            isStarting = false
            setError("Bundled memory-rs binary not found at: \(binaryPath)\n\nRebuild the app after running scripts/fetch_binaries.sh")
            return
        }

        print("🔄 Starting memory-rs serve (bundled binary)")
        print("📦 Binary: \(binaryPath)")

        let logURL = logFileURL()
        prepareLogFile(at: logURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        var args = ["serve", "--port", "\(port)"]
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
            print("✓ memory-rs serve launched (API \(apiBase), MCP \(mcpEndpoint))")
            markRunning()
        } catch {
            isStarting = false
            lastError = error.localizedDescription
            print("❌ Failed to start memory-rs: \(error)")
        }
    }

    func stop() {
        // Mark this as a deliberate stop so the process-exit watcher doesn't
        // report it as an unexpected crash (it races the cancel below).
        intentionalStop = true
        pollTask?.cancel()
        pollTask = nil
        browse.reset()
        sessionImport.reset()
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
        namespaces = []
    }

    // MARK: - Polling

    /// Fetch `/health`, `/api/stats` and `/api/namespaces` once.
    func refresh() {
        Task { await refreshOnce() }
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
        if let ns = try? await client.namespaces() { namespaces = ns }
    }

    // MARK: - Private

    private func markRunning() {
        isStarting = false
        isRunning = true
        if let pid = process?.processIdentifier { watchProcess(pid) }
        // The process may have died before we got here (port in use, DuckDB lock
        // held by another instance, …). Surface the real reason from the log.
        if let proc = process, !proc.isRunning {
            print("⚠️ memory-rs exited immediately after launch")
            let reason = lastServeLogError()
            markStopped()
            lastError = reason
                ?? "memory-rs serve exited on startup. Check that port \(port) is free and no other instance is running."
            return
        }
        print("✅ Memory is ready (API \(apiBase))")
        startPolling()
    }

    private func markStopped() {
        pollTask?.cancel()
        pollTask = nil
        browse.reset()
        sessionImport.reset()
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
        namespaces = []
    }

    /// A single async loop that probes on first launch (with a short backoff so
    /// a slow first boot doesn't flash "unreachable"), then polls every
    /// `pollInterval` until cancelled.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<self.firstProbeRetries {
                if Task.isCancelled { return }
                await self.refreshOnce()
                if self.isReachable { break }
                let delay = Duration.milliseconds(500 * (attempt + 1))
                try? await Task.sleep(for: delay)
            }
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
                let reason = self.lastServeLogError()
                self.markStopped()
                self.lastError = reason ?? "Memory stopped unexpectedly. See ~/.memory-rs/memory-serve.log."
            }
        }
        source.resume()
        processSource = source
    }

    /// Extract a human-readable failure reason from the tail of the serve log,
    /// or nil if nothing recognizable is there. The DuckDB lock conflict is by
    /// far the most common startup failure — memory-rs keeps its own
    /// single-writer database, so a stray CLI or TUI holds it exclusively.
    private func lastServeLogError() -> String? {
        guard let data = try? Data(contentsOf: logFileURL()),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let tail = text.split(separator: "\n").suffix(20)
        for line in tail.reversed() {
            if line.contains("Conflicting lock") || line.contains("Could not set lock") {
                return "Memory couldn't start: another process is using its database "
                    + "(~/.memory-rs/memory.duckdb). Quit any other memory-rs instance "
                    + "(the CLI or TUI, or a second copy of this app), then Start again."
            }
            if line.localizedCaseInsensitiveContains("address already in use")
                || line.localizedCaseInsensitiveContains("failed to bind") {
                return "Memory couldn't start: port \(port) is already in use."
            }
            if line.hasPrefix("Error:") {
                return "Memory stopped: \(line.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces))"
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
            .appendingPathComponent(".memory-rs/memory-serve.log")
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
