import Foundation
import Observation

/// App-scoped state for LLM feature explanations, keyed by feature id.
///
/// Lives on `CodesearchManager` (not in the SwiftUI view) so an in-flight
/// explanation keeps streaming after the user leaves the Overview tab — the
/// consuming task is owned here, and the accumulated text is waiting when the
/// user comes back. Same reasoning as `SessionImportManager`.
@Observable
@MainActor
final class FeatureExplainManager {
    /// One explanation's lifecycle. Streamed tokens accumulate in `text`
    /// during `.running`, so views can render the answer as it arrives.
    enum Phase: Equatable {
        case running
        case done
        case failed(String)
    }

    struct ExplainState: Equatable {
        var phase: Phase
        var text: String
    }

    private(set) var states: [String: ExplainState] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let clientProvider: () -> CodesearchClient

    init(clientProvider: @escaping () -> CodesearchClient) {
        self.clientProvider = clientProvider
    }

    func state(for featureId: String) -> ExplainState? { states[featureId] }

    /// Whether any explanation is currently streaming (drives the row spinner).
    func isRunning(_ featureId: String) -> Bool {
        states[featureId]?.phase == .running
    }

    /// Start (or, after a failure, restart) an explanation of `symbol`.
    /// No-op while one is already streaming for this feature. `regenerate`
    /// bypasses the server-side cache and recomputes (Regenerate button).
    func explain(featureId: String, symbol: String, repository: String?, regenerate: Bool = false) {
        if states[featureId]?.phase == .running { return }
        states[featureId] = ExplainState(phase: .running, text: "")
        tasks[featureId]?.cancel()
        tasks[featureId] = Task { [weak self] in
            guard let self else { return }
            var options = ExplainStreamRequest()
            options.repository = repository
            options.regenerate = regenerate
            do {
                for try await event in self.clientProvider()
                    .explainStream(symbol: symbol, options: options)
                {
                    switch event {
                    case .token(let text):
                        self.states[featureId]?.text += text
                    case .doneOk(let done):
                        // Some outcomes arrive only in the terminal frame with
                        // no token stream (e.g. "no callers or callees") —
                        // surface them instead of finishing with a blank card.
                        if self.states[featureId]?.text.isEmpty ?? true, !done.explanation.isEmpty {
                            self.states[featureId]?.text = done.explanation
                        }
                        self.states[featureId]?.phase = .done
                    case .doneAmbiguous(let candidates):
                        self.states[featureId]?.phase =
                            .failed("Symbol matched \(candidates.count) candidates — expected the exact entry point.")
                    case .failed(let message):
                        self.states[featureId]?.phase = .failed(message)
                    }
                }
                // Stream closed without a terminal frame: keep partial text as
                // a result rather than throwing it away.
                if self.states[featureId]?.phase == .running {
                    self.states[featureId]?.phase = (self.states[featureId]?.text.isEmpty ?? true)
                        ? .failed("The explanation stream ended unexpectedly.")
                        : .done
                }
            } catch {
                if !Task.isCancelled {
                    self.states[featureId]?.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Cancel (if streaming) and clear one feature's explanation.
    func dismiss(featureId: String) {
        tasks[featureId]?.cancel()
        tasks[featureId] = nil
        states[featureId] = nil
    }

    /// Drop everything — the serve process is gone, so in-flight streams are
    /// dead and cached texts may describe a stale index.
    func reset() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        states.removeAll()
    }
}
