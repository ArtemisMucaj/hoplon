import SwiftUI
import AppKit

/// Detail column for the Code Intelligence section.
///
/// codesearch is an agent tool (MCP + REST), so the native surface is a map of
/// what's indexed rather than a re-implementation of search: the landing shows
/// index-wide stats and the indexed namespaces as clickable squares, and a
/// sidebar namespace row opens that namespace's community graph directly.
///
/// Long-term memory used to live under this section; it moved to memory-rs and
/// has its own top-level section now.
struct CodeDetailView: View {
    @Environment(AppState.self) var state
    @Environment(NavigationModel.self) var nav

    private var manager: CodesearchManager { state.codesearchManager }

    var body: some View {
        Group {
            if manager.isRunning {
                VStack(spacing: 0) {
                    // Shared running header — identical to the other services.
                    ServiceHeader(
                        systemImage: AppSection.code.systemImage,
                        status: state.codesearchStatus,
                        subtitle: "MCP \(manager.mcpEndpoint)  ·  API \(manager.mgmtBase)"
                    ) {
                        Button { manager.refresh() } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) {
                            state.codesearchEnabled = false
                        } label: {
                            Label("Stop", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.glassProminent).tint(.red)
                    }
                    Divider()

                    // A sidebar namespace selection opens that namespace's
                    // community graph directly; the landing squares open the
                    // Overview instead, via CodeOverviewView's own state.
                    // Stable .id so the 5s status poll re-rendering this view
                    // can't re-create the child and restart its loads.
                    Group {
                        if let ns = nav.selectedCodeNamespace {
                            NamespaceGraphView(
                                namespace: ns,
                                repos: manager.repositories.filter { ($0.namespace ?? "—") == ns }
                            )
                            .id("code.graph.\(ns)")
                        } else {
                            CodeOverviewView().id("code.overview")
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
                Text("Starting codesearch…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = manager.lastError {
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Could not start Code Intelligence",
                message: error,
                actionTitle: "Try Again",
                action: { state.codesearchEnabled = true }
            )
        } else {
            EmptyStateView(
                icon: AppSection.code.systemImage,
                title: "Code Intelligence is stopped",
                message: "Start codesearch to browse indexed namespaces, communities and call graphs.",
                actionTitle: "Start",
                action: { state.codesearchEnabled = true }
            )
        }
    }
}
