import Foundation
import Observation

/// Launches and supervises the bundled `guardrail` proxy binary
/// (https://github.com/ArtemisMucaj/guardrails) and polls its admin server
/// for liveness and metrics. Mirrors `ProxyManager` but adds the admin
/// `/stats`, `/info`, and `/healthz` polling that powers the Stats screen.
@Observable
class GuardrailsManager {
    var isRunning = false
    var isStarting = false
    var lastError: String?

    /// Whether the admin server answered the most recent /healthz probe.
    var isReachable = false
    var stats: GuardrailsStats?
    var info: GuardrailsInfo?

    /// One rollup sample per stats poll, powering the session sparklines.
    struct Sample: Identifiable {
        let index: Int
        let requests: Int
        let errors: Int
        var id: Int { index }
    }
    /// Rolling session history (one point per 5s poll, capped at `historyCap`).
    var history: [Sample] = []
    private let historyCap = 120
    @ObservationIgnored private var sampleIndex = 0

    private var process: Process?
    private var processSource: DispatchSourceProcess?
    /// One shared handle for the child's stdout+stderr — separate handles on
    /// the same file get independent offsets and overwrite each other.
    @ObservationIgnored private var processLogHandle: FileHandle?
    private var pollTimer: Timer?

    // Configuration (owned/persisted by AppState, pushed down here).
    var listenPort: Int
    var adminPort: Int
    var backend: String

    init(listenPort: Int = 8080, adminPort: Int = 8081, backend: String = "http://127.0.0.1:1234") {
        self.listenPort = listenPort
        self.adminPort = adminPort
        self.backend = backend
    }

    /// The OpenAI-compatible endpoint clients point at instead of the backend.
    var proxyEndpoint: String { "http://127.0.0.1:\(listenPort)/v1" }
    var adminBase: String { "http://127.0.0.1:\(adminPort)" }

    // MARK: - Lifecycle

    func startBundled() {
        guard !isRunning && !isStarting else {
            print("⚠️ Guardrails already running or starting - ignoring start request")
            return
        }
        // Set the re-entrancy guard synchronously: callers run on the main
        // thread, and a deferred (async) flag would let a second start slip
        // past this guard within the same runloop tick, spawning a duplicate
        // process. startBundled() must only ever be called on the main thread.
        isStarting = true
        lastError = nil

        guard listenPort != adminPort else {
            isStarting = false
            setError("Guardrails listen port and admin port must differ (both are \(listenPort)).")
            return
        }

        guard !backend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isStarting = false
            setError("Guardrails backend URL is empty. Set it in Settings (e.g. http://127.0.0.1:1234).")
            return
        }

        guard let resourcePath = Bundle.main.resourcePath else {
            isStarting = false
            setError("Could not locate app bundle resources.")
            return
        }

        let binaryPath = (resourcePath as NSString).appendingPathComponent("guardrail")
        let fileManager = FileManager.default

        guard fileManager.isExecutableFile(atPath: binaryPath) else {
            isStarting = false
            setError("Bundled guardrail binary not found at: \(binaryPath)\n\nRebuild the app after running scripts/download_guardrails_binary.sh")
            return
        }

        print("🔄 Starting guardrails (bundled binary)")
        print("📦 Binary: \(binaryPath)")

        let logURL = logFileURL()
        prepareLogFile(at: logURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = [
            "--listen", "127.0.0.1:\(listenPort)",
            "--admin-listen", "127.0.0.1:\(adminPort)",
            "--backend", backend,
        ]
        proc.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser
        proc.environment = ProxyManager.shellEnvironment
        processLogHandle = logHandle(for: logURL)
        proc.standardOutput = processLogHandle
        proc.standardError  = processLogHandle

        do {
            try proc.run()
            process = proc
            print("✓ Guardrails proxy launched on \(proxyEndpoint), admin on \(adminBase)")
            DispatchQueue.main.async { self.markRunning() }
        } catch {
            DispatchQueue.main.async {
                self.isStarting = false
                self.lastError = error.localizedDescription
            }
            print("❌ Failed to start guardrails: \(error)")
        }
    }

    func stop() {
        stopPolling()
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
        // Drop metrics from the previous run so a restart (e.g. new backend
        // or port) never shows stale numbers.
        stats = nil
        info = nil
        history.removeAll()
        sampleIndex = 0
    }

    // MARK: - Admin polling

    /// Fetch /healthz, /info, and /stats from the admin server once.
    func refresh() {
        fetchHealth()
        fetchInfo()
        fetchStats()
    }

    private func fetchHealth() {
        guard let url = URL(string: "\(adminBase)/healthz") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                if self.isReachable != ok { self.isReachable = ok }
            }
        }.resume()
    }

    private func fetchInfo() {
        guard let url = URL(string: "\(adminBase)/info") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data, let info = GuardrailsInfo(data: data) else { return }
            DispatchQueue.main.async {
                if self.info != info { self.info = info }
            }
        }.resume()
    }

    private func fetchStats() {
        guard let url = URL(string: "\(adminBase)/stats") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                print("📊 Guardrails stats fetch failed: \(error.localizedDescription)")
                return
            }
            guard let data,
                  let parsed = try? JSONDecoder().decode(GuardrailsStats.self, from: data)
            else {
                print("📊 Guardrails stats: unexpected response")
                return
            }
            DispatchQueue.main.async {
                if self.stats != parsed { self.stats = parsed }
                self.appendSample(from: parsed)
            }
        }.resume()
    }

    /// Record one rollup point for the session sparklines.
    private func appendSample(from stats: GuardrailsStats) {
        sampleIndex += 1
        history.append(Sample(index: sampleIndex, requests: stats.totalRequests, errors: stats.totalErrors))
        if history.count > historyCap { history.removeFirst(history.count - historyCap) }
    }

    // MARK: - Private

    private func markRunning() {
        isStarting = false
        isRunning = true
        if let pid = process?.processIdentifier { watchProcess(pid) }
        // The exit watcher is installed above, but the process may already
        // have died before we got here (e.g. a port was in use). Reconcile so
        // status doesn't stay stuck on "running" with the exit event missed.
        if let proc = process, !proc.isRunning {
            print("⚠️ Guardrails exited immediately after launch")
            markStopped()
            lastError = "Guardrails exited on startup. Check that ports \(listenPort)/\(adminPort) are free and the backend URL is valid."
            return
        }
        // Give the admin socket a moment to bind, then begin polling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isRunning else { return }
            self.refresh()
            self.startPolling()
        }
        print("✅ Guardrails is ready (proxy \(proxyEndpoint))")
    }

    private func markStopped() {
        stopPolling()
        process = nil
        processLogHandle?.closeFile()
        processLogHandle = nil
        isRunning = false
        isStarting = false
        isReachable = false
        processSource?.cancel()
        processSource = nil
        stats = nil
        info = nil
        history.removeAll()
        sampleIndex = 0
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func watchProcess(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.markStopped() }
        }
        source.resume()
        processSource = source
    }

    private func setError(_ msg: String) {
        DispatchQueue.main.async {
            self.isStarting = false
            self.lastError = msg
        }
        print("❌ \(msg)")
    }

    private func logFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".guardrails/guardrails.log")
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
