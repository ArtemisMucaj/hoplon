import Foundation
import Observation
import AppKit

struct DiscoveredTool: Identifiable, Codable {
    let name: String
    let description: String
    var id: String { name }
}

/// Top-level sections in the control-center sidebar. Each supervised service
/// gets first-class space; Proxy is the landing section.
enum AppSection: String, CaseIterable, Identifiable {
    case proxy
    case guardrails
    case memory
    case code

    var id: String { rawValue }

    var label: String {
        switch self {
        case .proxy:      return "Proxy"
        case .guardrails: return "Guardrails"
        case .memory:     return "Memory"
        case .code:       return "Code Intelligence"
        }
    }

    var systemImage: String {
        switch self {
        case .proxy:      return "point.3.connected.trianglepath.dotted"
        case .guardrails: return "shield.lefthalf.filled"
        case .memory:     return "brain"
        case .code:       return "curlybraces.square"
        }
    }

}

// MARK: - Private Codable helpers

private nonisolated struct ToolEntry: Codable {
    let name: String
    let description: String
}

/// Shape of ~/.panoply/presets.json (written by the proxy).
private nonisolated struct PresetsFile: Codable {
    var presets: [Preset]
    var activePresetID: String?
}

/// Shape returned by GET /api/presets.
private nonisolated struct PresetsResponse: Codable {
    let presets: [Preset]
    let activePresetID: String?
    let activeConfigPath: String?
}

/// Shape returned by POST /api/presets.
private nonisolated struct CreatePresetResponse: Codable {
    let preset: Preset
}

// MARK: - AppState

@Observable
@MainActor
final class AppState {
    /// Shared instance. The app delegate and the SwiftUI views resolve the same
    /// AppState through this, so service lifecycle (started from the delegate,
    /// window-independent) and the UI observe one source of truth.
    static let shared = AppState()

    var servers: [String: MCPServer] = [:]
    let proxyManager: ProxyManager
    let guardrailsManager: GuardrailsManager
    let memoryManager: MemoryManager
    let codesearchManager: CodesearchManager
    var discoveredTools: [String: [DiscoveredTool]] = [:]
    var isDiscoveringTools = false
    var presets: [Preset] = []
    var activePresetID: UUID?

    // MARK: - Proxy settings (persisted in UserDefaults)

    var port: Int {
        didSet {
            // Clamp to 1024...65534 so apiPort (port + 1) never exceeds 65535.
            let clamped = max(1024, min(65534, port))
            if port != clamped { port = clamped; return }
            UserDefaults.standard.set(port, forKey: "port")
            proxyManager.port = port
            if proxyManager.isRunning || proxyManager.isStarting { restartProxy() }
        }
    }
    var codeMode: Bool {
        didSet {
            UserDefaults.standard.set(codeMode, forKey: "codeMode")
            proxyManager.codeMode = codeMode
            if proxyManager.isRunning || proxyManager.isStarting { restartProxy() }
        }
    }

    // MARK: - Guardrails settings (persisted in UserDefaults)

    /// Whether the guardrails proxy should run. Toggling starts/stops it.
    var guardrailsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(guardrailsEnabled, forKey: "guardrailsEnabled")
            if guardrailsEnabled { startGuardrails() } else { stopGuardrails() }
        }
    }
    /// Address the proxy listens on for OpenAI-compatible traffic.
    var guardrailsPort: Int {
        didSet {
            let clamped = max(1024, min(65535, guardrailsPort))
            if guardrailsPort != clamped { guardrailsPort = clamped; return }
            UserDefaults.standard.set(guardrailsPort, forKey: "guardrailsPort")
            guardrailsManager.listenPort = guardrailsPort
            restartGuardrailsIfRunning()
        }
    }
    /// Admin/metrics server port (`--admin-listen`).
    var guardrailsAdminPort: Int {
        didSet {
            let clamped = max(1024, min(65535, guardrailsAdminPort))
            if guardrailsAdminPort != clamped { guardrailsAdminPort = clamped; return }
            UserDefaults.standard.set(guardrailsAdminPort, forKey: "guardrailsAdminPort")
            guardrailsManager.adminPort = guardrailsAdminPort
            restartGuardrailsIfRunning()
        }
    }
    /// Backend base URL the proxy forwards to (`--backend`).
    var guardrailsBackend: String {
        didSet {
            UserDefaults.standard.set(guardrailsBackend, forKey: "guardrailsBackend")
            guardrailsManager.backend = guardrailsBackend
            restartGuardrailsIfRunning()
        }
    }

    // MARK: - Memory settings (persisted in UserDefaults)

    /// Whether the memory-rs `serve` process should run. Toggling starts/stops it.
    var memoryEnabled: Bool {
        didSet {
            UserDefaults.standard.set(memoryEnabled, forKey: "memoryEnabled")
            if memoryEnabled { startMemory() } else { stopMemory() }
        }
    }
    /// Single port for both the REST API and the MCP endpoint at `/mcp`.
    var memoryPort: Int {
        didSet {
            let clamped = max(1024, min(65535, memoryPort))
            if memoryPort != clamped { memoryPort = clamped; return }
            UserDefaults.standard.set(memoryPort, forKey: "memoryPort")
            memoryManager.port = memoryPort
            restartMemoryIfRunning()
        }
    }
    /// Bind 0.0.0.0 instead of 127.0.0.1 (`--public`).
    var memoryPublic: Bool {
        didSet {
            UserDefaults.standard.set(memoryPublic, forKey: "memoryPublic")
            memoryManager.publicBind = memoryPublic
            restartMemoryIfRunning()
        }
    }
    // MARK: - Code Intelligence settings (persisted in UserDefaults)

    /// Whether the codesearch `serve` process should run. Toggling starts/stops it.
    var codesearchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(codesearchEnabled, forKey: "codesearchEnabled")
            if codesearchEnabled { startCodesearch() } else { stopCodesearch() }
        }
    }
    /// Port for the bundled MCP HTTP server (`--mcp-port`).
    var codesearchMcpPort: Int {
        didSet {
            let clamped = max(1024, min(65535, codesearchMcpPort))
            if codesearchMcpPort != clamped { codesearchMcpPort = clamped; return }
            UserDefaults.standard.set(codesearchMcpPort, forKey: "codesearchMcpPort")
            codesearchManager.mcpPort = codesearchMcpPort
            restartCodesearchIfRunning()
        }
    }
    /// Port for the REST/JSON management API (`--mgmt-port`).
    var codesearchMgmtPort: Int {
        didSet {
            let clamped = max(1024, min(65535, codesearchMgmtPort))
            if codesearchMgmtPort != clamped { codesearchMgmtPort = clamped; return }
            UserDefaults.standard.set(codesearchMgmtPort, forKey: "codesearchMgmtPort")
            codesearchManager.mgmtPort = codesearchMgmtPort
            restartCodesearchIfRunning()
        }
    }
    /// Bind both servers on 0.0.0.0 instead of 127.0.0.1 (`--public`).
    var codesearchPublic: Bool {
        didSet {
            UserDefaults.standard.set(codesearchPublic, forKey: "codesearchPublic")
            codesearchManager.publicBind = codesearchPublic
            restartCodesearchIfRunning()
        }
    }

    /// Whether to keep a `memory` entry in the proxy's servers.json pointing at
    /// the running memory service, so agents reach memory tools through the one
    /// proxy endpoint. Turning it off removes the managed entry.
    var registerMemoryWithProxy: Bool {
        didSet {
            UserDefaults.standard.set(registerMemoryWithProxy, forKey: "registerMemoryWithProxy")
            syncMemoryProxyRegistration()
        }
    }

    @ObservationIgnored private var fileWatcherSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var fileWatcherFD: Int32 = -1
    @ObservationIgnored private var reloadWorkItem: DispatchWorkItem?
    @ObservationIgnored private var guardrailsRestartWork: DispatchWorkItem?
    @ObservationIgnored private var memoryRestartWork: DispatchWorkItem?
    @ObservationIgnored private var codesearchRestartWork: DispatchWorkItem?

    /// Management API port is always the MCP port + 1 (panoply's layout).
    var apiPort: Int { port + 1 }
    private var apiBase: String { "http://127.0.0.1:\(apiPort)" }

    // MARK: - Normalized service status (drives sidebar/menu bar)

    var proxyStatus: ServiceStatus {
        if proxyManager.isStarting { return .starting }
        return proxyManager.isRunning ? .running : .stopped
    }

    var guardrailsStatus: ServiceStatus {
        if !guardrailsEnabled && !guardrailsManager.isRunning && !guardrailsManager.isStarting { return .stopped }
        if guardrailsManager.isStarting { return .starting }
        if guardrailsManager.isRunning { return guardrailsManager.isReachable ? .running : .runningUnreachable }
        return .stopped
    }

    var memoryStatus: ServiceStatus {
        if memoryManager.isStarting { return .starting }
        if memoryManager.isRunning { return memoryManager.isReachable ? .running : .runningUnreachable }
        return .stopped
    }

    var codesearchStatus: ServiceStatus {
        if codesearchManager.isStarting { return .starting }
        if codesearchManager.isRunning { return codesearchManager.isReachable ? .running : .runningUnreachable }
        return .stopped
    }

    func status(for section: AppSection) -> ServiceStatus? {
        switch section {
        case .proxy:      return proxyStatus
        case .guardrails: return guardrailsStatus
        case .memory:     return memoryStatus
        case .code:       return codesearchStatus
        }
    }

    /// Names of the MCP servers the running proxy is actually serving — sourced
    /// from the tools it probed on startup (`/api/tools`), so the sidebar's
    /// nested "Proxy ▸ server" rows reflect what's live, not just what's in the
    /// config file. Empty while the proxy is stopped. A configured-but-disabled
    /// server never gets probed, so it never appears here.
    var proxiedServerNames: [String] {
        guard proxyManager.isRunning else { return [] }
        return discoveredTools.keys.sorted()
    }

    // MARK: - Config URL

    private var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".panoply/servers.json")
    }

    /// The active config file path, derived from the local (API-synced) preset state.
    var configURL: URL {
        if let id = activePresetID,
           let preset = presets.first(where: { $0.id == id }) {
            return URL(fileURLWithPath: preset.filePath)
        }
        return defaultConfigURL
    }

    // MARK: - Init

    init() {
        let savedPort     = UserDefaults.standard.integer(forKey: "port")
        let savedCodeMode = UserDefaults.standard.bool(forKey: "codeMode")
        let port          = (1024...65534).contains(savedPort) ? savedPort : 7070

        self.port         = port
        self.codeMode     = savedCodeMode
        self.proxyManager = ProxyManager(port: port, codeMode: savedCodeMode)

        // Guardrails settings (fall back to upstream defaults when unset).
        let savedGRPort      = UserDefaults.standard.integer(forKey: "guardrailsPort")
        let savedGRAdminPort = UserDefaults.standard.integer(forKey: "guardrailsAdminPort")
        let grPort      = (1024...65535).contains(savedGRPort) ? savedGRPort : 8080
        var grAdminPort = (1024...65535).contains(savedGRAdminPort) ? savedGRAdminPort : 8081
        // Listen and admin ports must differ; bump the admin port if a stale or
        // corrupt persisted value collides with the listen port.
        if grAdminPort == grPort { grAdminPort = grPort == 65535 ? grPort - 1 : grPort + 1 }
        let grBackend = UserDefaults.standard.string(forKey: "guardrailsBackend") ?? "http://127.0.0.1:1234"
        self.guardrailsEnabled   = UserDefaults.standard.bool(forKey: "guardrailsEnabled")
        self.guardrailsPort      = grPort
        self.guardrailsAdminPort = grAdminPort
        self.guardrailsBackend   = grBackend
        self.guardrailsManager   = GuardrailsManager(listenPort: grPort, adminPort: grAdminPort, backend: grBackend)

        // Memory settings (fall back to memory-rs's own `serve` default).
        let savedMemPort = UserDefaults.standard.integer(forKey: "memoryPort")
        let memPort      = (1024...65535).contains(savedMemPort) ? savedMemPort : 8766
        let memPublic    = UserDefaults.standard.bool(forKey: "memoryPublic")
        self.memoryEnabled = UserDefaults.standard.bool(forKey: "memoryEnabled")
        self.memoryPort    = memPort
        self.memoryPublic  = memPublic
        self.memoryManager = MemoryManager(port: memPort, publicBind: memPublic)
        // Same local model server guardrails points at, so a first run gets
        // memory extraction without setup. Separate from codesearch's — the two
        // services keep independent LLM configs.
        self.memoryManager.llmAutodetectBase = grBackend
        // Default ON: the whole point of running both is that agents reach
        // memory through the single proxy endpoint. `object(forKey:)` (not
        // `bool(forKey:)`) so an unset default reads as "not yet chosen".
        self.registerMemoryWithProxy =
            (UserDefaults.standard.object(forKey: "registerMemoryWithProxy") as? Bool) ?? true

        // Code Intelligence settings (fall back to codesearch's `serve` defaults).
        let savedCsMcpPort  = UserDefaults.standard.integer(forKey: "codesearchMcpPort")
        let savedCsMgmtPort = UserDefaults.standard.integer(forKey: "codesearchMgmtPort")
        let csMcpPort  = (1024...65535).contains(savedCsMcpPort) ? savedCsMcpPort : 8677
        var csMgmtPort = (1024...65535).contains(savedCsMgmtPort) ? savedCsMgmtPort : 8676
        // MCP and management ports must differ; bump if a stale/corrupt value collides.
        if csMgmtPort == csMcpPort { csMgmtPort = csMcpPort == 65535 ? csMcpPort - 1 : csMcpPort + 1 }
        let csPublic = UserDefaults.standard.bool(forKey: "codesearchPublic")
        self.codesearchEnabled  = UserDefaults.standard.bool(forKey: "codesearchEnabled")
        self.codesearchMcpPort  = csMcpPort
        self.codesearchMgmtPort = csMgmtPort
        self.codesearchPublic   = csPublic
        self.codesearchManager  = CodesearchManager(mcpPort: csMcpPort, mgmtPort: csMgmtPort, publicBind: csPublic)
        // Auto-register the same local model server guardrails points at as
        // codesearch's LLM endpoint (if the user hasn't configured one), so
        // community names + call-flow explanations work without setup.
        self.codesearchManager.llmAutodetectBase = grBackend

        // Bootstrap preset state from disk so the UI is populated before the proxy starts.
        let (initialPresets, initialActiveID) = AppState.loadPresetsFromDisk()
        self.presets        = initialPresets
        self.activePresetID = initialActiveID

        loadConfig()
        startFileWatcher()

        // Reconcile the managed `memory` proxy entry against what's actually
        // configured. Property observers don't fire during init, and neither
        // start/stop path runs when memory is disabled — so without this, a
        // managed entry left over from a previous run would linger in
        // servers.json and the proxy would keep trying to reach a dead port.
        syncMemoryProxyRegistration()

        // Auto-discover tools when the proxy transitions to running.
        proxyManager.onBecameRunning = { [weak self] in
            // Small delay to let the API thread bind its socket.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.discoverTools()
            }
        }
    }

    // MARK: - Disk bootstrap (used only before the proxy is online)

    /// Read presets from ~/.panoply/presets.json without going through the API.
    /// Called once at init so the UI has data before the proxy starts.
    static func loadPresetsFromDisk() -> ([Preset], UUID?) {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".panoply/presets.json")
        guard let data = try? Data(contentsOf: path),
              let file = try? JSONDecoder().decode(PresetsFile.self, from: data)
        else { return ([], nil) }
        let activeID = file.activePresetID.flatMap { UUID(uuidString: $0) }
        return (file.presets, activeID)
    }

    // MARK: - File Watcher

    /// Watches the active configURL for external modifications using kqueue.
    /// Debounces rapid writes (editors often write multiple times on save) by 0.3 s.
    private func startFileWatcher() {
        stopFileWatcher()
        let path = configURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { print("⚠️ Could not open \(path) for watching"); return }
        fileWatcherFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.reloadWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                print("🔄 Config file changed on disk, reloading…")
                DispatchQueue.main.async {
                    self.loadConfig()
                    self.startFileWatcher()
                }
            }
            self.reloadWorkItem = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { if fd >= 0 { close(fd) } }
        source.resume()
        fileWatcherSource = source
        print("👁️ Watching config file: \(path)")
    }

    private func stopFileWatcher() {
        reloadWorkItem?.cancel()
        reloadWorkItem = nil
        fileWatcherSource?.cancel()
        fileWatcherSource = nil
    }

    deinit {
        reloadWorkItem?.cancel()
        fileWatcherSource?.cancel()
    }

    // MARK: - Config (local read for the servers panel)

    func loadConfig() {
        let configDir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        print("📁 Loading config from: \(configURL.path)")
        guard let data   = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(ServersConfig.self, from: data)
        else {
            print("⚠️ No config found, creating default config")
            createDefaultConfig()
            return
        }
        servers = config.mcpServers
        print("✓ Loaded \(servers.count) server(s) from config")
        loadToolsFromCache()
        // Drop cached tools for servers no longer in the config, so a server
        // removed from servers.json stops appearing in the sidebar / proxied
        // list (the tools cache is keyed by config path and outlives edits).
        pruneDiscoveredTools()
    }

    /// Remove `discoveredTools` entries for servers that aren't in the current
    /// config — reconciles the persisted tool cache after external edits.
    private func pruneDiscoveredTools() {
        let configured = Set(servers.keys)
        let stale = discoveredTools.keys.filter { !configured.contains($0) }
        guard !stale.isEmpty else { return }
        for name in stale { discoveredTools.removeValue(forKey: name) }
        print("🧹 Pruned \(stale.count) stale server(s) from tool cache: \(stale.joined(separator: ", "))")
        saveToolsToCache()
    }

    func saveConfig() {
        let configDir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let config  = ServersConfig(mcpServers: servers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configURL)
        print("✓ Saved config to: \(configURL.path)")
    }

    private func createDefaultConfig() {
        let sampleServers: [String: MCPServer] = [
            "example-filesystem": MCPServer(
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                env: nil, url: nil, transport: "stdio", auth: nil, enabled: false),
            "example-github": MCPServer(
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-github"],
                env: ["GITHUB_PERSONAL_ACCESS_TOKEN": "your-token-here"],
                url: nil, transport: "stdio", auth: nil, enabled: false)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(ServersConfig(mcpServers: sampleServers)) else { return }
        try? data.write(to: configURL)
        print("✓ Created default config at: \(configURL.path)")
        servers = sampleServers
    }

    // MARK: - Proxy process

    func startProxy() { proxyManager.startBundled() }
    func stopProxy()  { proxyManager.stop() }

    func restartProxy() {
        proxyManager.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startProxy() }
    }

    // MARK: - Guardrails process

    /// Start guardrails if the user has enabled it. Called at app launch.
    func startGuardrailsIfEnabled() {
        if guardrailsEnabled { startGuardrails() }
    }

    func startGuardrails() { guardrailsManager.startBundled() }

    func stopGuardrails() {
        guardrailsRestartWork?.cancel()
        guardrailsRestartWork = nil
        guardrailsManager.stop()
    }

    /// Restart, coalescing rapid successive calls (e.g. several settings
    /// changed in one Settings "Done") into a single stop + delayed start so
    /// we never schedule overlapping launches.
    func restartGuardrails() {
        guardrailsManager.stop()
        guardrailsRestartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startGuardrails() }
        guardrailsRestartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func restartGuardrailsIfRunning() {
        if guardrailsManager.isRunning || guardrailsManager.isStarting { restartGuardrails() }
    }

    // MARK: - Memory process

    /// Start memory-rs if the user has enabled it. Called at app launch.
    func startMemoryIfEnabled() {
        if memoryEnabled { startMemory() }
    }

    func startMemory() {
        memoryManager.startBundled()
        syncMemoryProxyRegistration()
    }

    func stopMemory() {
        memoryRestartWork?.cancel()
        memoryRestartWork = nil
        memoryManager.stop()
        syncMemoryProxyRegistration()
    }

    /// Restart, coalescing rapid successive calls into one stop + delayed start.
    func restartMemory() {
        memoryManager.stop()
        memoryRestartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startMemory() }
        memoryRestartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func restartMemoryIfRunning() {
        if memoryManager.isRunning || memoryManager.isStarting { restartMemory() }
    }

    // MARK: - Codesearch process

    /// Start codesearch if the user has enabled it. Called at app launch.
    func startCodesearchIfEnabled() {
        if codesearchEnabled { startCodesearch() }
    }

    func startCodesearch() { codesearchManager.startBundled() }

    func stopCodesearch() {
        codesearchRestartWork?.cancel()
        codesearchRestartWork = nil
        codesearchManager.stop()
    }

    /// Restart, coalescing rapid successive calls into one stop + delayed start.
    func restartCodesearch() {
        codesearchManager.stop()
        codesearchRestartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startCodesearch() }
        codesearchRestartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func restartCodesearchIfRunning() {
        if codesearchManager.isRunning || codesearchManager.isStarting { restartCodesearch() }
    }

    // MARK: - Memory ▸ Proxy registration

    /// Keep the proxy's `memory` server entry in step with the memory service.
    ///
    /// When both the toggle and the service are on, the entry points at the
    /// running MCP endpoint; otherwise the managed entry is removed. Only ever
    /// touches the one entry it owns (marked via `managedByHoplon`), so a
    /// hand-written config survives untouched.
    func syncMemoryProxyRegistration() {
        let shouldRegister = registerMemoryWithProxy && memoryEnabled
        let changed = ProxyRegistration.sync(
            servers: &servers,
            shouldRegister: shouldRegister,
            endpoint: memoryManager.mcpEndpoint
        )
        guard changed else { return }
        saveConfig()
        // Push it to the running proxy so connected clients pick it up without
        // a restart; a stopped proxy reads the file at next launch.
        if proxyManager.isRunning { putFullConfig() }
    }

    // MARK: - Tool Discovery (API only)

    /// Path to the on-disk cache of discovered tools, keyed by config path.
    private var toolsCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".panoply/tools_cache.json")
    }

    /// Populate `discoveredTools` from disk for the current config so the UI
    /// has data immediately, before the proxy has finished probing.
    func loadToolsFromCache() {
        guard let data = try? Data(contentsOf: toolsCacheURL),
              let cache = try? JSONDecoder().decode([String: [String: [DiscoveredTool]]].self, from: data),
              let tools = cache[configURL.path]
        else { return }
        discoveredTools = tools
        print("📦 Loaded \(tools.values.map(\.count).reduce(0, +)) cached tools across \(tools.count) server(s)")
    }

    /// Persist the current `discoveredTools` to disk under the active config path.
    private func saveToolsToCache() {
        var cache: [String: [String: [DiscoveredTool]]] = [:]
        if let data = try? Data(contentsOf: toolsCacheURL),
           let existing = try? JSONDecoder().decode([String: [String: [DiscoveredTool]]].self, from: data) {
            cache = existing
        }
        cache[configURL.path] = discoveredTools
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: toolsCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: toolsCacheURL)
    }

    func discoverTools() {
        guard !isDiscoveringTools, proxyManager.isRunning else { return }
        isDiscoveringTools = true

        guard let url = URL(string: "\(apiBase)/api/tools") else {
            isDiscoveringTools = false
            return
        }

        // Allow enough time for all upstream MCP servers to be probed.
        var request = URLRequest(url: url)
        request.timeoutInterval = 90

        print("🔍 Tool discovery via API: \(url)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                print("🔍 Tool discovery failed: \(error.localizedDescription)")
                Task { @MainActor in self.isDiscoveringTools = false }
                return
            }

            guard let data,
                  let parsed = try? JSONDecoder().decode([String: [ToolEntry]].self, from: data)
            else {
                print("🔍 Tool discovery: unexpected response")
                Task { @MainActor in self.isDiscoveringTools = false }
                return
            }

            let tools = parsed.mapValues { entries in
                entries.map { DiscoveredTool(name: $0.name, description: $0.description) }
            }
            for (server, list) in tools.sorted(by: { $0.key < $1.key }) {
                print("🔍 \(server): \(list.count) tools")
            }

            Task { @MainActor in
                self.discoveredTools = tools
                self.isDiscoveringTools = false
                self.saveToolsToCache()
            }
        }.resume()
    }

    func isToolDisabled(server: String, tool: String) -> Bool {
        servers[server]?.disabledTools?.contains(tool) ?? false
    }

    func toggleTool(server: String, tool: String) {
        // Optimistic local update for snappy UI.
        let currentlyDisabled = isToolDisabled(server: server, tool: tool)
        let newEnabled = currentlyDisabled  // flipping: if was disabled, now enabled
        if servers[server]?.disabledTools == nil { servers[server]?.disabledTools = [] }
        if let idx = servers[server]?.disabledTools?.firstIndex(of: tool) {
            servers[server]?.disabledTools?.remove(at: idx)
        } else {
            servers[server]?.disabledTools?.append(tool)
        }
        if servers[server]?.disabledTools?.isEmpty == true { servers[server]?.disabledTools = nil }

        // Persist via the REST API so the running proxy hot-swaps the tool
        // (no process restart, no MCP client reconnect).
        postToolToggle(server: server, tool: tool, enabled: newEnabled)
    }

    // MARK: - Config API

    /// POST /api/tools/toggle — flips one tool's visibility on the running proxy.
    private func postToolToggle(server: String, tool: String, enabled: Bool) {
        guard let url = URL(string: "\(apiBase)/api/tools/toggle") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "server": server, "tool": tool, "enabled": enabled,
        ])
        URLSession.shared.dataTask(with: request).resume()
    }

    /// POST /api/servers/{name}/toggle — enables/disables a whole backend.
    func postServerToggle(server: String, enabled: Bool) {
        guard let encoded = server.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(apiBase)/api/servers/\(encoded)/toggle")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": enabled])
        URLSession.shared.dataTask(with: request).resume()
    }

    /// PUT /api/config — writes the full config and rebuilds the proxy. Used
    /// when structural changes (command/args/env/url/transport) require it.
    func putFullConfig() {
        guard let url = URL(string: "\(apiBase)/api/config") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let config = ServersConfig(mcpServers: servers)
        request.httpBody = try? encoder.encode(config)
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - Preset API

    /// Fetch the current preset list from the proxy and sync local state.
    func fetchPresets() {
        guard let url = URL(string: "\(apiBase)/api/presets") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self,
                  let data,
                  let response = try? JSONDecoder().decode(PresetsResponse.self, from: data)
            else { return }
            let activeID = response.activePresetID.flatMap { UUID(uuidString: $0) }
            Task { @MainActor in
                self.presets        = response.presets
                self.activePresetID = activeID
                self.loadConfig()
                self.startFileWatcher()
            }
        }.resume()
    }

    /// Add a new preset. Calls POST /api/presets and updates local state on success.
    func addPreset(name: String, filePath: String, completion: (@Sendable (Bool) -> Void)? = nil) {
        guard !filePath.isEmpty,
              let url = URL(string: "\(apiBase)/api/presets")
        else { completion?(false); return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["name": name.isEmpty
            ? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            : name, "filePath": filePath])

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self,
                  let data,
                  let r = try? JSONDecoder().decode(CreatePresetResponse.self, from: data)
            else { completion?(false); return }
            Task { @MainActor in
                self.presets.append(r.preset)
                completion?(true)
            }
        }.resume()
    }

    /// Remove a preset. Calls DELETE /api/presets/{id} and updates local state.
    func removePreset(_ preset: Preset, completion: (@Sendable (Bool) -> Void)? = nil) {
        guard let url = URL(string: "\(apiBase)/api/presets/\(preset.id)") else {
            completion?(false); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let wasActive = activePresetID == preset.id

        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let self,
                  let http = response as? HTTPURLResponse, http.statusCode == 200
            else { completion?(false); return }
            Task { @MainActor in
                self.presets.removeAll { $0.id == preset.id }
                if wasActive {
                    self.activePresetID = nil
                    self.loadConfig()
                    self.startFileWatcher()
                    if self.proxyManager.isRunning || self.proxyManager.isStarting {
                        self.restartProxy()
                    }
                }
                completion?(true)
            }
        }.resume()
    }

    /// Rename a preset. Calls PATCH /api/presets/{id}.
    func renamePreset(id: UUID, to name: String) {
        guard let url = URL(string: "\(apiBase)/api/presets/\(id)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["name": name])
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                print("⚠️ Failed to rename preset: \(error.localizedDescription)")
                return
            }

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("⚠️ Rename preset failed with non-200 response")
                return
            }

            if let data,
               let decoded = try? JSONDecoder().decode([String: Preset].self, from: data),
               let updatedPreset = decoded["preset"] {
                Task { @MainActor in
                    if let idx = self.presets.firstIndex(where: { $0.id == id }) {
                        self.presets[idx] = updatedPreset
                    }
                }
            }
        }.resume()
    }

    /// Activate a preset (or nil for default). Calls POST /api/presets/{id}/activate,
    /// which hot-swaps the running proxy's active config without restarting it.
    func switchPreset(_ preset: Preset?, completion: (@Sendable (Bool) -> Void)? = nil) {
        let path: String
        if let preset {
            path = "\(apiBase)/api/presets/\(preset.id)/activate"
        } else {
            path = "\(apiBase)/api/presets/default/activate"
        }
        guard let url = URL(string: path) else { completion?(false); return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let self,
                  let http = response as? HTTPURLResponse, http.statusCode == 200
            else { completion?(false); return }
            Task { @MainActor in
                self.activePresetID = preset?.id
                self.loadConfig()
                self.startFileWatcher()
                completion?(true)
            }
        }.resume()
    }
}
