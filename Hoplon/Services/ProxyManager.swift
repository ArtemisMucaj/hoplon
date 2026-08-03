import Foundation
import Observation
import UserNotifications

/// Supervises the bundled `panoply` binary — the MCP proxy that aggregates
/// every configured backend server behind three synthetic tools.
///
/// `panoply --http PORT` serves the MCP endpoint at `/mcp` and its REST
/// management API on `PORT + 1`; `AppState` drives that API for config,
/// presets and tool toggles.
@Observable
class ProxyManager {
    var isRunning = false
    var isStarting = false
    var lastError: String?

    /// Invoked on the main queue whenever the proxy transitions to running.
    @ObservationIgnored var onBecameRunning: (() -> Void)?

    private var process: Process?
    private var processSource: DispatchSourceProcess?
    /// One shared handle for the child's stdout+stderr — separate handles on
    /// the same file get independent offsets and overwrite each other.
    @ObservationIgnored private var processLogHandle: FileHandle?
    var port: Int
    var codeMode: Bool

    init(port: Int = 7070, codeMode: Bool = false) {
        self.port = port
        self.codeMode = codeMode

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                print("✓ Notification permission granted")
            }
        }
    }

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    // MARK: - Lifecycle

    func startBundled() {
        guard !isRunning && !isStarting else {
            print("⚠️ Already running or starting - ignoring start request")
            return
        }
        // Claim the re-entrancy guard synchronously. Deferring `isStarting = true`
        // to a later runloop tick lets a second start() call in the same tick
        // slip past the guard above and spawn a duplicate `panoply --http <port>`
        // (the loser then fails to bind the port and exits, flapping the proxy
        // to "stopped"). The other managers guard the same way.
        isStarting = true
        lastError = nil

        guard let resourcePath = Bundle.main.resourcePath else {
            let msg = "Could not locate app bundle resources."
            DispatchQueue.main.async { self.isStarting = false; self.lastError = msg }
            print("❌ \(msg)")
            return
        }

        let binaryPath = (resourcePath as NSString).appendingPathComponent("panoply")
        let fileManager = FileManager.default

        guard fileManager.isExecutableFile(atPath: binaryPath) else {
            let msg = "Bundled panoply binary not found at: \(binaryPath)\n\nRebuild the app after running scripts/fetch_binaries.sh"
            DispatchQueue.main.async { self.isStarting = false; self.lastError = msg }
            print("❌ \(msg)")
            return
        }

        print("🔄 Setting isStarting = true (bundled binary)")
        print("📦 Binary: \(binaryPath)")

        let logURL = logFileURL()
        prepareLogFile(at: logURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        var args = ["--http", "\(port)"]
        if codeMode { args.append("--code-mode") }
        proc.arguments = args
        proc.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser
        proc.environment = Self.shellEnvironment
        processLogHandle = logHandle(for: logURL)
        proc.standardOutput = processLogHandle
        proc.standardError  = processLogHandle

        do {
            try proc.run()
            process = proc
            print("✓ Panoply proxy launched from bundled binary")
            DispatchQueue.main.async { self.markRunning() }
        } catch {
            let msg = error.localizedDescription
            DispatchQueue.main.async {
                self.isStarting = false
                self.lastError = msg
            }
            print("❌ Failed to start bundled panoply: \(error)")
        }
    }

    func stop() {
        processSource?.cancel()
        processSource = nil
        if let proc = process, proc.isRunning {
            // Kill the entire process group so stdio backends don't linger.
            let pgid = proc.processIdentifier
            kill(-pgid, SIGTERM)
            proc.terminate()
        }
        process = nil
        processLogHandle?.closeFile()
        processLogHandle = nil
        isRunning = false
        isStarting = false
    }

    // MARK: - Private

    private func markStopped() {
        process = nil
        processLogHandle?.closeFile()
        processLogHandle = nil
        isRunning = false
        isStarting = false
        processSource?.cancel()
        processSource = nil
    }

    private func markRunning() {
        isStarting = false
        isRunning = true
        if let pid = process?.processIdentifier { watchProcess(pid) }
        print("✅ Panoply proxy is ready on port \(port)")
        onBecameRunning?()
        showReadyNotification()
    }

    private func showReadyNotification() {
        let content = UNMutableNotificationContent()
        content.title = "MCP Proxy Ready"
        content.body = "Panoply is running on \(endpoint)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func watchProcess(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.markStopped() }
        }
        source.resume()
        processSource = source
    }

    private func logFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".panoply/panoply.log")
    }

    private func prepareLogFile(at url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        // Truncate once at startup so stale content from previous runs is cleared.
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.truncateFile(atOffset: 0)
            handle.closeFile()
        }
    }

    private func logHandle(for url: URL) -> FileHandle? {
        try? FileHandle(forWritingTo: url)
    }

    // MARK: - Shell environment

    /// Capture the user's login shell PATH so child processes can find npx,
    /// uvx, etc. macOS GUI apps inherit a minimal PATH
    /// (/usr/bin:/bin:/usr/sbin:/sbin), which is not enough to launch the stdio
    /// MCP backends panoply proxies.
    static let shellEnvironment: [String: String] = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "env"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    var env: [String: String] = [:]
                    for line in output.components(separatedBy: "\n") {
                        guard let eqIdx = line.firstIndex(of: "=") else { continue }
                        let key = String(line[line.startIndex..<eqIdx])
                        let value = String(line[line.index(after: eqIdx)...])
                        env[key] = value
                    }
                    if !env.isEmpty {
                        print("✓ Captured shell environment (\(env.count) vars)")
                        return env
                    }
                }
            }
        } catch {
            print("⚠️ Failed to capture shell environment: \(error)")
        }

        // Fallback: use current process env (minimal but better than nothing)
        return ProcessInfo.processInfo.environment
    }()
}
