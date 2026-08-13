import Foundation

/// One skill vendored into the app bundle, as recorded by
/// `scripts/lib/fetch_skills.sh` in `Resources/skills-manifest.json`.
///
/// The provenance fields are the point: a skill documents a binary, so the UI
/// can say *which* release's skill is installed and whether it still matches the
/// bundled one.
nonisolated struct BundledSkill: Codable, Equatable, Identifiable {
    /// Upstream skill (and installed directory) name, e.g. `codesearch-mcp`.
    let name: String
    /// Flat filename under the bundle's Resources, e.g. `skill-codesearch-mcp.md`.
    let file: String
    /// `owner/repo` the skill came from.
    let repo: String
    /// Release tag the skill was vendored at — or `local` for a checkout build.
    let tag: String
    /// Commit the tag pointed at when it was vendored.
    let commit: String
    /// SHA-256 of the vendored file, recorded at fetch time.
    let sha256: String

    var id: String { name }

    /// Short commit, for display beside the tag.
    var shortCommit: String { String(commit.prefix(7)) }

    /// `v2.2.0 · 88b6231`, or `local checkout · 88b6231` for a checkout build.
    var provenance: String {
        tag == "local" ? "local checkout · \(shortCommit)" : "\(tag) · \(shortCommit)"
    }
}

nonisolated struct SkillsManifest: Codable {
    let skills: [String: BundledSkill]
}

/// Written into an installed skill's directory so the app can tell its own
/// installs from a hand-authored skill of the same name — the same "only ever
/// touch what we created" rule `ProxyRegistration` follows for `servers.json`.
///
/// Also carries the provenance of what was installed, which is what lets the UI
/// offer an update when the bundled skill has moved on.
nonisolated struct InstalledSkillMarker: Codable, Equatable {
    let skill: String
    let variant: String
    let repo: String
    let tag: String
    let commit: String
    let sha256: String
    let installedAt: Date
}
