import Foundation
import Observation

/// Sub-tabs within the Memory section.
///
/// memory-rs is primarily an agent tool (MCP + REST), so the native surface
/// covers the two things a human actually drives: browsing the memory virtual
/// filesystem and importing finished assistant sessions into it.
enum MemoryTab: String, Hashable, CaseIterable, Identifiable {
    case browse, sessions

    var id: String { rawValue }

    static var browsable: [MemoryTab] { [.browse, .sessions] }

    var title: String {
        switch self {
        case .browse:   return "Memory"
        case .sessions: return "Sessions"
        }
    }

    var icon: String {
        switch self {
        case .browse:   return "brain"
        case .sessions: return "square.and.arrow.down.on.square"
        }
    }
}

/// Sidebar selection: a top-level section, an MCP server nested under the
/// running Proxy, a Memory sub-tab / namespace, or an indexed codesearch
/// namespace. Modeling them in one `Hashable` type lets the single always-on
/// sidebar `List` bind its selection directly, so clicking a nested row both
/// selects it and opens its detail.
enum SidebarItem: Hashable {
    case section(AppSection)
    case proxyServer(String)
    case memoryTab(MemoryTab)
    /// A namespace nested under Memory — opens that namespace's detail (its
    /// member projects and the memories scoped to them).
    case memoryNamespace(String)
    /// An indexed namespace nested under Code Intelligence — opens its
    /// community graph.
    case codeNamespace(String)
}

/// Navigation state for the two-column split: the always-on sidebar picks the
/// section (or a nested proxy server / memory sub-tab / namespace); the detail
/// column fills the rest. Per-section selection lives here so returning to a
/// section restores what was open.
@Observable
final class NavigationModel {
    /// The section shown in the detail column. Proxy is the landing section.
    var section: AppSection? = .proxy
    var selectedServer: String?          // MCP server name (proxy editor)
    /// The active Memory sub-tab, or `nil` for the section's landing overview
    /// (stats + namespaces).
    var selectedMemoryTab: MemoryTab?
    /// A memory namespace drilled into from the Memory landing, or `nil` for the
    /// namespace grid. Held here (not view `@State`) so the 5s status poll
    /// re-rendering the detail column can't drop it — the same reason the
    /// sub-tabs carry stable `.id`s.
    var selectedMemoryNamespace: String?
    /// An indexed codesearch namespace opened from the sidebar, or `nil` for the
    /// Code Intelligence landing. Distinct from `selectedMemoryNamespace`: the
    /// two sections have unrelated namespace sets (memory groups *projects*,
    /// codesearch groups *indexed repositories*).
    var selectedCodeNamespace: String?

    /// The sidebar's current selection, projected from the state above so the
    /// two stay in sync. Setting it routes: a section switches the detail
    /// column; a nested proxy server opens that server; a memory tab opens it.
    var sidebarSelection: SidebarItem? {
        get {
            if section == .proxy, let server = selectedServer {
                return .proxyServer(server)
            }
            if section == .memory, let ns = selectedMemoryNamespace {
                return .memoryNamespace(ns)
            }
            if section == .memory, let tab = selectedMemoryTab {
                return .memoryTab(tab)
            }
            if section == .code, let ns = selectedCodeNamespace {
                return .codeNamespace(ns)
            }
            return section.map(SidebarItem.section)
        }
        set {
            switch newValue {
            case .section(let s):
                // Selecting ANY top-level row clears the nested selections —
                // including tapping the parent itself, which should show that
                // section's landing. Leaving a nested value set would make the
                // getter re-derive it and snap the highlight back.
                section = s
                selectedServer = nil
                selectedMemoryTab = nil
                selectedMemoryNamespace = nil
                selectedCodeNamespace = nil
            case .proxyServer(let name):
                section = .proxy
                selectedServer = name
            case .memoryTab(let tab):
                section = .memory
                selectedMemoryTab = tab
                selectedMemoryNamespace = nil
            case .memoryNamespace(let ns):
                section = .memory
                selectedMemoryNamespace = ns
                selectedMemoryTab = nil
            case .codeNamespace(let ns):
                section = .code
                selectedCodeNamespace = ns
            case nil:
                break
            }
        }
    }
}
