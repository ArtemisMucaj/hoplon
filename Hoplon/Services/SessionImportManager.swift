import Foundation
import Observation

/// App-scoped state for the session-import screen.
///
/// Lives on `MemoryManager` (not in the SwiftUI view) so an in-flight import
/// keeps being tracked after the user leaves the Import tab: the **server** runs
/// the import in the background, and this object keeps polling its status until
/// every queued session reaches a terminal state — regardless of whether the
/// view is on screen.
///
/// It mirrors the import TUI's model: a discovered-session list plus a status
/// map keyed by a session's stable `(source, id)` identity, so status survives
/// re-discovery (the list re-sorts newest-first each time).
@Observable
@MainActor
final class SessionImportManager {
    /// Discovered importable sessions, newest first.
    var sessions: [DiscoveredSessionDTO] = []
    /// Import status keyed by `DiscoveredSessionDTO.id` (`source:id`).
    var statuses: [String: SessionImportStatusDTO] = [:]

    var isDiscovering = false
    var discoverError: String?
    /// One-line outcome of the most recent finished import, for a footer note.
    var lastResult: String?

    /// The management-API base is owned by the process manager; captured as a
    /// closure so this object never holds a stale port after a restart.
    @ObservationIgnored private let clientProvider: () -> MemoryClient
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Poll cadence while imports are in flight — brisk enough that a row's
    /// queued → importing → done transitions feel live.
    private let pollInterval: Duration = .milliseconds(1500)

    /// Called once each time a session finishes importing.
    ///
    /// An import is the only thing that changes the store from inside the app,
    /// and the browse tree is cached deliberately (so navigating away and back
    /// does not refetch). Without this the two disagree until something else
    /// forces a reload — which is why a freshly imported session appeared only
    /// after restarting the server.
    @ObservationIgnored var onImportCompleted: (() -> Void)?

    init(clientProvider: @escaping () -> MemoryClient) {
        self.clientProvider = clientProvider
    }

    /// Status for a discovered session (defaults to nil = not tracked yet).
    func status(for session: DiscoveredSessionDTO) -> SessionImportState? {
        statuses[session.id]?.status
    }

    /// Number of sessions already imported or freshly done, for the header.
    var importedCount: Int {
        var n = 0
        for session in sessions {
            let s = statuses[session.id]?.status
            if s == .alreadyImported || s == .done { n += 1 }
        }
        return n
    }

    /// True while any tracked session is queued or importing.
    var hasActiveImports: Bool {
        for entry in statuses.values where entry.status == .queued || entry.status == .importing {
            return true
        }
        return false
    }

    // MARK: - Discovery

    /// Discover importable sessions and refresh the status map. Safe to call on
    /// every appearance; it never disturbs an in-flight import's status.
    func discover() async {
        isDiscovering = true
        discoverError = nil
        let client = clientProvider()
        do {
            async let discovered = client.discoverSessions()
            async let statusList = client.sessionImportStatuses()
            let (found, statusEntries) = try await (discovered, statusList)
            sessions = found
            mergeStatuses(statusEntries)
        } catch {
            discoverError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isDiscovering = false
    }

    // MARK: - Import

    /// Queue a background import of `session`. Optimistically marks the row
    /// `queued`, POSTs the request, and ensures the status poll loop is running
    /// so the row advances to importing → done without the view being present.
    func startImport(_ session: DiscoveredSessionDTO, force: Bool = false) {
        // Don't double-queue an in-flight import.
        if let s = statuses[session.id]?.status, s == .queued || s == .importing { return }

        statuses[session.id] = SessionImportStatusDTO(
            source: session.source, sessionID: session.sessionID, status: .queued, detail: nil
        )
        let client = clientProvider()
        let source = session.source
        let id = session.sessionID
        Task {
            do {
                try await client.importSession(source: source, id: id, force: force)
            } catch {
                // The server never accepted it — reflect the failure locally.
                statuses[session.id] = SessionImportStatusDTO(
                    source: source, sessionID: id, status: .failed,
                    detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
        ensurePolling()
    }

    // MARK: - Polling

    /// Start the status poll loop if it isn't already running. The loop stops on
    /// its own once no import is in flight, so it costs nothing at rest.
    func ensurePolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            // Keep polling as long as work is outstanding. A short grace poll
            // after the last one finishes catches the final terminal update.
            var idleTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: self.pollInterval)
                if Task.isCancelled { return }
                await self.pollStatuses()
                if self.hasActiveImports {
                    idleTicks = 0
                } else {
                    idleTicks += 1
                    if idleTicks >= 1 { break }   // one settling poll, then stop
                }
            }
            self.pollTask = nil
        }
    }

    /// Cancel the poll loop (e.g. when memory stops). Import state is left
    /// intact so a returning user still sees the last-known statuses.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollStatuses() async {
        guard let entries = try? await clientProvider().sessionImportStatuses() else { return }
        mergeStatuses(entries)
        if let latest = entries.first(where: { $0.status == .done && $0.detail != nil }) {
            lastResult = latest.detail
        }
    }

    /// Merge server status entries into the map without regressing a locally
    /// optimistic `queued` that the server hasn't observed yet.
    ///
    /// On a force re-import of an already-`done`/`failed` row we set `.queued`
    /// locally, but a poll can still carry the *prior* terminal status until the
    /// server actually re-queues. Applying it would flip our fresh `.queued`
    /// marker back to `done`/`failed` and make the row look idle. So while local
    /// is `.queued`, an incoming terminal status is skipped; the server's own
    /// `.importing` (it has picked the job up) is applied and, from there,
    /// terminal statuses flow through normally — so a genuinely-finished import
    /// is never stuck.
    private func mergeStatuses(_ entries: [SessionImportStatusDTO]) {
        var completedNow = false
        for entry in entries {
            if statuses[entry.id]?.status == .queued,
               entry.status == .done || entry.status == .failed || entry.status == .alreadyImported {
                continue
            }
            // Fire on the *transition* into `.done`, not on the state. Polling
            // sees `.done` on every tick afterwards, and refreshing the tree
            // every two seconds would undo the point of caching it.
            if entry.status == .done, statuses[entry.id]?.status != .done {
                completedNow = true
            }
            statuses[entry.id] = entry
        }
        if completedNow { onImportCompleted?() }
    }
}
