import SwiftUI

/// Compact status panel for the `.window`-style MenuBarExtra: one row per
/// service (dot, name, endpoint, toggle), then window/quit actions.
struct MenuBarView: View {
    @Environment(AppState.self) var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            serviceRow(
                icon: AppSection.proxy.systemImage,
                name: "MCP Proxy",
                status: state.proxyStatus,
                detail: state.proxyManager.isRunning ? "port \(state.proxyManager.port)" : nil,
                toggle: {
                    state.proxyManager.isRunning ? state.stopProxy() : state.startProxy()
                }
            )
            serviceRow(
                icon: AppSection.guardrails.systemImage,
                name: "Guardrails",
                status: state.guardrailsStatus,
                detail: state.guardrailsManager.isRunning ? "port \(state.guardrailsManager.listenPort)" : nil,
                toggle: { state.guardrailsEnabled = !state.guardrailsManager.isRunning }
            )
            serviceRow(
                icon: AppSection.memory.systemImage,
                name: "Memory",
                status: state.memoryStatus,
                detail: state.memoryManager.isRunning ? "port \(state.memoryManager.port)" : nil,
                toggle: { state.memoryEnabled = !state.memoryManager.isRunning }
            )

            Divider()

            HStack {
                Button {
                    // openWindow re-creates the window if the user closed it;
                    // iterating NSApp.windows only finds still-visible ones.
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Show Window", systemImage: "macwindow")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    state.stopProxy()
                    state.stopGuardrails()
                    state.stopMemory()
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.borderless)
            }
            .font(.callout)
        }
        .padding(12)
        .frame(width: 300)
    }

    @ViewBuilder
    private func serviceRow(
        icon: String,
        name: String,
        status: ServiceStatus,
        detail: String?,
        toggle: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(status == .stopped ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.medium))
                HStack(spacing: 5) {
                    StatusDot(status: status, size: 7)
                    Text(detail ?? status.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(status == .stopped ? "Start" : "Stop", action: toggle)
                .controlSize(.small)
                .disabled(status.isBusy)
        }
    }
}
