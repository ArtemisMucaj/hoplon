import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Getting finished assistant sessions into long-term memory.
///
/// Two paths, because memory-rs owns session discovery but only exposes it
/// through the dream harvest, not as a REST endpoint:
///
/// - **Run a dream cycle** — the bulk path. Server-side it discovers every
///   finished session (Claude Code, OpenCode, Zed), imports the new ones, then
///   consolidates the store.
/// - **Import a transcript** — the precise path, for one file you point at.
///
/// Below both, the sessions the server has already recorded, including failed
/// attempts (memory-rs records those so the harvest stops retrying them).
struct SessionImportView: View {
    @Environment(AppState.self) var state

    private var manager: MemoryManager { state.memoryManager }
    private var importer: SessionImportManager { state.memoryManager.sessionImport }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                dreamSection
                fileSection
                sessionsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { importer.loadSessions() }
        .navigationTitle("Import")
    }

    // MARK: - Dream

    @ViewBuilder
    private var dreamSection: some View {
        @Bindable var importer = importer
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Harvest finished sessions")
            CardContainer {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "moon.stars.fill")
                            .foregroundStyle(.purple)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Dream cycle").font(.callout.weight(.medium))
                            Text("Finds every session idle for at least the interval below, imports the ones memory hasn't seen, then consolidates what it learned. Each new session costs an LLM call, so a first run over a backlog takes a while.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Text("Idle for at least").font(.caption)
                                Stepper(value: $importer.idleMinutes, in: 5...1440, step: 5) {
                                    Text("\(importer.idleMinutes) min")
                                        .font(.caption.monospacedDigit())
                                        .frame(minWidth: 56, alignment: .leading)
                                }
                                .fixedSize()
                            }
                            .padding(.top, 2)
                        }
                        Spacer()
                        Button {
                            importer.runDream()
                        } label: {
                            if importer.isDreaming {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Dreaming…")
                                }
                            } else {
                                Label("Run Dream", systemImage: "play.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(importer.isBusy)
                    }
                    .padding(12)

                    if let report = importer.lastDream {
                        Divider()
                        dreamReport(report)
                    }
                    if let error = importer.dreamError {
                        Divider()
                        errorRow(error)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dreamReport(_ report: MemoryDreamResponse) -> some View {
        HStack(spacing: 18) {
            reportStat("Eligible", report.sessionsEligible, .secondary)
            reportStat("Imported", report.sessionsImported, .green)
            reportStat("Failed", report.sessionsFailed, report.sessionsFailed > 0 ? .red : .secondary)
            reportStat("Clusters", report.clustersFound, .indigo)
            reportStat("Applied", report.operationsApplied, .cyan)
            reportStat("Skipped", report.operationsSkipped, .secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func reportStat(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
            Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Single file

    @ViewBuilder
    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Import one transcript")
            CardContainer {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.cyan)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pick a session log").font(.callout.weight(.medium))
                            Text("A Claude Code transcript (~/.claude/projects/<project>/<id>.jsonl) or any JSONL chat log with one {\"role\", \"content\"} object per line.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button {
                            pickTranscript()
                        } label: {
                            if importer.importingPath != nil {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Importing…")
                                }
                            } else {
                                Label("Choose File…", systemImage: "folder")
                            }
                        }
                        .disabled(importer.isBusy)
                    }
                    .padding(12)

                    if let result = importer.lastImport {
                        Divider()
                        importResult(result)
                    }
                    if let error = importer.importError {
                        Divider()
                        errorRow(error)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func importResult(_ result: MemoryImportResponse) -> some View {
        HStack(spacing: 10) {
            if result.imported {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Imported \(result.messageCount ?? 0) message\((result.messageCount ?? 0) == 1 ? "" : "s")")
                        .font(.callout)
                    Text("\(result.operationsApplied ?? 0) memory operation\((result.operationsApplied ?? 0) == 1 ? "" : "s") applied, \(result.operationsSkipped ?? 0) skipped")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Already imported").font(.callout)
                    Text("This session is already in memory. Re-import it to overwrite what was extracted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let path = importer.lastImportPath {
                    Button("Re-import") { importer.importFile(at: path, force: true) }
                        .buttonStyle(.borderless)
                        .disabled(importer.isBusy)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: - Imported sessions

    @ViewBuilder
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Imported sessions") {
                Button { importer.loadSessions() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(importer.isLoadingSessions)
            }

            if let error = importer.sessionsError {
                CardContainer { errorRow(error) }
            } else if importer.sessions.isEmpty {
                CardContainer {
                    HStack(spacing: 8) {
                        if importer.isLoadingSessions {
                            ProgressView().controlSize(.small)
                            Text("Loading…").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("Nothing imported yet — run a dream cycle to harvest finished sessions.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                }
            } else {
                CardContainer {
                    VStack(spacing: 0) {
                        ForEach(Array(importer.sessions.enumerated()), id: \.element.id) { idx, session in
                            sessionRow(session)
                            if idx < importer.sessions.count - 1 { Divider() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: MemorySession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.didFail ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(session.didFail ? .red : .green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.id)
                        .font(.callout.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                    if let source = session.source { Badge(text: source, color: .cyan) }
                }
                HStack(spacing: 8) {
                    if let date = session.importedDate {
                        Text(date.formatted(.relative(presentation: .named)))
                    }
                    if let messages = session.messageCount {
                        Text("· \(messages) message\(messages == 1 ? "" : "s")")
                    }
                    if let written = session.itemsWritten {
                        Text("· \(written) memor\(written == 1 ? "y" : "ies")")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                // A failure is the whole reason this row is interesting — show why.
                if let error = session.lastError, session.didFail {
                    Text(error)
                        .font(.caption).foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func pickTranscript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Session logs are JSONL; the system has no UTType for that, so accept
        // any file and let the server reject what it can't parse.
        panel.allowedContentTypes = [.data]
        panel.showsHiddenFiles = true
        panel.message = "Select a session transcript (JSONL)"
        panel.prompt = "Import"
        // Start where Claude Code keeps its transcripts, which is hidden.
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        if panel.runModal() == .OK, let url = panel.url {
            importer.importFile(at: url.path)
        }
    }
}
