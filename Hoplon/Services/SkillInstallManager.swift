import Foundation
import CryptoKit

/// Installs the agent skills that document memory-rs and codesearch into
/// `~/.claude/skills`, from copies vendored into the app bundle at build time.
///
/// Why the app ships them: a skill is the *documentation half* of a service Hoplon
/// already supervises — the app knows which release is bundled, so it can install
/// the matching skill text and offer an update when the bundle moves on. The files
/// come from each service's repo at its pinned release commit
/// (`scripts/lib/fetch_skills.sh`), so installing needs no network.
///
/// **One variant per service, never both.** Each service publishes an `-mcp` and a
/// `-cli` skill covering the same capability through different surfaces. Both
/// installed at once is a trap: the agent gets two overlapping playbooks for one
/// service and picks per-invocation, so it will reach for `codesearch index` in a
/// session where only the MCP tools exist (or vice versa). Selecting one variant
/// therefore removes the other.
///
/// Only ever touches directories it created, marked with `InstalledSkillMarker` —
/// the same rule `ProxyRegistration` follows for `servers.json`. A hand-authored
/// skill of the same name is left alone and reported, rather than silently
/// overwritten.
@MainActor
@Observable
final class SkillInstallManager {
    /// A service's pair of skills. `AppSection` ties the row to the service it
    /// documents, so the UI can label it the same way the sidebar does.
    struct Family: Identifiable {
        let section: AppSection
        /// Skill (directory) name per variant.
        let names: [SkillVariant: String]
        /// The command the `-cli` skill tells the agent to run — so the UI can
        /// point out that the CLI skill is useless without the symlink from the
        /// section above it.
        let cliCommand: String

        var id: String { section.rawValue }
        var title: String { section.label }
        func name(for variant: SkillVariant) -> String { names[variant] ?? "" }
    }

    enum SkillVariant: String, CaseIterable, Identifiable, Hashable {
        case mcp, cli
        var id: String { rawValue }
        var title: String { self == .mcp ? "MCP" : "CLI" }
        var other: SkillVariant { self == .mcp ? .cli : .mcp }
        /// What the variant assumes is available, for the picker's help text.
        var blurb: String {
            switch self {
            case .mcp: return "Drives the service over MCP — needs it running and reachable by the agent."
            case .cli: return "Drives the bundled command-line binary — needs the CLI symlink installed."
            }
        }
    }

    static let families: [Family] = [
        Family(section: .memory,
               names: [.mcp: "memory-rs-mcp", .cli: "memory-rs-cli"],
               cliCommand: "memory-rs"),
        Family(section: .code,
               names: [.mcp: "codesearch-mcp", .cli: "codesearch-cli"],
               cliCommand: "codesearch"),
    ]

    enum SkillState: Equatable {
        case absent
        /// Installed by us. `upToDate` compares what we wrote against what the
        /// bundle now carries.
        case managed(marker: InstalledSkillMarker, upToDate: Bool)
        /// A directory of that name exists without our marker — the user's own
        /// skill, or one another tool installed. Never touched.
        case foreign(reason: String)
    }

    /// Per-skill-name state, recomputed by `refresh()`.
    private(set) var states: [String: SkillState] = [:]

    /// Skills vendored into this build, keyed by name. Empty if the bundle was
    /// built without running the fetch scripts.
    private(set) var bundled: [String: BundledSkill] = [:]

    /// Last install/remove error, for display.
    private(set) var lastError: String?

    /// `~/.claude/skills` — Claude Code's per-user skill directory.
    var skillsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills", isDirectory: true)
    }

    var skillsDirectoryPath: String { skillsDirectory.path }

    private let markerFilename = ".hoplon-skill.json"

    init() {
        loadManifest()
    }

    // MARK: - Bundle

    /// Read the vendored manifest. The payload each entry names is hashed on
    /// demand rather than trusted, so a truncated or edited resource can't be
    /// installed while claiming the release's provenance.
    private func loadManifest() {
        guard let url = Bundle.main.url(forResource: "skills-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(SkillsManifest.self, from: data)
        else {
            bundled = [:]
            return
        }
        bundled = manifest.skills
    }

    private func payloadURL(for skill: BundledSkill) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent(skill.file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The bundled skill for a family+variant, if this build has it.
    func bundledSkill(_ family: Family, _ variant: SkillVariant) -> BundledSkill? {
        bundled[family.name(for: variant)]
    }

    /// Whether anything is installable at all — false when the fetch scripts
    /// never ran for this build.
    var hasBundledSkills: Bool { !bundled.isEmpty }

    // MARK: - Queries

    private func skillDirectory(_ name: String) -> URL {
        skillsDirectory.appendingPathComponent(name, isDirectory: true)
    }

    /// Recompute every skill's state. Cheap; call on appear.
    func refresh() {
        var next: [String: SkillState] = [:]
        for family in Self.families {
            for variant in SkillVariant.allCases {
                let name = family.name(for: variant)
                guard !name.isEmpty else { continue }
                next[name] = computeState(name: name)
            }
        }
        states = next
    }

    private func computeState(name: String) -> SkillState {
        let fm = FileManager.default
        let dir = skillDirectory(name)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir) else { return .absent }
        guard isDir.boolValue else {
            return .foreign(reason: "A file (not a directory) exists at \(dir.path).")
        }

        let markerURL = dir.appendingPathComponent(markerFilename)
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? Self.decoder.decode(InstalledSkillMarker.self, from: data),
              marker.skill == name
        else {
            return .foreign(reason: "\(dir.path) already exists and wasn't installed by Hoplon.")
        }

        // Out of date when the bundle carries different text than we wrote —
        // either the app updated, or someone edited the installed copy.
        let current = bundled[name]?.sha256
        return .managed(marker: marker, upToDate: current == nil || current == marker.sha256)
    }

    /// State for one family+variant, defaulting to absent before the first refresh.
    func state(_ family: Family, _ variant: SkillVariant) -> SkillState {
        states[family.name(for: variant)] ?? .absent
    }

    /// The variant this service currently has installed *by us*, if any.
    func installedVariant(_ family: Family) -> SkillVariant? {
        SkillVariant.allCases.first { variant in
            if case .managed = state(family, variant) { return true }
            return false
        }
    }

    /// Skill names in this family that exist but aren't ours, for the UI's notice.
    func foreignNames(_ family: Family) -> [String] {
        SkillVariant.allCases.compactMap { variant -> String? in
            if case .foreign = state(family, variant) { return family.name(for: variant) }
            return nil
        }
    }

    // MARK: - Mutations

    /// Install (or update) one variant for a service, and remove the other one so
    /// the agent is never holding two playbooks for the same service.
    ///
    /// Returns true on success.
    @discardableResult
    func install(_ family: Family, variant: SkillVariant) -> Bool {
        lastError = nil
        let fm = FileManager.default
        let name = family.name(for: variant)

        guard let skill = bundled[name], let payload = payloadURL(for: skill) else {
            lastError = "This build of Hoplon doesn't bundle \(name). Run scripts/fetch_binaries.sh and rebuild."
            return false
        }

        guard let data = try? Data(contentsOf: payload) else {
            lastError = "Couldn't read the bundled \(name) skill."
            return false
        }

        // The manifest's hash is from fetch time; verify the resource still
        // matches it rather than installing whatever happens to be in the bundle.
        let actual = Self.sha256(data)
        guard actual == skill.sha256 else {
            lastError = "The bundled \(name) skill doesn't match its manifest checksum — the app bundle looks damaged. Reinstall Hoplon."
            return false
        }

        // Never write into a directory we didn't create.
        if case .foreign(let reason) = computeState(name: name) {
            lastError = "\(reason) Hoplon won't overwrite it — move or delete it first."
            return false
        }

        let dir = skillDirectory(name)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("SKILL.md"), options: .atomic)
            let marker = InstalledSkillMarker(
                skill: name,
                variant: variant.rawValue,
                repo: skill.repo,
                tag: skill.tag,
                commit: skill.commit,
                sha256: actual,
                installedAt: Date()
            )
            let encoded = try Self.encoder.encode(marker)
            try encoded.write(to: dir.appendingPathComponent(markerFilename), options: .atomic)
        } catch {
            lastError = "Couldn't install \(name): \(error.localizedDescription)"
            refresh()
            return false
        }

        // Mutual exclusion. Only removes the sibling if we own it — a
        // hand-authored one of that name stays, and the UI reports it.
        let sibling = family.name(for: variant.other)
        if case .managed = computeState(name: sibling) {
            removeSkill(named: sibling)
        }

        refresh()
        return true
    }

    /// Remove whichever variant of a service we installed. Returns true on
    /// success (including when nothing of ours was there).
    @discardableResult
    func remove(_ family: Family) -> Bool {
        lastError = nil
        var ok = true
        for variant in SkillVariant.allCases {
            let name = family.name(for: variant)
            if case .managed = computeState(name: name) {
                ok = removeSkill(named: name) && ok
            }
        }
        refresh()
        return ok
    }

    /// Delete the two files we wrote, then the directory if that left it empty.
    /// A directory the user has since added files to (their own `references/`,
    /// say) is kept, so removal never takes their work with it.
    @discardableResult
    private func removeSkill(named name: String) -> Bool {
        let fm = FileManager.default
        let dir = skillDirectory(name)
        do {
            try? fm.removeItem(at: dir.appendingPathComponent("SKILL.md"))
            try? fm.removeItem(at: dir.appendingPathComponent(markerFilename))
            let leftovers = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if leftovers.isEmpty {
                try fm.removeItem(at: dir)
            } else {
                lastError = "Removed the \(name) skill, but kept \(dir.path) — it has other files in it."
            }
        } catch {
            lastError = "Couldn't remove \(name): \(error.localizedDescription)"
            return false
        }
        return true
    }

    // MARK: - Helpers

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
