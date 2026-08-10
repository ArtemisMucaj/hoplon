import SwiftUI

// Shared design-system components for the control-center UI. These consolidate
// the visual vocabulary that previously lived (privately) inside GuardrailsView
// — status dots, metric cards, empty states, rounded card containers — so all
// three service bricks look and behave consistently.

// MARK: - Service status

/// Normalized lifecycle status for any of the three services.
enum ServiceStatus {
    case stopped
    case starting
    case running          // process up, admin/mgmt reachable
    case runningUnreachable // process up, but health endpoint not answering

    var color: Color {
        switch self {
        case .stopped:            return .secondary
        case .starting:           return .orange
        case .running:            return .green
        case .runningUnreachable: return .yellow
        }
    }

    var label: String {
        switch self {
        case .stopped:            return "Stopped"
        case .starting:           return "Starting…"
        case .running:            return "Running"
        case .runningUnreachable: return "Running (unreachable)"
        }
    }

    var isBusy: Bool { self == .starting }
}

/// A small status indicator: a pulsing dot while starting, a steady colored
/// dot otherwise.
struct StatusDot: View {
    let status: ServiceStatus
    var size: CGFloat = 10

    var body: some View {
        if status.isBusy {
            Image(systemName: "circle.fill")
                .font(.system(size: size))
                .foregroundStyle(Color.orange)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(status == .stopped ? Color.secondary.opacity(0.5) : status.color)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Metric card

/// A compact headline metric (used in dashboards and stat rollups).
struct MetricCard: View {
    let title: String
    let value: String
    var color: Color = .primary
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(title.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - Service header

/// The running/stopped header shown at the top of a service screen: a large
/// tinted icon, a status dot + label, a subtitle (endpoints when running), and
/// trailing controls. Shared so Guardrails and Code Intelligence look identical.
struct ServiceHeader<Controls: View>: View {
    let systemImage: String
    let status: ServiceStatus
    let subtitle: String
    @ViewBuilder var controls: Controls

    init(systemImage: String,
         status: ServiceStatus,
         subtitle: String,
         @ViewBuilder controls: () -> Controls = { EmptyView() }) {
        self.systemImage = systemImage
        self.status = status
        self.subtitle = subtitle
        self.controls = controls()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(status == .stopped ? Color.secondary : Color.accentColor)
                .layoutPriority(1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    StatusDot(status: status)
                    Text(status.label).font(.headline).fixedSize()
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
            // The subtitle is the flexible part — it truncates first when the
            // header is squeezed, so the trailing controls never get clipped.
            .layoutPriority(0)

            Spacer(minLength: 8)
            // Keep the controls at their intrinsic size and pinned right, so a
            // narrow window truncates the subtitle instead of cutting the Stop
            // button off the edge.
            controls
                .fixedSize()
                .layoutPriority(2)
        }
        .padding()
    }
}

// MARK: - Search bar

/// The one search field used across the code brick (code search, memory search,
/// call-graph symbol lookup). Prominent and identical everywhere: a large
/// rounded field with a leading magnifier, a clear button, and an optional
/// trailing accessory (e.g. a Kind picker). Submitting calls `onSubmit`.
struct SearchBar<Accessory: View>: View {
    @Binding var text: String
    var prompt: String
    var isBusy: Bool = false
    var onSubmit: () -> Void = {}
    @ViewBuilder var accessory: Accessory

    @FocusState private var focused: Bool

    init(text: Binding<String>,
         prompt: String,
         isBusy: Bool = false,
         onSubmit: @escaping () -> Void = {},
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self._text = text
        self.prompt = prompt
        self.isBusy = isBusy
        self.onSubmit = onSubmit
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(onSubmit)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                        focused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15),
                        lineWidth: 1))
            )

            accessory
        }
        .onAppear { focused = true }
    }
}

// MARK: - Card section container

/// A rounded container matching the `controlBackgroundColor` cards used across
/// the app for grouped tables/rows.
struct CardContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - Empty / error state

/// A centered icon + title + message, with an optional call-to-action button.
/// Thin wrapper over the native `ContentUnavailableView` so every empty,
/// loading-failed, and no-results state gets platform-correct styling.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Error card

/// A failure message that stays one or two lines until asked to expand.
///
/// Service errors are not all short: a failed SCIP index can carry a Node
/// out-of-memory dump — a GC log plus a native stack trace, hundreds of lines —
/// and rendering that raw turned the whole pane into a wall of red text with the
/// actual cause lost inside it. So the first line leads (it's the summary the
/// service wrote), the rest hides behind a disclosure, and the full text is
/// always copyable for a bug report.
struct ErrorCard: View {
    let message: String
    /// Shown above the message, e.g. "Indexing failed".
    var title: String?

    @State private var expanded = false

    /// The service's own summary line — the part worth reading first.
    private var firstLine: String {
        message.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? message
    }

    private var hasDetail: Bool {
        message.contains("\n") || message.count > 200
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            Text(title).font(.callout.weight(.medium))
                        }
                        Text(firstLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(expanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the full error")
                }

                if hasDetail {
                    Button(expanded ? "Show less" : "Show more") {
                        expanded.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)

                    if expanded {
                        ScrollView {
                            Text(message)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Bounded: the point is that a huge dump can't push the
                        // rest of the page off-screen.
                        .frame(maxHeight: 220)
                    }
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Section header (title + trailing accessory)

/// A lightweight section header used above card containers in the code brick.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            trailing
        }
    }
}

// MARK: - Formatting helpers

enum Format {
    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
    /// Compact integer with thousands separators (e.g. 6,139).
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
