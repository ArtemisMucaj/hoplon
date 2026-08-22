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
    /// Per-day totals behind the contribution graph. Always fetched over the
    /// full window (`graphDays`), never the selected period — the graph is how
    /// a period is *chosen*, so narrowing it to the current selection would
    /// leave nothing else to click.
    var activity: [DayActivity] = []

    /// The window every figure on the screen is computed over.
    ///
    /// Owned by the manager rather than the view: the 5s poll re-renders the
    /// detail column, and view-owned state gets wiped by it.
    var period: GuardrailsPeriod = .last30Days {
        didSet {
            guard period != oldValue else { return }
            // Any /stats still in flight describes the previous window; drop it
            // rather than letting it land on top of the new one.
            generation += 1
            // The rollup is window-scoped, so it must be refetched; the graph
            // spans the whole history and does not move.
            if isRunning { fetchStats() }
        }
    }

    /// Days the contribution graph spans — a full year, as a contribution
    /// calendar conventionally shows. Well under the server's 1100-day cap.
    let graphDays = 371

    /// Bumped whenever an in-flight metrics response becomes obsolete — the
    /// proxy stopped, or the period changed.
    ///
    /// `URLSession` completions arrive in whatever order the responses do, so
    /// without this a slow `/stats` for the previous period can land after the
    /// new one and repaint the screen with figures for a window the user is no
    /// longer looking at. A response whose captured generation is stale is
    /// dropped rather than applied.
    @ObservationIgnored private var generation = 0

    /// Providers and Copilot login, driving the Guardrails settings pane.
    let providers = GuardrailsProvidersManager()

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
    /// Proxy GitHub Copilot models (`--copilot`).
    var copilot: Bool

    init(
        listenPort: Int = 8080,
        adminPort: Int = 8081,
        backend: String = "http://127.0.0.1:1234",
        copilot: Bool = false
    ) {
        self.listenPort = listenPort
        self.adminPort = adminPort
        self.backend = backend
        self.copilot = copilot
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

        // Only a first run needs a seed: after that config.json supplies the
        // providers and an empty field is the normal state, not an error.
        if backend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !Self.configExists() {
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
        proc.arguments = launchArguments()
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

    /// The proxy's command line.
    ///
    /// The backend flags are a **seed**, not the source of truth: guardrails
    /// writes `~/.guardrails/config.json` on first run and that file then wins
    /// over whatever flags the launcher passes, so these only shape a fresh
    /// install. Providers are changed afterwards through the management API
    /// (Settings ▸ Guardrails ▸ Providers), which applies to the live registry
    /// and persists in one call — no restart, and no risk of the flags and the
    /// running proxy disagreeing.
    ///
    /// `--copilot` is the exception that must stay a flag: Copilot needs an
    /// OAuth credential and GitHub's client-identity headers, which no
    /// `--backend URL` can express, so the process has to start knowing about it.
    func launchArguments() -> [String] {
        var args = [
            "--listen", "127.0.0.1:\(listenPort)",
            "--admin-listen", "127.0.0.1:\(adminPort)",
        ]
        // Repeated rather than comma-joined: a URL may contain a comma (a query
        // parameter), and the flag's env-var form is the only place upstream
        // splits on one.
        // The seed is only meaningful on a first run. Once config.json exists
        // it wins over every flag, so passing one is at best noise in the argv
        // and at worst a stale provider the user cannot see in the pane that
        // claims to manage them.
        if !Self.configExists() {
            for spec in Self.backendSpecs(backend) {
                args.append(contentsOf: ["--backend", spec])
            }
        }
        // `--copilot` *adds* a Copilot provider; it is not a request to ensure
        // one exists. Passing it when config.json already lists `copilot`
        // registers a second, identical entry — which is what put Copilot in
        // the provider list twice. Once the proxy has written its own config,
        // that file is the source of truth and the flag has nothing to add.
        if copilot && !Self.configHasCopilot() { args.append("--copilot") }
        // Always on. Chat Completions is stateless, so without it every turn's
        // resent transcript is counted again and the token totals describe the
        // sum of the turns rather than the conversation — which is simply the
        // wrong number, not a cheaper approximation of the right one. It is not
        // offered as a choice because there is no case for the other value.
        args.append("--match-conversations")
        return args
    }

    /// Whether the proxy has written its own configuration yet.
    static func configExists() -> Bool {
        FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".guardrails/config.json").path
        )
    }

    /// Whether the proxy's own configuration already lists a Copilot provider.
    ///
    /// Read from disk rather than from the last `/providers` response: this is
    /// needed while building the command line, before the admin server exists.
    static func configHasCopilot() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".guardrails/config.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [[String: Any]]
        else { return false }
        return providers.contains { $0["name"] as? String == "copilot" }
    }

    /// Split the configured backend setting into one spec per provider.
    ///
    /// Accepts a single URL (the common case, which upstream names `default`),
    /// or several `NAME=URL` entries **one per line**. Blank lines are dropped
    /// so a trailing newline is not an error.
    ///
    /// Newline is the only separator on purpose. A comma is not safe: it is a
    /// legal character in a URL query (`?ids=a,b`), so splitting on it would
    /// tear one backend into two invalid ones. Upstream does accept a
    /// comma-separated list, but only in the environment-variable form, where
    /// there is no alternative — a flag repeated per provider has no such
    /// constraint, and that is what this builds.
    ///
    /// Note that only the *first* backend may be anonymous upstream; the rest
    /// must be named, so their metrics can be told apart. A user who writes two
    /// bare URLs gets that error from the proxy, which states it better than a
    /// guess here would.
    static func backendSpecs(_ setting: String) -> [String] {
        let specs = setting
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // A spec must carry a URL, so anything without a scheme is dropped
            // rather than passed through. A stray word left in the field —
            // `--backend pr` — is not a backend the proxy can reach, and
            // forwarding it puts a broken provider in the registry on a first
            // run and noise in the argv on every other.
            .filter { spec in
                let url = spec.contains("=") ? String(spec.split(separator: "=", maxSplits: 1)[1]) : spec
                return url.hasPrefix("http://") || url.hasPrefix("https://")
            }
        // Empty means "say nothing": once config.json exists the seed is unused,
        // and passing `--backend ""` made the proxy register a nameless empty
        // provider rather than falling through to its own configuration.
        return specs
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
        // Any metrics request still in flight belongs to the run that just
        // ended; bumping the generation makes its completion a no-op instead of
        // repopulating a screen this is clearing.
        generation += 1
        stats = nil
        info = nil
        activity.removeAll()
        providers.reset()
        history.removeAll()
        sampleIndex = 0
    }

    // MARK: - Admin polling

    /// Fetch /healthz, /info, /stats and /activity from the admin server once.
    func refresh() {
        fetchHealth()
        fetchInfo()
        fetchStats()
        fetchActivity()
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

    /// Per-day totals for the contribution graph.
    ///
    /// Deliberately unbounded by `period`: the graph is the control a period is
    /// picked *with*, so scoping it to the current selection would collapse it
    /// to the days already chosen.
    private func fetchActivity() {
        guard let url = URL(string: "\(adminBase)/activity?days=\(graphDays)") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let issued = generation
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            if error != nil { return }
            guard let data,
                  let parsed = try? JSONDecoder().decode(GuardrailsActivity.self, from: data)
            else { return }
            DispatchQueue.main.async {
                // Stale: the proxy stopped, or was restarted, while this was in
                // flight. Applying it would repopulate a screen that has been
                // deliberately cleared.
                guard issued == self.generation else { return }
                if self.activity != parsed.days { self.activity = parsed.days }
            }
        }.resume()
    }

    private func fetchStats() {
        guard let url = URL(string: "\(adminBase)/stats\(period.query)") else { return }
        let issued = generation
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
                // Stale: the period changed or the proxy stopped while this was
                // in flight, so these figures describe a window nobody is
                // looking at — and appending a sample would skew the sparkline.
                guard issued == self.generation else { return }
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
        // Any metrics request still in flight belongs to the run that just
        // ended; bumping the generation makes its completion a no-op instead of
        // repopulating a screen this is clearing.
        generation += 1
        stats = nil
        info = nil
        activity.removeAll()
        providers.reset()
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
