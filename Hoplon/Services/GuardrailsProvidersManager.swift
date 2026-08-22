import Foundation
import Observation

/// App-scoped state for the Guardrails ▸ Providers settings pane.
///
/// Lives on `GuardrailsManager` rather than in the view: the 5s status poll
/// re-renders the settings column, and view-owned load state gets wiped by it.
///
/// Every mutation returns the server's new snapshot, so `providers` is replaced
/// from the response rather than refetched — the API applies the change to the
/// live registry *and* persists it in one call, so what comes back is what the
/// proxy is actually doing.
@Observable
class GuardrailsProvidersManager {
    var providers: [ProviderConfig] = []
    var isLoading = false
    var lastError: String?
    /// True when the proxy has no management API — it was started without a
    /// config. Not an error: the pane says so instead of showing an empty list.
    var isUnavailable = false

    /// Names with an in-flight mutation, so a row can disable just its own
    /// controls instead of the whole pane freezing.
    var busy: Set<String> = []

    // Copilot device flow.
    var copilot: CopilotLoginStatus?
    /// True when the proxy was started without `--copilot`, so the login routes
    /// answer 404 and the section is hidden rather than shown broken.
    var copilotUnavailable = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Where to reach the admin server. Pushed down by `GuardrailsManager`.
    @ObservationIgnored var adminBase: String = "http://127.0.0.1:8081"

    /// Serializes everything that produces a provider snapshot.
    ///
    /// Every call here returns the server's full list, so two in flight at once
    /// race: a slow `load()` landing after an `add()` would drop the new
    /// provider from the UI, and two mutations completing out of order would
    /// leave the older snapshot on screen. Chaining each operation onto the
    /// previous one makes the last write the newest read, which is the only
    /// ordering that keeps the pane agreeing with the proxy.
    ///
    /// They are short admin-port calls against localhost, so serializing them
    /// costs nothing a user would notice.
    @ObservationIgnored private var queue: Task<Void, Never>?

    /// Run `operation` after every previously queued one has finished.
    private func serialized(_ operation: @escaping () async -> Void) async {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        queue = task
        await task.value
    }

    private var client: GuardrailsClient { GuardrailsClient(base: adminBase) }

    // MARK: - Providers

    func load() async {
        await serialized { [self] in
            isLoading = true
            defer { isLoading = false }
            do {
                providers = try await client.providers()
                isUnavailable = false
                lastError = nil
            } catch GuardrailsClient.ClientError.notConfigured {
                isUnavailable = true
                providers = []
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func setEnabled(_ name: String, _ enabled: Bool) async {
        await mutate(name) { try await self.client.updateProvider(name, enabled: enabled) }
    }

    func setExposeByDefault(_ name: String, _ value: Bool) async {
        await mutate(name) {
            try await self.client.updateProvider(name, exposeByDefault: value)
        }
    }

    func setModelExposed(_ name: String, model: String, exposed: Bool) async {
        await mutate(name) {
            try await self.client.updateProvider(name, models: [model: exposed])
        }
    }

    func add(name: String, baseURL: String, unversioned: Bool) async {
        await mutate(name) {
            try await self.client.addProvider(
                name: name, baseURL: baseURL, unversioned: unversioned
            )
        }
    }

    func remove(_ name: String) async {
        await mutate(name) { try await self.client.removeProvider(name) }
    }

    /// Run a mutation, replacing `providers` with the snapshot it returns.
    ///
    /// A rejected change (the last provider disabled, say) leaves the server's
    /// state untouched and reports why, so the pane cannot drift into showing a
    /// configuration the proxy refused.
    private func mutate(
        _ name: String, _ operation: @escaping () async throws -> [ProviderConfig]
    ) async {
        await serialized { [self] in
            busy.insert(name)
            defer { busy.remove(name) }
            do {
                providers = try await operation()
                lastError = nil
            } catch GuardrailsClient.ClientError.notConfigured {
                isUnavailable = true
            } catch {
                lastError = error.localizedDescription
                // The server refused, so re-read rather than leaving the UI
                // showing the change the user attempted.
                providers = (try? await client.providers()) ?? providers
            }
        }
    }

    // MARK: - Copilot

    func loadCopilot() async {
        do {
            copilot = try await client.copilotStatus()
            copilotUnavailable = false
            if copilot?.state == .pending { startPolling() }
        } catch GuardrailsClient.ClientError.notConfigured {
            copilotUnavailable = true
            copilot = nil
        } catch {
            // A transient read failure should not claim Copilot is unavailable.
            lastError = error.localizedDescription
        }
    }

    func startCopilotLogin() async {
        do {
            copilot = try await client.startCopilotLogin()
            startPolling()
        } catch GuardrailsClient.ClientError.notConfigured {
            copilotUnavailable = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Poll until the device flow resolves.
    ///
    /// The user authorizes in a browser, so the app has nothing to wait on but
    /// the server's own polling. Bounded at 5 minutes — GitHub's device codes
    /// expire well before that, and an unbounded task would outlive the pane.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<100 {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                guard let status = try? await self.client.copilotStatus() else { continue }
                self.copilot = status
                if status.state != .pending { return }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Drop everything from a previous run, so a restart never shows stale
    /// configuration.
    func reset() {
        stopPolling()
        providers = []
        lastError = nil
        isUnavailable = false
        copilot = nil
        copilotUnavailable = false
        busy.removeAll()
    }
}
