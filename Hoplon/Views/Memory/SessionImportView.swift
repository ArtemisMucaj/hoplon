import SwiftUI

/// Import finished assistant sessions (Claude Code / OpenCode / Zed) into
/// long-term memory — the native counterpart of the memory-rs TUI's interactive
/// import screen.
///
/// Left: the discovered-session list with per-row import markers
/// (`[ ]` none · `[…]` queued · `[⟳] importing` · `[✓]` done/already · `[✗]`
/// failed). Right: the highlighted session's full transcript, per turn.
///
/// Imports run in the **server's** background and are tracked by
/// `SessionImportManager` (owned by `MemoryManager`, not this view), so an
/// import keeps progressing after you leave this tab — exactly what the TUI's
/// background worker does.
struct SessionImportView: View {
    @Environment(AppState.self) var state

    @State private var selection: DiscoveredSessionDTO.ID?

    private var manager: SessionImportManager { state.memoryManager.sessionImport }

    private var selectedSession: DiscoveredSessionDTO? {
        guard let selection else { return manager.sessions.first }
        return manager.sessions.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ResizableSplit(leftIdeal: 400, leftMin: 240, rightMin: 300) {
                sessionList
            } right: {
                transcriptPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Fill the section so the view doesn't resize when discovery finishes.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Refresh on appear so a row imported while away shows ✓; resume polling
        // if an import is still in flight.
        .task {
            await manager.discover()
            if manager.hasActiveImports { manager.ensurePolling() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            metric("Found", manager.sessions.count)
            metric("Imported", manager.importedCount)
            if manager.isDiscovering {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("discovering…").font(.caption).foregroundStyle(.secondary)
                }
            } else if manager.hasActiveImports {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("importing…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let result = manager.lastResult {
                Label(result, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                    .lineLimit(1).truncationMode(.tail)
            }
            Button {
                Task { await manager.discover() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(manager.isDiscovering)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 6) {
            Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text("\(value)").font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    // MARK: - Session list

    @ViewBuilder
    private var sessionList: some View {
        if let error = manager.discoverError {
            EmptyStateView(icon: "exclamationmark.triangle", title: "Couldn't discover sessions", message: error)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if manager.sessions.isEmpty && manager.isDiscovering {
            VStack(spacing: 10) {
                ProgressView()
                Text("Discovering sessions…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if manager.sessions.isEmpty {
            EmptyStateView(icon: "tray", title: "No sessions found",
                           message: "No Claude Code, OpenCode, or Zed sessions were found on this machine.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(manager.sessions) { session in
                    SessionRow(session: session, status: manager.status(for: session))
                        .tag(session.id)
                        .contextMenu {
                            importButtons(for: session)
                        }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Transcript pane

    @ViewBuilder
    private var transcriptPane: some View {
        if let session = selectedSession {
            SessionTranscriptPane(session: session) {
                importControls(for: session)
            }
            .id(session.id)
        } else {
            EmptyStateView(icon: "text.bubble", title: "No session selected",
                           message: "Pick a session to preview its transcript.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Import controls

    @ViewBuilder
    private func importControls(for session: DiscoveredSessionDTO) -> some View {
        let status = manager.status(for: session)
        switch status {
        case .queued:
            Label("Queued…", systemImage: "clock").foregroundStyle(.yellow)
        case .importing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Importing…").foregroundStyle(.secondary)
            }
        case .done, .alreadyImported:
            HStack(spacing: 8) {
                Label(status == .done ? "Imported" : "Already imported", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Re-import") { manager.startImport(session, force: true) }
                    .controlSize(.small)
                    .help("Discards the memories this session already wrote, then extracts them again. The one destructive action in the store — everything else only ever appends.")
            }
        case .failed:
            HStack(spacing: 8) {
                Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Button("Retry") { manager.startImport(session, force: true) }
                    .controlSize(.small)
            }
        case nil:
            Button {
                manager.startImport(session)
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func importButtons(for session: DiscoveredSessionDTO) -> some View {
        let status = manager.status(for: session)
        if status == .done || status == .alreadyImported || status == .failed {
            Button("Re-import") { manager.startImport(session, force: true) }
                .help("Discards the memories this session already wrote, then extracts them again. The one destructive action in the store — everything else only ever appends.")
        } else if status == nil {
            Button("Import") { manager.startImport(session) }
        }
    }
}

// MARK: - Session row

/// One list row: status marker, source badge, relative time, token estimate,
/// and title — the same columns the import TUI shows.
private struct SessionRow: View {
    let session: DiscoveredSessionDTO
    let status: SessionImportState?

    var body: some View {
        HStack(spacing: 10) {
            statusMarker
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 8) {
                    Badge(text: session.source, color: sourceColor)
                    Text(SessionFormat.relativeTime(session.updatedAt))
                        .font(.caption2).foregroundStyle(.secondary)
                    if session.approxTokens > 0 {
                        Text(SessionFormat.tokens(session.approxTokens))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.orange)
                    }
                    if session.messageCount > 0 {
                        Text("\(session.messageCount) msg")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusMarker: some View {
        switch status {
        case .alreadyImported, .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .queued:
            Image(systemName: "clock.fill").foregroundStyle(.yellow)
        case .importing:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case nil:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private var sourceColor: Color {
        switch session.source {
        case "claude":   return .purple
        case "opencode": return .green
        case "zed":      return .blue
        default:         return .secondary
        }
    }
}

// MARK: - Transcript pane

/// The highlighted session's full transcript, loaded lazily and rendered per
/// turn (role header + Markdown body), with the import controls pinned above.
private struct SessionTranscriptPane<Controls: View>: View {
    let session: DiscoveredSessionDTO
    @ViewBuilder var controls: Controls

    @Environment(AppState.self) private var state
    @State private var transcript: SessionTranscriptDTO?
    @State private var isLoading = false
    @State private var error: String?

    private var manager: MemoryManager { state.memoryManager }

    var body: some View {
        VStack(spacing: 0) {
            // Title + import controls.
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).font(.headline).lineLimit(2)
                    if let cwd = session.cwd {
                        Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                controls
            }
            .padding(12)
            Divider()
            transcriptBody
        }
        .task(id: session.id) { await load() }
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading transcript…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            EmptyStateView(icon: "exclamationmark.triangle", title: "Couldn't load transcript", message: error)
        } else if let transcript, !transcript.messages.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(transcript.messages) { message in
                        TranscriptTurn(message: message)
                    }
                }
                .padding(16)
            }
        } else {
            EmptyStateView(icon: "text.bubble", title: "Empty transcript", message: "This session has no textual content.")
        }
    }

    private func load() async {
        isLoading = true; error = nil; transcript = nil
        do {
            transcript = try await manager.makeClient()
                .sessionTranscript(source: session.source, id: session.sessionID)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

/// One conversation turn: a coloured role header then the Markdown body.
private struct TranscriptTurn: View {
    let message: SessionMessageDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(roleLabel, systemImage: roleIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(roleColor)
            if message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("(no textual content)").font(.callout).foregroundStyle(.tertiary)
            } else {
                MarkdownText(message.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case "user":      return "User"
        case "assistant": return "Assistant"
        case "system":    return "System"
        case "tool":      return "Tool"
        default:          return message.role.capitalized
        }
    }
    private var roleIcon: String {
        switch message.role {
        case "user":      return "person.fill"
        case "assistant": return "sparkles"
        case "system":    return "gearshape.fill"
        case "tool":      return "wrench.and.screwdriver.fill"
        default:          return "bubble.left.fill"
        }
    }
    private var roleColor: Color {
        switch message.role {
        case "user":      return .cyan
        case "assistant": return .green
        default:          return .orange
        }
    }
}

// MARK: - Formatting

enum SessionFormat {
    /// A compact "N ago" label from a Unix timestamp (seconds).
    static func relativeTime(_ then: Int) -> String {
        let now = Int(Date().timeIntervalSince1970)
        let d = max(0, now - then)
        switch d {
        case ..<60:            return "just now"
        case ..<3600:          return "\(d / 60)m ago"
        case ..<86400:         return "\(d / 3600)h ago"
        case ..<(86400 * 30):  return "\(d / 86400)d ago"
        case ..<(86400 * 365): return "\(d / (86400 * 30))mo ago"
        default:               return "\(d / (86400 * 365))y ago"
        }
    }

    /// Compact token estimate: `~450`, `~1.2k`, `~48k`, `~1.5M`.
    static func tokens(_ n: Int) -> String {
        switch n {
        case 0:              return ""
        case ..<1_000:       return "~\(n)"
        case ..<10_000:      return String(format: "~%.1fk", Double(n) / 1_000)
        case ..<1_000_000:   return "~\(n / 1_000)k"
        default:             return String(format: "~%.1fM", Double(n) / 1_000_000)
        }
    }
}
