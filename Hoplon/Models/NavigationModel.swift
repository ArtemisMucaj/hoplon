import Foundation
import Observation

/// Sidebar selection: a top-level section, an MCP server nested under the
/// running Proxy, or an indexed codesearch namespace. Modeling them in one
/// `Hashable` type lets the single always-on sidebar `List` bind its selection
/// directly, so clicking a nested row both selects it and opens its detail.
enum SidebarItem: Hashable {
    case section(AppSection)
    case proxyServer(String)
    /// An indexed namespace nested under Code Intelligence — opens its
    /// community graph.
    case codeNamespace(String)
}

/// Navigation state for the two-column split: the always-on sidebar picks the
/// section (or a nested proxy server / namespace); the detail column fills the
/// rest. Per-section selection lives here so returning to a
/// section restores what was open.
@Observable
final class NavigationModel {
    /// The section shown in the detail column. Proxy is the landing section.
    var section: AppSection? = .proxy
    var selectedServer: String?          // MCP server name (proxy editor)
    /// An indexed codesearch namespace opened from the sidebar, or `nil` for the
    /// Code Intelligence landing. Held here (not view `@State`) so the 5s status
    /// poll re-rendering the detail column can't drop it.
    var selectedCodeNamespace: String?

    /// The sidebar's current selection, projected from the state above so the
    /// two stay in sync. Setting it routes: a section switches the detail
    /// column; a nested proxy server or namespace opens it.
    var sidebarSelection: SidebarItem? {
        get {
            if section == .proxy, let server = selectedServer {
                return .proxyServer(server)
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
                selectedCodeNamespace = nil
            case .proxyServer(let name):
                section = .proxy
                selectedServer = name
            case .codeNamespace(let ns):
                section = .code
                selectedCodeNamespace = ns
            case nil:
                break
            }
        }
    }
}
