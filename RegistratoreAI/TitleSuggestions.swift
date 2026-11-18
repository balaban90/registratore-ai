import Foundation

/// Suggerimenti per il nome di una registrazione.
enum TitleSuggestions {
    static let instructions = """
    Proponi 4 titoli diversi in italiano per una registrazione, partendo dal testo.
    Ogni titolo: 3-7 parole, chiaro, dice di cosa si parla. Varia lo stile: uno descrittivo,
    uno con il tema principale, uno con chi partecipa o il tipo di incontro se si capisce, uno breve.
    Un titolo per riga, senza numeri, elenchi, virgolette o punto finale. Nessun altro testo.
    """

    /// Ripulisce la risposta: una proposta per riga, senza numeri, simboli o doppioni.
    static func parse(_ raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            var t = line.trimmingCharacters(in: .whitespaces)
            while let first = t.first, first.isNumber || "-*•–.)#:".contains(first) || first == " " {
                t.removeFirst()
            }
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \"«»“”*_.'"))
            guard t.count >= 3, t.count <= 80 else { continue }
            let key = t.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(t)
            if out.count == 4 { break }
        }
        return out
    }

    /// Proposte che non richiedono l'AI: tipo di registrazione e data, nomi di chi parla,
    /// tema della sintesi. Disponibili subito, anche senza rete.
    static func basic(for recording: Recording) -> [String] {
        let day = recording.createdAt.formatted(.dateTime.day().month(.wide))
        let hour = recording.createdAt.formatted(.dateTime.hour().minute())
        var out: [String] = []
        let names = Array(Set(recording.speakerNames.values.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })).sorted()
        if names.count >= 2 {
            let shown = names.prefix(3).joined(separator: ", ")
            out.append("Incontro con \(shown)")
        } else if names.count == 1 {
            out.append("Conversazione con \(names[0])")
        }
        if let theme = sintesiTheme(recording) { out.append(theme) }
        out.append(recording.speakerOrder.count >= 2 ? "Riunione del \(day)" : "Nota del \(day)")
        out.append("Registrazione del \(day), ore \(hour)")
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted && $0.lowercased() != recording.title.lowercased() }
    }

    /// Primo titolo o prima riga utile della sintesi, se breve.
    private static func sintesiTheme(_ recording: Recording) -> String? {
        guard let text = recording.summaries.first(where: { $0.templateID == "sintesi" })?.text else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: CharacterSet(charactersIn: " #*-•\t"))
            guard !t.isEmpty else { continue }
            let words = t.split(separator: " ").count
            if words >= 2 && words <= 8 && !t.hasSuffix(":") { return t.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            return nil
        }
        return nil
    }
}
