import Foundation

// Mirrors servers.json — the standard MCP config format,
// extended with an optional `enabled` field managed by this app.
struct ServersConfig: Codable {
    var mcpServers: [String: MCPServer]
}

struct MCPServer: Codable, Equatable {
    // stdio transport
    var command: String?
    var args: [String]?
    var env: [String: String]?

    // http transport
    var url: String?
    // Authorization (and other) headers sent on every request to a remote
    // HTTP/SSE server. Standard MCP field. Declared here so the app
    // round-trips it instead of silently dropping it when re-encoding the
    // config on save — JSONDecoder discards keys the struct doesn't model.
    var headers: [String: String]?

    // shared
    var transport: String?
    var auth: String?

    // standard MCP field — a short description of what this server is for.
    // Panoply surfaces it through the `load_tools` overview so agents know
    // which provider to search. Declared here so the app round-trips it
    // instead of dropping it when re-encoding the config on save.
    var description: String?

    // non-standard: managed by Hoplon, stripped before panoply reads it
    var enabled: Bool?
    var disabledTools: [String]? = nil

    var isOAuth: Bool { auth == "oauth" }
    var isHTTP: Bool { url != nil }

    var displayType: String {
        if let url { return url }
        if let command {
            let args = args?.joined(separator: " ") ?? ""
            return "\(command) \(args)".trimmingCharacters(in: .whitespaces)
        }
        return "unknown"
    }
}