import SwiftUI

/// Mostra il Markdown semplice usato da Claude e dal modello Apple:
/// titoli (#), elenchi puntati e numerati, caselle (- [ ]), grassetto e corsivo.
struct MarkdownText: View {
    let text: String

    private enum Block: Identifiable {
        case heading(Int, String, Int)
        case bullet(String, Int)
        case numbered(String, String, Int)
        case task(Bool, String, Int)
        case paragraph(String, Int)
        case divider(Int)

        var id: Int {
            switch self {
            case .heading(_, _, let i), .bullet(_, let i), .numbered(_, _, let i),
                 .task(_, _, let i), .paragraph(_, let i), .divider(let i):
                return i
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: " "), index))
                index += 1
                paragraph = []
            }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "***" {
                flush(); result.append(.divider(index)); index += 1; continue
            }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                result.append(.heading(level, title, index)); index += 1
                continue
            }
            let lower = line.lowercased()
            if lower.hasPrefix("- [ ]") || lower.hasPrefix("- [x]") || lower.hasPrefix("* [ ]") || lower.hasPrefix("* [x]") {
                flush()
                let done = lower.hasPrefix("- [x]") || lower.hasPrefix("* [x]")
                result.append(.task(done, String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces), index)); index += 1
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                result.append(.bullet(String(line.dropFirst(2)), index)); index += 1
                continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                flush()
                let number = String(line[..<dot])
                let body = String(line[line.index(dot, offsetBy: 2)...])
                result.append(.numbered(number, body, index)); index += 1
                continue
            }
            paragraph.append(line)
        }
        flush()
        return result
    }

    private func inline(_ s: String) -> Text {
        if let attributed = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .heading(let level, let title, _):
                    inline(title)
                        .font(level <= 1 ? .title3.bold() : .headline)
                        .padding(.top, 8)
                case .bullet(let s, _):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(s)
                    }
                case .numbered(let n, let s, _):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                        inline(s)
                    }
                case .task(let done, let s, _):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(done ? Theme.accent : .secondary)
                        inline(s)
                    }
                case .paragraph(let s, _):
                    inline(s)
                case .divider:
                    Divider()
                }
            }
        }
        .font(.callout)
        .lineSpacing(2)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
