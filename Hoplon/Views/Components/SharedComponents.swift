import SwiftUI

// Shared presentation components: badges, a lightweight markdown renderer,
// and a draggable two-pane split. Used across the Memory screens.

// MARK: - Badge

/// A small pill label used for node type / language tags.
struct Badge: View {
    let text: String
    var color: Color = .accentColor
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

// MARK: - Markdown

/// Lightweight Markdown renderer for the block-level content the app shows
/// (headings, tables, paragraphs). Apple's `AttributedString(markdown:)` only
/// does inline syntax and drops tables entirely, which left the architecture
/// overview looking raw — so we parse the handful of block elements ourselves
/// and still use `AttributedString` for inline styling within each line.
struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    /// One parsed block.
    private enum Block: Identifiable {
        case heading(level: Int, text: String)
        case table(header: [String], rows: [[String]])
        case paragraph(String)
        /// A `## Label — body` section (memory experiences write these, often as
        /// `- ## Label — …`). Rendered as a bold label above its body.
        case labeledSection(label: String, body: String)
        case bullet(String)
        var id: String {
            switch self {
            case .heading(_, let t): return "h:\(t)"
            case .table(let h, let r): return "t:\(h.joined())-\(r.count)"
            case .paragraph(let t): return "p:\(t.prefix(24))\(t.count)"
            case .labeledSection(let l, let b): return "s:\(l)\(b.prefix(16))"
            case .bullet(let t): return "b:\(t.prefix(24))\(t.count)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parse(text)) { block in
                switch block {
                case .heading(let level, let t):
                    Text(t)
                        .font(level <= 1 ? .headline : .subheadline.weight(.semibold))
                        .padding(.top, level <= 1 ? 2 : 0)
                case .paragraph(let t):
                    inline(t).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .table(let header, let rows):
                    tableView(header: header, rows: rows)
                case .labeledSection(let label, let text):
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label).font(.subheadline.weight(.semibold))
                        inline(text).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(t).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Inline markdown (bold/italic/code/links) within a single line.
    private func inline(_ line: String) -> Text {
        if let a = try? AttributedString(markdown: line,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(line)
    }

    @ViewBuilder
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let cols = max(header.count, rows.map(\.count).max() ?? 0)
        // SwiftUI `Grid` lays out explicit rows with correct intrinsic heights —
        // `LazyVGrid` was collapsing the body rows here.
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(0..<cols, id: \.self) { c in
                    Text(c < header.count ? header[c] : "")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                }
            }
            Divider().gridCellColumns(cols)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<cols, id: \.self) { c in
                        Text(c < row.count ? row[c] : "")
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .gridColumnAlignment(.leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// Split markdown into blocks. Recognizes ATX headings, GFM pipe tables, and
    /// runs of text as paragraphs. Deliberately small — not a full CommonMark
    /// parser, just enough for the overview payloads.
    private func parse(_ md: String) -> [Block] {
        var blocks: [Block] = []
        let lines = md.components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []
        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }
        func splitRow(_ line: String) -> [String] {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s.removeFirst() }
            if s.hasSuffix("|") { s.removeLast() }
            return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func isSeparator(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.contains("-") && t.allSatisfy { "|-: ".contains($0) } && t.contains("|")
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph(); i += 1; continue
            }
            // Strip a leading list marker so `- ## Label` and `* item` are seen
            // for what they contain (memory experiences write `- ## Situation …`).
            var body = trimmed
            let isListItem = body.hasPrefix("- ") || body.hasPrefix("* ")
            if isListItem { body = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces) }

            // `## Label — rest` (optionally list-wrapped): a labeled section.
            if body.hasPrefix("#") {
                flushParagraph()
                let label = body.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                // Split the heading text from any trailing body on an em/en dash
                // or colon so "Situation — foo" shows "Situation" bold + "foo".
                if let sep = label.range(of: #" [—–:-] "#, options: .regularExpression) {
                    let head = String(label[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let rest = String(label[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                    blocks.append(.labeledSection(label: head, body: rest))
                } else {
                    let level = body.prefix(while: { $0 == "#" }).count
                    blocks.append(.heading(level: level, text: label))
                }
                i += 1; continue
            }
            // A plain list item.
            if isListItem {
                flushParagraph()
                blocks.append(.bullet(body))
                i += 1; continue
            }
            // GFM table: a header row, a separator row, then body rows.
            if trimmed.contains("|"), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flushParagraph()
                let header = splitRow(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(splitRow(lines[i])); i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            paragraph.append(trimmed); i += 1
        }
        flushParagraph()
        return blocks
    }
}

// MARK: - ResizableSplit

/// A two-pane horizontal split with a drag-resizable divider, built from plain
/// SwiftUI stacks. Use instead of `HSplitView` inside the detail column: the
/// AppKit-backed split ignores the safe-area inset the floating sidebar
/// contributes (macOS 26), so its left pane slid under the sidebar and was
/// clipped — plain stacks respect the inset.
struct ResizableSplit<Left: View, Right: View>: View {
    private let leftMin: CGFloat
    private let rightMin: CGFloat
    private let left: Left
    private let right: Right
    @State private var leftWidth: CGFloat

    init(leftIdeal: CGFloat, leftMin: CGFloat, rightMin: CGFloat,
         @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.leftMin = leftMin
        self.rightMin = rightMin
        self.left = left()
        self.right = right()
        _leftWidth = State(initialValue: leftIdeal)
    }

    var body: some View {
        GeometryReader { geo in
            // Clamp so neither pane can be dragged (or window-resized) away.
            let width = min(max(leftWidth, leftMin), max(leftMin, geo.size.width - rightMin))
            HStack(spacing: 0) {
                left.frame(width: width).frame(maxHeight: .infinity)
                splitter(total: geo.size.width)
                right.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: "resizable-split")
        }
    }

    private func splitter(total: CGFloat) -> some View {
        Divider()
            .frame(maxHeight: .infinity)
            // An 8pt invisible grab strip over the 1pt line — dragging the bare
            // divider would demand pixel-perfect aim.
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("resizable-split"))
                            .onChanged { v in
                                leftWidth = min(max(v.location.x, leftMin), max(leftMin, total - rightMin))
                            }
                    )
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
            }
    }
}
