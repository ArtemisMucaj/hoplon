import SwiftUI

/// Owns process lifecycle. Starts the services when the app finishes launching
/// (window-independent — the menu-bar item may be the only visible surface, so
/// we can't rely on a view's `.onAppear`) and kills them on terminate. Uses the
/// shared AppState so it and the UI observe one instance.
class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private let state = AppState.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            state.startProxy()
            state.startGuardrailsIfEnabled()
            state.startMemoryIfEnabled()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            state.stopProxy()
            state.stopGuardrails()
            state.stopMemory()
        }
    }
}

@main
struct HoplonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var state = AppState.shared
    @State private var nav = NavigationModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(state)
                .environment(nav)
        }
        .defaultSize(width: 1040, height: 640)
        // Honor RootView's `.frame(minWidth:minHeight:)` as the window's hard
        // minimum. Without this the window resizes freely below the content's
        // real minimum, and NavigationSplitView steals width from the sidebar —
        // clipping its labels off the left edge.
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Go") {
                Button("Proxy") { nav.sidebarSelection = .section(.proxy) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Guardrails") { nav.sidebarSelection = .section(.guardrails) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Memory") { nav.sidebarSelection = .section(.memory) }
                    .keyboardShortcut("3", modifiers: .command)
            }
            CommandMenu("Services") {
                Button("Start All Services") {
                    state.startProxy()
                    state.startGuardrails()
                    state.startMemory()
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Stop All Services") {
                    state.stopProxy()
                    state.stopGuardrails()
                    state.stopMemory()
                }
                .keyboardShortcut(".", modifiers: .command)
            }
        }

        // Menu bar extra for quick access.
        MenuBarExtra {
            MenuBarView()
                .environment(state)
        } label: {
            if state.proxyManager.isStarting || state.guardrailsManager.isStarting || state.memoryManager.isStarting {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .controlSize(.small)
                    menuBarIcon(dimmed: false)
                }
            } else {
                // Dim only when no service is running at all.
                let anyRunning = state.proxyManager.isRunning
                    || state.guardrailsManager.isRunning
                    || state.memoryManager.isRunning
                menuBarIcon(dimmed: !anyRunning)
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// A hoplon is the round shield a hoplite carried — hence the glyph. Uses
    /// the `MenuBarIcon` asset when one is present, else an SF Symbol so the app
    /// is usable before any art exists.
    @ViewBuilder
    private func menuBarIcon(dimmed: Bool) -> some View {
        if let img = NSImage(named: "MenuBarIcon") {
            Image(nsImage: img)
                .resizable()
                .frame(width: 16, height: 16)
                .opacity(dimmed ? 0.5 : 1.0)
        } else {
            Image(systemName: dimmed ? "shield" : "shield.fill")
        }
    }
}
