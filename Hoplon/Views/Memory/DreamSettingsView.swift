import SwiftUI

/// Dream (memory consolidation) settings for the running memory server.
///
/// "Dreaming" harvests finished sessions into long-term memory and periodically
/// consolidates the store. These settings live in the server's config.json and
/// are edited here through the management API (`GET /api/dream`,
/// `PUT /api/dream/config`); a change is persisted and applied to the running
/// scheduler live — no restart.
struct DreamSettingsView: View {
    @Environment(AppState.self) var state

    @State private var status: DreamStatus?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var savedNote: String?
    @State private var isTriggering = false
    @State private var saveTask: Task<Void, Never>?
    /// True while a debounced edit is queued but not yet written, so it can be
    /// flushed (not dropped) if the view disappears mid-debounce.
    @State private var pendingSave = false

    // Live-edited values, seeded from `status` on load.
    @State private var dreamEnabled = true
    @State private var autoImport = true
    @State private var intervalHours = 4
    @State private var idleMinutes = 60

    private var manager: MemoryManager { state.memoryManager }

    var body: some View {
        Group {
            if let loadError {
                EmptyStateView(icon: "moon.zzz", title: "Dreaming unavailable", message: loadError)
            } else if status == nil && isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading dream settings…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
        .task { await load() }
        // Flush a pending debounced edit instead of dropping it: cancel the
        // timer, and if a change was still queued, persist it now.
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
            if pendingSave { pendingSave = false; Task { await save() } }
        }
    }

    private var form: some View {
        // Settings apply live: each control change persists immediately (the
        // server accepts partial updates and applies them on the next cycle).
        Form {
            Section {
                Toggle("Enable scheduled dreaming", isOn: $dreamEnabled)
                if dreamEnabled {
                    Stepper(value: $intervalHours, in: 1...168) {
                        LabeledContent("Dream every", value: "\(intervalHours) h")
                    }
                }
            } header: {
                Text("Consolidation")
            } footer: {
                Text("Periodically consolidates the memory store, merging and pruning related items.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Auto-import finished sessions", isOn: $autoImport)
                Stepper(value: $idleMinutes, in: 1...1440) {
                    LabeledContent("Idle threshold", value: "\(idleMinutes) min")
                }
            } header: {
                Text("Auto-import")
            } footer: {
                Text("Between dreams, automatically import sessions once idle (each import spends LLM extraction calls). A session must be inactive for the idle threshold before it counts as finished.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button {
                        Task { await triggerNow() }
                    } label: {
                        Label("Dream now", systemImage: "moon.stars.fill")
                    }
                    .disabled(isTriggering || status?.running == true)
                    if isTriggering || status?.running == true {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("A dream cycle is running…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    // Live-apply status, inline (no separate Apply button/bar).
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red).lineLimit(1)
                    } else if savedNote != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            } header: {
                Text("Run now")
            } footer: {
                Text("Runs one consolidation cycle in the background immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Persist on any change. The steppers/toggles update the @State first;
        // these fire after, sending the current values as a partial update.
        .onChange(of: dreamEnabled) { _, _ in applyLive() }
        .onChange(of: autoImport) { _, _ in applyLive() }
        .onChange(of: intervalHours) { _, _ in applyLive() }
        .onChange(of: idleMinutes) { _, _ in applyLive() }
    }

    /// Debounced live-apply: coalesces rapid stepper taps into one write.
    private func applyLive() {
        // Skip while the initial load is seeding the drafts (avoids a redundant
        // write of the values we just read back).
        guard status != nil, !isLoading else { return }
        pendingSave = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            pendingSave = false
            await save()
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true; loadError = nil
        do {
            let s = try await manager.makeClient().dreamStatus()
            status = s
            dreamEnabled = s.enabled
            autoImport = s.autoImport
            intervalHours = s.intervalHours
            idleMinutes = s.sessionIdleMinutes
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true; saveError = nil; savedNote = nil
        let request = DreamConfigRequest(
            dreamEnabled: dreamEnabled,
            dreamIntervalHours: intervalHours,
            sessionIdleMinutes: idleMinutes,
            autoImport: autoImport
        )
        do {
            let merged = try await manager.makeClient().updateDreamConfig(request)
            // Refresh the baseline so the UI reflects the server's canonical values.
            dreamEnabled = merged.dreamEnabled
            autoImport = merged.autoImport
            intervalHours = merged.dreamIntervalHours
            idleMinutes = merged.sessionIdleMinutes
            await load()
            savedNote = "Applied — takes effect on the next cycle."
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isSaving = false
    }

    private func triggerNow() async {
        isTriggering = true; saveError = nil
        do {
            try await manager.makeClient().triggerDream()
            await load()
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isTriggering = false
    }
}
