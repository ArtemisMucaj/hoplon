import Foundation

/// Keeps a single entry in the proxy's `servers.json` pointing at one of the
/// services this app supervises, so an agent connected to the one proxy endpoint
/// also reaches that service's MCP tools.
///
/// The rule this type exists to enforce: **only ever touch the entry we own.**
/// `servers.json` is a hand-editable file the user also owns, so a managed
/// entry is tagged with `managedMarker` in its description and every mutation
/// checks that tag first. A user's own server of the same name (however they
/// defined it) is left exactly as it is, and turning the toggle off removes only
/// what we added.
///
/// One instance per service — `.memory` and `.codesearch`. The two are
/// independent entries with independent toggles; a service is only ever
/// reconciled through its own instance.
struct ProxyRegistration {
    /// Entry name written into `mcpServers`.
    let serverName: String

    /// Description written into the managed entry. Panoply surfaces it through
    /// `load_tools`, so it should read as "what this provider is for" — the
    /// marker is appended automatically.
    private let purpose: String

    /// Marker embedded in a managed entry's description. Chosen to be
    /// human-readable in the file — someone reading servers.json should
    /// understand why the entry is there and that the app rewrites it.
    static let managedMarker = "[managed by Hoplon]"

    private var managedDescription: String { "\(purpose) \(Self.managedMarker)" }

    static let memory = ProxyRegistration(
        serverName: "memory",
        purpose: "Long-term memory: recall past decisions, preferences and session history."
    )

    static let codesearch = ProxyRegistration(
        serverName: "codesearch",
        purpose: "Code intelligence: semantic search, call graphs and community structure over indexed repositories."
    )

    /// Reconcile the managed entry against the desired state.
    ///
    /// - Returns: whether `servers` actually changed, so the caller can skip a
    ///   redundant disk write + proxy reload.
    @discardableResult
    func sync(
        servers: inout [String: MCPServer],
        shouldRegister: Bool,
        endpoint: String
    ) -> Bool {
        let existing = servers[serverName]

        guard shouldRegister else {
            // Only remove an entry we created. A user-authored server of the
            // same name stays put — silently deleting it would be data loss.
            guard let existing, isManaged(existing) else { return false }
            servers.removeValue(forKey: serverName)
            print("🧹 Removed managed \(serverName) entry from the proxy config")
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
        print("🔗 Registered \(serverName) with the proxy at \(endpoint)")
        return true
    }

    /// Whether this entry is one we manage.
    func isManaged(_ server: MCPServer) -> Bool {
        server.description?.contains(Self.managedMarker) ?? false
    }

    /// Whether an entry under our name exists that we do NOT own — the case
    /// where the UI should explain why the toggle is having no effect.
    func hasUserDefinedEntry(in servers: [String: MCPServer]) -> Bool {
        guard let existing = servers[serverName] else { return false }
        return !isManaged(existing)
    }
}
