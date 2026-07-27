import Foundation

// DTOs for memory-rs's session discovery + background import endpoints
// (`/api/sessions/discover`, `/api/sessions/transcript`, `/api/sessions/import`).
//
// These are the *importable* sessions found on disk — distinct from
// `MemorySession` in MemoryModels.swift, which is a session already recorded in
// the store.

extension KeyedDecodingContainer {
    /// Decode a value if present and well-typed, falling back to `defaultValue`
    /// otherwise — the lenient-decode idiom used throughout these models. (For
    /// optional fields we keep plain `try?` so a missing key stays `nil`.)
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key, or defaultValue: T) -> T {
        (try? decode(type, forKey: key)) ?? defaultValue
    }
}

/// One importable session discovered by `GET /api/sessions/discover` — a
/// finished Claude Code / OpenCode / Zed conversation on this machine, shown
/// before any expensive parse of its body (mirrors the import TUI's list row).
nonisolated struct DiscoveredSessionDTO: Codable, Equatable, Identifiable {
    var source: String          // "claude" | "opencode" | "zed"
    var sessionID: String
    var title: String
    var cwd: String?
    var updatedAt: Int
    var messageCount: Int
    var approxTokens: Int
    var tailPreview: String

    /// Stable identity across re-discovery: source + id (the server keys import
    /// status the same way).
    var id: String { "\(source):\(sessionID)" }

    enum CodingKeys: String, CodingKey {
        case source, title, cwd
        case sessionID = "id"
        case updatedAt = "updated_at"
        case messageCount = "message_count"
        case approxTokens = "approx_tokens"
        case tailPreview = "tail_preview"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source       = c.lenient(String.self, .source, or: "")
        sessionID    = c.lenient(String.self, .sessionID, or: "")
        title        = c.lenient(String.self, .title, or: "(untitled session)")
        cwd          = try? c.decode(String.self, forKey: .cwd)
        updatedAt    = c.lenient(Int.self, .updatedAt, or: 0)
        messageCount = c.lenient(Int.self, .messageCount, or: 0)
        approxTokens = c.lenient(Int.self, .approxTokens, or: 0)
        tailPreview  = c.lenient(String.self, .tailPreview, or: "")
    }
}

nonisolated struct DiscoveredSessionsResponse: Codable {
    var count: Int
    var sessions: [DiscoveredSessionDTO]
}

/// Import lifecycle of one session, mirroring the server's `ImportStatus`
/// (and the import TUI's per-row markers).
nonisolated enum SessionImportState: String, Codable, Equatable {
    case alreadyImported = "already_imported"
    case queued
    case importing
    case done
    case failed

    /// Decode leniently so an unknown future state doesn't drop the row.
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = SessionImportState(rawValue: raw) ?? .failed
    }
}

/// One entry in `GET /api/sessions/import`: a session's current import state
/// plus a terminal detail (summary on done, error on failed).
nonisolated struct SessionImportStatusDTO: Codable, Equatable, Identifiable {
    var source: String
    var sessionID: String
    var status: SessionImportState
    var detail: String?

    var id: String { "\(source):\(sessionID)" }

    enum CodingKeys: String, CodingKey {
        case source, status, detail
        case sessionID = "id"
    }

    init(source: String, sessionID: String, status: SessionImportState, detail: String?) {
        self.source = source
        self.sessionID = sessionID
        self.status = status
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source    = c.lenient(String.self, .source, or: "")
        sessionID = c.lenient(String.self, .sessionID, or: "")
        status    = (try? c.decode(SessionImportState.self, forKey: .status)) ?? .failed
        detail    = try? c.decode(String.self, forKey: .detail)
    }
}

nonisolated struct SessionImportStatusResponse: Codable {
    var count: Int
    var statuses: [SessionImportStatusDTO]
}

/// One message of a session transcript (`GET /api/sessions/transcript`).
nonisolated struct SessionMessageDTO: Codable, Equatable, Identifiable {
    var role: String
    var content: String
    var timestamp: String?

    /// Positional identity assigned by the transcript decoder (messages aren't
    /// uniquely keyed server-side).
    var id = UUID()

    enum CodingKeys: String, CodingKey { case role, content, timestamp }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role      = c.lenient(String.self, .role, or: "")
        content   = c.lenient(String.self, .content, or: "")
        timestamp = try? c.decode(String.self, forKey: .timestamp)
    }
}

nonisolated struct SessionTranscriptDTO: Codable, Equatable {
    var id: String
    var source: String
    var project: String?
    var messageCount: Int
    var messages: [SessionMessageDTO]

    enum CodingKeys: String, CodingKey {
        case id, source, project, messages
        case messageCount = "message_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = c.lenient(String.self, .id, or: "")
        source       = c.lenient(String.self, .source, or: "")
        project      = try? c.decode(String.self, forKey: .project)
        messageCount = c.lenient(Int.self, .messageCount, or: 0)
        messages     = c.lenient([SessionMessageDTO].self, .messages, or: [])
    }
}

/// Body for `POST /api/sessions/import`.
nonisolated struct SessionImportRequest: Codable {
    var source: String
    var id: String
    var force: Bool = false
}
