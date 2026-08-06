import Foundation

/// Installs command-line symlinks for the bundled CLI tools into a user-owned
/// bin directory, so `codesearch` / `memory-rs` are runnable from a terminal.
///
/// Why `~/.local/bin` and not `/usr/local/bin`: `/usr/local/bin` is `root:wheel`,
/// so writing there needs `sudo` or a privileged helper — a big notarization and
/// UX cost for a convenience feature. `~/.local/bin` is user-owned, needs no
/// elevation, and is a conventional per-user bin dir. The app is not sandboxed
/// (see Hoplon.entitlements), so it can write there directly.
///
/// The links point *into the app bundle* (`Bundle.main.resourcePath`). That
/// tracks the current binary automatically, but breaks if the app is moved,
/// deleted, or relocated by Gatekeeper path-translocation — so we surface a
/// `.stale` state and let the user repair it with one click.
@MainActor
@Observable
final class CliLinkManager {
    /// The tools we expose. Bundled binary name → the command name to install as.
    /// (guardrail/panoply are supervised-only services, not user-facing CLIs.)
    struct Tool: Identifiable {
        let binaryName: String   // filename under the app's Resources/
        let commandName: String  // symlink name created in the bin dir
        var id: String { binaryName }
    }

    static let tools: [Tool] = [
        Tool(binaryName: "codesearch", commandName: "codesearch"),
        Tool(binaryName: "memory-rs", commandName: "memory-rs"),
    ]

    enum LinkState: Equatable {
        case notLinked
        /// A symlink we own, pointing at the current bundled binary.
        case linked
        /// Something exists at the path but isn't our correct link — a symlink to
        /// a different (moved/old) bundle, or a non-symlink file the user placed.
        case stale(reason: String)
    }

    /// Per-command state, recomputed by `refresh()`.
    private(set) var states: [String: LinkState] = [:]

    /// Whether the target bin dir is on the user's `PATH` (best-effort; based on
    /// the `PATH` the app inherited plus the shell env we capture for subprocesses).
    private(set) var binDirOnPath: Bool = false

    /// Last error from an install/remove attempt, for display.
    private(set) var lastError: String?

    /// `~/.local/bin`.
    var binDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
    }

    var binDirectoryPath: String { binDirectory.path }

    private var resourcePath: String? { Bundle.main.resourcePath }

    // MARK: - Queries

    /// Absolute path to a tool's bundled binary, or nil if the bundle can't be found.
    private func bundledBinaryURL(for tool: Tool) -> URL? {
        guard let resourcePath else { return nil }
        return URL(fileURLWithPath: resourcePath)
            .appendingPathComponent(tool.binaryName)
    }

    private func linkURL(for tool: Tool) -> URL {
        binDirectory.appendingPathComponent(tool.commandName)
    }

    /// Recompute link states and PATH membership. Cheap; call on appear.
    func refresh() {
        let fm = FileManager.default
        var next: [String: LinkState] = [:]
        for tool in Self.tools {
            next[tool.commandName] = computeState(for: tool, fm: fm)
        }
        states = next
        binDirOnPath = isBinDirOnPath()
    }

    private func computeState(for tool: Tool, fm: FileManager) -> LinkState {
        let link = linkURL(for: tool)
        // `fileExists` follows symlinks; use the no-follow attribute check first.
        let attrs = try? fm.attributesOfItem(atPath: link.path)
        guard attrs != nil else {
            // Nothing at the path (or unreadable). Treat unreadable as not-linked;
            // the install attempt will surface any real error.
            if fm.fileExists(atPath: link.path) {
                return .stale(reason: "A file already exists at \(link.path).")
            }
            return .notLinked
        }

        // Is it a symlink?
        if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            let dest = try? fm.destinationOfSymbolicLink(atPath: link.path)
            let expected = bundledBinaryURL(for: tool)?.path
            if let dest, let expected, resolvePath(dest, relativeTo: link) == expected {
                return .linked
            }
            return .stale(reason: "Links to \(dest ?? "an unknown path") instead of this app's binary.")
        }

        // A real file the user put there — never overwrite it silently.
        return .stale(reason: "A non-symlink file already exists at \(link.path).")
    }

    /// Resolve a possibly-relative symlink destination to an absolute path for
    /// comparison. Our links are always absolute, but be defensive.
    private func resolvePath(_ dest: String, relativeTo link: URL) -> String {
        if dest.hasPrefix("/") { return dest }
        return link.deletingLastPathComponent()
            .appendingPathComponent(dest)
            .standardizedFileURL.path
    }

    // MARK: - Mutations

    /// Create (or repair) the symlink for one tool. Overwrites only a symlink we
    /// recognize as ours or a stale one *of our own name* — never a user's real file.
    /// Returns true on success.
    @discardableResult
    func install(_ tool: Tool) -> Bool {
        lastError = nil
        let fm = FileManager.default

        guard let target = bundledBinaryURL(for: tool),
              fm.isExecutableFile(atPath: target.path) else {
            lastError = "Bundled \(tool.binaryName) not found in the app. Reinstall Hoplon."
            return false
        }

        do {
            try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        } catch {
            lastError = "Couldn't create \(binDirectoryPath): \(error.localizedDescription)"
            return false
        }

        let link = linkURL(for: tool)
        // Refuse to clobber a non-symlink file the user owns.
        if let attrs = try? fm.attributesOfItem(atPath: link.path),
           let type = attrs[.type] as? FileAttributeType,
           type != .typeSymbolicLink {
            lastError = "\(link.path) already exists and isn't a symlink. Remove it yourself first."
            return false
        }
        // Replace any existing symlink (ours, or one pointing at an old bundle).
        try? fm.removeItem(at: link)

        do {
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
        } catch {
            lastError = "Couldn't create the link: \(error.localizedDescription)"
            refresh()
            return false
        }
        refresh()
        return true
    }

    /// Remove the symlink for one tool. Only removes a symlink — never a real file.
    /// Returns true on success (including when nothing was there).
    @discardableResult
    func remove(_ tool: Tool) -> Bool {
        lastError = nil
        let fm = FileManager.default
        let link = linkURL(for: tool)

        guard let attrs = try? fm.attributesOfItem(atPath: link.path) else {
            refresh()
            return true  // already absent
        }
        if let type = attrs[.type] as? FileAttributeType, type != .typeSymbolicLink {
            lastError = "\(link.path) isn't a symlink Hoplon created; leaving it alone."
            return false
        }
        do {
            try fm.removeItem(at: link)
        } catch {
            lastError = "Couldn't remove the link: \(error.localizedDescription)"
            refresh()
            return false
        }
        refresh()
        return true
    }

    /// Install all tools. Returns true only if every one succeeded.
    @discardableResult
    func installAll() -> Bool {
        Self.tools.reduce(true) { ok, tool in install(tool) && ok }
    }

    @discardableResult
    func removeAll() -> Bool {
        Self.tools.reduce(true) { ok, tool in remove(tool) && ok }
    }

    // MARK: - PATH

    /// The `line` a user can paste into their shell profile to put the bin dir
    /// on PATH.
    var pathExportLine: String {
        "export PATH=\"$HOME/.local/bin:$PATH\""
    }

    /// Best-effort check that the bin dir is already on PATH. Uses the app's own
    /// inherited `PATH` plus the login-shell env Hoplon captures for subprocesses
    /// (a GUI app's inherited PATH is usually minimal, so the captured env is the
    /// more accurate signal).
    private func isBinDirOnPath() -> Bool {
        let target = binDirectoryPath
        var candidates: [String] = []
        if let p = ProcessInfo.processInfo.environment["PATH"] { candidates.append(p) }
        if let p = ProxyManager.shellEnvironment["PATH"] { candidates.append(p) }
        let entries = candidates
            .flatMap { $0.split(separator: ":").map(String.init) }
            .map { ($0 as NSString).expandingTildeInPath }
        return entries.contains(target)
    }
}
