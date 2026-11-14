import Foundation

/// Sostituzioni automatiche e gratuite, applicate a ogni trascrizione.
enum Glossary {
    static func apply(_ entries: [GlossaryEntry], to text: String) -> String {
        var result = text
        // Prima le espressioni più lunghe, così "erre esse u" vince su "erre".
        let rules = entries
            .map { ($0.wrong.trimmingCharacters(in: .whitespaces), $0.right.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
            .sorted { $0.0.count > $1.0.count }
        for (wrong, right) in rules {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: wrong) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: right))
        }
        return result
    }

    static func apply(_ entries: [GlossaryEntry], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard entries.contains(where: { !$0.wrong.isEmpty }) else { return segments }
        return segments.map { segment in
            var s = segment
            s.text = apply(entries, to: segment.text)
            return s
        }
    }

    /// Elenco dei termini corretti, da passare a Claude come riferimento.
    static func termsForClaude(_ entries: [GlossaryEntry]) -> String {
        let terms = Set(entries.map { $0.right.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return terms.sorted().joined(separator: ", ")
    }
}
