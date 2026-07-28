import SwiftUI
import AppKit

/// Detail column for the Memory section.
///
/// memory-rs is an agent tool (MCP + REST), so the native surface focuses on
/// what a human actually drives: browsing the memory virtual filesystem,
/// importing finished sessions into it, and grouping projects into namespaces.
/// With no sub-tab selected it shows an overview landing (stats + namespaces).
struct MemoryDetailView: View {
    @Environment(AppState.self) var state
    @Environment(NavigationModel.self) var nav

    private var manager: MemoryManager { state.memoryManager }

    var body: some View {
        Group {
            if manager.isRunning {
                VStack(spacing: 0) {
                    // Shared running header — identical to Proxy & Guardrails.
                    ServiceHeader(
                        systemImage: AppSection.memory.systemImage,
                        status: state.memoryStatus,
                        subtitle: "API \(manager.apiBase)  ·  MCP \(manager.mcpEndpoint)"
                    ) {
                        Button { manager.refresh() } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) {
                            state.memoryEnabled = false
                        } label: {
                            Label("Stop", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.glassProminent).tint(.red)
                    }
                    Divider()

                    // The sidebar picks the sub-tab; nil shows the overview.
                    // Stable .id per tab so the 5s status poll re-rendering this
                    // view doesn't re-create the tab (which would wipe its state
                    // and restart in-flight loads).
                    Group {
                        if let ns = nav.selectedMemoryNamespace {
                            NamespaceDetailView(namespace: ns)
                                .id("memory.namespace.\(ns)")
                        } else {
                            switch nav.selectedMemoryTab {
                            case .browse:   MemoryBrowseView().id("memory.browse")
                            case .sessions: SessionImportView().id("memory.import")
                            case nil:       MemoryOverviewView().id("memory.overview")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                stoppedState
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if manager.isRunning {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(manager.mcpEndpoint, forType: .string)
                    } label: {
                        Label("Copy MCP Endpoint", systemImage: "doc.on.doc")
                    }
                    .help(manager.mcpEndpoint)
                }
            }
        }
    }

    @ViewBuilder
    private var stoppedState: some View {
        if manager.isStarting {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Starting memory…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = manager.lastError {
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Could not start Memory",
                message: error,
                actionTitle: "Try Again",
                action: { state.memoryEnabled = true }
            )
        } else {
            EmptyStateView(
                icon: AppSection.memory.systemImage,
                title: "Memory is stopped",
                message: "Start memory-rs to browse long-term memory and import finished assistant sessions.",
                actionTitle: "Start",
                action: { state.memoryEnabled = true }
            )
        }
    }
}
