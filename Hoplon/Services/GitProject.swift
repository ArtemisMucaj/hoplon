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
            if let gitDir = resolvedGitDir(at: dir),
               let contents = try? String(contentsOf: gitDir.appendingPathComponent("config"),
                                          encoding: .utf8),
               let url = parseOriginURL(contents) {
                return url
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            // `/`.deletingLastPathComponent() is `/` — the fixpoint that ends the walk.
            if parent == dir { return nil }
            dir = parent
        }
    }

    /// The directory holding `config` for the repository rooted at `dir`, or nil
    /// if `dir` is not a repository root.
    ///
    /// `.git` is usually a directory, but in a **linked worktree or submodule**
    /// it is a file containing `gitdir: <path>`. Following that matters here:
    /// without it the walk skips the real repository, keeps climbing, and either
    /// finds the *parent* repo's remote or falls back to the folder name — a
    /// silently wrong project name, which is the failure this whole picker
    /// exists to avoid.
    ///
    /// A linked worktree's gitdir holds per-worktree state and points at the
    /// shared repository via `commondir`; `config` lives there, so resolve it.
    private static func resolvedGitDir(at dir: URL) -> URL? {
        let dotGit = dir.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return dotGit }

        // A pointer file: `gitdir: /abs/path` or a path relative to `dir`.
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let gitDir = target.hasPrefix("/")
            ? URL(fileURLWithPath: target)
            : dir.appendingPathComponent(target).standardizedFileURL

        // In a linked worktree the config lives in the shared repo `commondir`
        // points at; in a submodule the gitdir itself holds it.
        if let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"),
                                    encoding: .utf8) {
            let trimmed = common.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed.hasPrefix("/")
                    ? URL(fileURLWithPath: trimmed)
                    : gitDir.appendingPathComponent(trimmed).standardizedFileURL
            }
        }
        return gitDir
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
