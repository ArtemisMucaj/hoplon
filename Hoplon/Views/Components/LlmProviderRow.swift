import SwiftUI

/// One model a provider offers, as rendered in the provider list.
nonisolated struct LlmModelRow: Identifiable, Hashable {
    let id: String
    var detail: String?
}

/// One configured inference server, collapsed to a single row.
///
/// Which model runs which job is settled by the pickers above, so a server's
/// model list is reference material — it stays folded until clicked. The row
/// itself is the click target; trailing `actions` stay clickable because they
/// sit outside the tap area rather than inside a nested button.
struct LlmProviderRow<Actions: View>: View {
    let name: String
    /// Base URL, or whatever identifies the provider in one line.
    let subtitle: String
    var hasKey: Bool = false
    var isLoading: Bool = false
    var error: String?
    var models: [LlmModelRow] = []
    /// Whether a model probe finished — an empty list only means "offers none"
    /// once it has.
    var loaded: Bool = false
    @ViewBuilder var actions: Actions

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                Divider()
                modelList
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                // No leading chevron: the names line up with everything else in
                // the pane, and the disclosure sits at the far right instead.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).font(.callout.weight(.medium))
                        if hasKey {
                            Image(systemName: "key.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(subtitle)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                status
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }

            HStack(spacing: 6) { actions }
                .fixedSize()

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private var status: some View {
        if isLoading {
            ProgressView().controlSize(.small)
        } else if error != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        } else if !models.isEmpty {
            Text("\(models.count) models").font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var modelList: some View {
        if let error {
            Text(error)
                .font(.caption).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
        } else if models.isEmpty {
            Text(loaded ? "No models offered." : "Loading…")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
        } else {
            VStack(spacing: 0) {
                ForEach(models) { model in
                    HStack(spacing: 8) {
                        Text(model.id).font(.caption.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        if let detail = model.detail, detail != model.id {
                            Text(detail).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 3)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// The Copilot row while it is not usable yet: a sign-in button, then the
/// device code inline once the flow is pending. Both LLM panes drive the same
/// server-side device flow, so the row is written once.
struct CopilotSignInRow: View {
    let login: CopilotLoginStatus?
    var isStarting: Bool = false
    let onSignIn: () -> Void

    private var isPending: Bool { login?.state == .pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub Copilot").font(.callout.weight(.medium))
                    if case .failed = login?.state, let error = login?.error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(isPending ? "Waiting for authorization…" : "Not signed in")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isPending || isStarting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Sign in", action: onSignIn).controlSize(.small)
                }
            }
            if isPending, let code = login?.userCode {
                HStack(spacing: 10) {
                    Text(code)
                        .font(.title3.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    CopyButton(text: { code }, help: "Copy the device code")
                    if let uri = login?.verificationUri, let url = URL(string: uri) {
                        Link("Open GitHub", destination: url).font(.callout)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
