import Foundation

/// Derives the project name a folder is known by, the way the services do.
///
/// A "project" in memory-rs is a codebase's stable name — normally its git
/// remote's `owner/repo`. Typing that by hand is where this goes wrong: a
/// typo produces a project that matches no memories and no sessions, and the
/// UI has no way to tell that from a legitimately empty one. Picking a folder
/// and deriving the name removes the guess.
///
/// The rule mirrors memory-rs's own `project_from_cwd`, deliberately: the app
/// must derive exactly what memory-rs will stamp on a session imported from
/// that directory, or the assignment silently won't match.
enum GitProject {
    /// The project name for `folder`:
    /// 1. the git remote `owner/repo` (walking up for `.git/config`), else
    /// 2. the folder's own name.
    static func name(for folder: URL) -> String? {
        if let remote = originURL(from: folder), let name = repoName(fromRemote: remote) {
            return name
        }
        let base = folder.standardizedFileURL.lastPathComponent
        return base.isEmpty ? nil : base
    }

    /// Read `remote.origin.url` from the `.git/config` of the repository
    /// containing `start`, walking up parent directories. Parses the file
    /// directly — no `git` binary, so this stays cheap and works regardless of
    /// what is on PATH.
    static func originURL(from start: URL) -> String? {
        var dir = start.standardizedFileURL
        while true {
            let config = dir.appendingPathComponent(".git/config")
            if let contents = try? String(contentsOf: config, encoding: .utf8),
               let url = parseOriginURL(contents) {
                return url
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            // `/`.deletingLastPathComponent() is `/` — the fixpoint that ends the walk.
            if parent == dir { return nil }
            dir = parent
        }
    }

    /// Pull `url = …` out of the `[remote "origin"]` section of a git config.
    /// A minimal INI walk: track the current section header, and inside
    /// `[remote "origin"]` return the first `url` value.
    static func parseOriginURL(_ config: String) -> String? {
        var inOrigin = false
        for rawLine in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line == "[remote \"origin\"]"
                continue
            }
            guard inOrigin, line.hasPrefix("url") else { continue }
            let rest = line.dropFirst("url".count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// `owner/repo` from a remote URL, across the forms git actually emits:
    /// - scp-like SSH: `git@github.com:owner/repo.git`
    /// - HTTPS: `https://github.com/owner/repo.git`
    /// - SSH URL: `ssh://git@github.com/owner/repo.git`
    static func repoName(fromRemote url: String) -> String? {
        var trimmed = url.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        let path: String
        if let range = trimmed.range(of: "://") {
            // scheme://[user@]host/owner/repo(.git) — drop scheme and host.
            let afterScheme = trimmed[range.upperBound...]
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            path = String(afterScheme[afterScheme.index(after: slash)...])
        } else if let colon = trimmed.firstIndex(of: ":") {
            // scp-like git@host:owner/repo(.git)
            path = String(trimmed[trimmed.index(after: colon)...])
        } else {
            path = trimmed
        }

        var segments = path.split(separator: "/").map(String.init)
        guard var repo = segments.popLast() else { return nil }
        if repo.hasSuffix(".git") { repo.removeLast(".git".count) }
        if repo.isEmpty { return nil }
        if let owner = segments.popLast() { return "\(owner)/\(repo)" }
        return repo
    }
}
