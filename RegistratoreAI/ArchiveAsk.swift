import Foundation

/// "Chiedi all'archivio" (come Ask Plaud): una domanda su tutte le registrazioni.
///
/// Per spendere poco non si manda tutto: si scelgono le registrazioni più pertinenti
/// (parole della domanda in titolo, elaborazioni, note, nomi e trascrizione) e di
/// ciascuna si mandano la sintesi e solo i passaggi in cui compaiono quelle parole.
/// L'AI cita le fonti come [R2 12:30]: l'app le trasforma in collegamenti al punto esatto dell'audio.
enum ArchiveAsk {
    /// Materiale di una registrazione, già estratto (così la scelta si può provare senza archivio).
    struct Item {
        let id: UUID
        let title: String
        let date: Date
        let duration: Double
        let summary: String
        let notes: String
        let names: [String]
        /// Frasi con orario e chi parla, già nel formato "[mm:ss] Nome: testo".
        let lines: [(time: Double, text: String)]
    }

    struct Source: Identifiable, Hashable {
        let number: Int
        let id: UUID
        let title: String
    }

    /// Rimando a un punto preciso di una fonte, letto dalla risposta.
    struct Citation: Identifiable, Hashable {
        let number: Int
        let time: Double?
        var id: String { "\(number)-\(time ?? -1)" }
    }

    static let maxRecordings = 6
    static let charsPerRecording = 5_000
    static let totalChars = 32_000

    private static let stopwords: Set<String> = [
        "abbiamo", "allora", "anche", "ancora", "avere", "avevo", "come", "con", "cosa", "cose", "dalla", "dalle",
        "degli", "della", "delle", "dello", "detto", "dove", "dopo", "erano", "essere", "fare", "fatto", "hanno",
        "loro", "molto", "nella", "nelle", "nello", "negli", "noi", "nostra", "nostro", "ogni", "perché", "perche",
        "però", "poi", "posso", "prima", "proprio", "quale", "quali", "quando", "quanto", "quella", "quelle",
        "quelli", "quello", "questa", "queste", "questi", "questo", "sono", "stata", "stato", "sulla", "sulle",
        "sugli", "tutte", "tutti", "tutto", "volta", "dimmi", "parlato", "registrazione", "registrazioni",
        "riunione", "riunioni", "chi", "che", "del", "dei", "nel", "per", "una", "uno", "gli", "le", "ho", "hai",
        "the", "and", "what", "when", "where", "which", "with"
    ]

    /// Parole significative della domanda, ridotte alla radice (prime 5 lettere) per
    /// trovare anche plurali e forme simili ("contratto" → "contr", trova "contratti").
    static func keywords(in question: String) -> [String] {
        let words = question.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
        var seen = Set<String>()
        var result: [String] = []
        for w in words {
            let stem = w.count >= 6 ? String(w.prefix(5)) : w
            if seen.insert(stem).inserted { result.append(stem) }
        }
        return result
    }

    private static func count(_ stem: String, in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var n = 0
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: stem, options: [.caseInsensitive, .diacriticInsensitive], range: range) {
            n += 1
            if n >= 20 { break }
            range = found.upperBound..<text.endIndex
        }
        return n
    }

    /// Punteggio di pertinenza: il titolo e le elaborazioni contano più della trascrizione.
    static func score(_ item: Item, keywords: [String]) -> Int {
        let transcript = item.lines.map(\.text).joined(separator: " ")
        let names = item.names.joined(separator: " ")
        return keywords.reduce(0) { total, k in
            total + count(k, in: item.title) * 6 + count(k, in: names) * 5
                + count(k, in: item.summary) * 3 + count(k, in: item.notes) * 3 + min(count(k, in: transcript), 10)
        }
    }

    /// Registrazioni da usare: le più pertinenti; se la domanda non ne trova nessuna, le più recenti.
    static func select(_ items: [Item], for question: String) -> [Item] {
        let keys = keywords(in: question)
        let scored = items.map { ($0, keys.isEmpty ? 0 : score($0, keywords: keys)) }
        let relevant = scored.filter { $0.1 > 0 }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }
            .map(\.0)
        if !relevant.isEmpty { return Array(relevant.prefix(maxRecordings)) }
        return Array(items.sorted { $0.date > $1.date }.prefix(maxRecordings))
    }

    /// Passaggi della trascrizione che contengono le parole della domanda, con la frase prima e dopo.
    static func excerpts(_ item: Item, keywords: [String], limit: Int) -> String {
        guard !item.lines.isEmpty else { return "" }
        var wanted = IndexSet()
        if !keywords.isEmpty {
            for (i, line) in item.lines.enumerated() where keywords.contains(where: { count($0, in: line.text) > 0 }) {
                wanted.insert(integersIn: max(0, i - 1)...min(item.lines.count - 1, i + 1))
            }
        }
        if wanted.isEmpty {
            // Nessuna parola trovata nel testo: si manda l'inizio, che di solito dice di cosa si parla.
            wanted.insert(integersIn: 0..<min(item.lines.count, 25))
        }
        var out = ""
        var previous: Int?
        for i in wanted {
            let line = item.lines[i].text
            if out.count + line.count > limit { break }
            if let p = previous, i > p + 1 { out += "…\n" }
            out += line + "\n"
            previous = i
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Testo mandato all'AI e fonti numerate (R1, R2…).
    static func material(for question: String, from items: [Item]) -> (text: String, sources: [Source]) {
        let chosen = select(items, for: question)
        let keys = keywords(in: question)
        var blocks: [String] = []
        var sources: [Source] = []
        var used = 0
        let dateFormat = Date.FormatStyle.dateTime.day().month(.wide).year().locale(Locale(identifier: "it_IT"))
        for (n, item) in chosen.enumerated() {
            guard used < totalChars else { break }
            let budget = min(charsPerRecording, totalChars - used)
            var block = "[R\(n + 1)] \"\(item.title)\" · \(item.date.formatted(dateFormat)) · durata \(formatTime(item.duration))"
            if !item.names.isEmpty { block += "\nPersone: " + item.names.joined(separator: ", ") }
            if !item.notes.isEmpty { block += "\nNote dell'utente: " + String(item.notes.prefix(600)) }
            if !item.summary.isEmpty { block += "\nSintesi:\n" + String(item.summary.prefix(1_500)) }
            let passages = excerpts(item, keywords: keys, limit: max(500, budget - block.count))
            if !passages.isEmpty { block += "\nPassaggi della trascrizione:\n" + passages }
            blocks.append(block)
            sources.append(Source(number: n + 1, id: item.id, title: item.title))
            used += block.count
        }
        return (blocks.joined(separator: "\n\n"), sources)
    }

    static let instructions = """
    Sei l'assistente di un archivio di registrazioni (riunioni, lezioni, colloqui, telefonate, appunti).
    Rispondi in italiano, in modo chiaro e sintetico, usando SOLO il materiale qui sotto.
    Ogni registrazione ha un codice [R1], [R2]…; gli orari tra parentesi quadre indicano il punto dell'audio.
    Dopo ogni informazione indica la fonte nel formato [R1 12:30] (codice e orario) o [R1] se l'orario non c'è.
    Se il materiale non basta per rispondere, dillo chiaramente invece di inventare.
    Se le registrazioni non parlano dell'argomento, rispondi che nell'archivio non c'è.
    """

    /// Rimandi trovati nella risposta, nell'ordine e senza doppioni.
    static func citations(in answer: String, sources: [Source]) -> [Citation] {
        guard let regex = try? NSRegularExpression(pattern: "\\[R(\\d{1,2})(?:[ ,·:\\-]+(\\d{1,2}:\\d{2}(?::\\d{2})?))?\\]") else { return [] }
        let valid = Set(sources.map(\.number))
        var seen = Set<String>()
        var result: [Citation] = []
        let ns = answer as NSString
        for match in regex.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            guard let number = Int(ns.substring(with: match.range(at: 1))), valid.contains(number) else { continue }
            var time: Double?
            if match.range(at: 2).location != NSNotFound {
                time = seconds(from: ns.substring(with: match.range(at: 2)))
            }
            let citation = Citation(number: number, time: time)
            if seen.insert(citation.id).inserted { result.append(citation) }
        }
        return result
    }

    /// "12:30" → 750, "1:02:03" → 3723.
    static func seconds(from text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    static func ask(question: String, items: [Item]) async throws -> (answer: ClaudeReply, sources: [Source]) {
        let material = material(for: question, from: items)
        DiagnosticLog.info(.ai, "Domanda all'archivio · \(items.count) registrazioni · scelte \(material.sources.count) · \(material.text.count) caratteri")
        let reply = try await ClaudeService.send(
            cachedContext: instructions,
            instructions: "MATERIALE DELL'ARCHIVIO:\n\n" + material.text,
            messages: [ClaudeMessage(role: "user", content: question)],
            maxTokens: 2_000,
            model: ClaudeService.chatModel
        )
        return (reply, material.sources)
    }
}

extension Recording {
    /// Materiale per "Chiedi all'archivio".
    var archiveItem: ArchiveAsk.Item {
        let names = speakerNames, order = speakerOrder
        let isDiarized = diarized
        let lines: [(time: Double, text: String)] = segments.map { seg in
            let who = isDiarized && seg.speaker != nil
                ? Recording.displayName(seg.speaker!, names: names, order: order) + ": " : ""
            return (seg.start, "[\(formatTime(seg.start))] \(who)\(seg.text)")
        }
        let summary = summaries.filter { $0.templateID == "sintesi" }.sorted { $0.createdAt > $1.createdAt }.first
            ?? sortedSummaries.first
        return ArchiveAsk.Item(id: id, title: title, date: createdAt, duration: duration,
                               summary: summary?.text ?? "", notes: notes,
                               names: names.values.filter { !$0.isEmpty }.sorted(), lines: lines)
    }
}
