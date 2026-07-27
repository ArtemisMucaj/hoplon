import Foundation

/// Keeps a single `memory` entry in the proxy's `servers.json` pointing at the
/// running memory service, so an agent connected to the one proxy endpoint also
/// reaches the memory tools.
///
/// The rule this type exists to enforce: **only ever touch the entry we own.**
/// `servers.json` is a hand-editable file the user also owns, so a managed
/// entry is tagged with `managedByHoplon` in its description and every mutation
/// checks that tag first. A user's own `memory` server (however they defined it)
/// is left exactly as it is, and turning the toggle off removes only what we
/// added.
enum ProxyRegistration {
    /// Entry name written into `mcpServers`.
    static let serverName = "memory"

    /// Marker embedded in the managed entry's description. Chosen to be
    /// human-readable in the file — someone reading servers.json should
    /// understand why the entry is there and that the app rewrites it.
    static let managedMarker = "[managed by Hoplon]"

    private static let managedDescription =
        "Long-term memory: recall past decisions, preferences and session history. \(managedMarker)"

    /// Reconcile the managed entry against the desired state.
    ///
    /// - Returns: whether `servers` actually changed, so the caller can skip a
    ///   redundant disk write + proxy reload.
    @discardableResult
    static func sync(
        servers: inout [String: MCPServer],
        shouldRegister: Bool,
        endpoint: String
    ) -> Bool {
        let existing = servers[serverName]

        guard shouldRegister else {
            // Only remove an entry we created. A user-authored `memory` server
            // stays put — silently deleting it would be data loss.
            guard let existing, isManaged(existing) else { return false }
            servers.removeValue(forKey: serverName)
            print("🧹 Removed managed memory entry from the proxy config")
            return true
        }

        // Never overwrite a user-authored entry of the same name. They asked for
        // that server; ours would clobber it on every launch.
        if let existing, !isManaged(existing) {
            print("ℹ️ '\(serverName)' is user-defined in servers.json — leaving it alone")
            return false
        }

        let desired = MCPServer(
            command: nil,
            args: nil,
            env: nil,
            url: endpoint,
            headers: nil,
            transport: "http",
            auth: nil,
            description: managedDescription,
            enabled: true,
            // Preserve any per-tool hiding the user applied to our entry — it's
            // their choice about our server, not part of what we manage.
            disabledTools: existing?.disabledTools
        )

        guard existing != desired else { return false }
        servers[serverName] = desired
        print("🔗 Registered memory with the proxy at \(endpoint)")
        return true
    }

    /// Whether this entry is the one we manage.
    static func isManaged(_ server: MCPServer) -> Bool {
        server.description?.contains(managedMarker) ?? false
    }

    /// Whether a `memory` entry exists that we do NOT own — the case where the
    /// UI should explain why the toggle is having no effect.
    static func hasUserDefinedEntry(in servers: [String: MCPServer]) -> Bool {
        guard let existing = servers[serverName] else { return false }
        return !isManaged(existing)
    }
}
