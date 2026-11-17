import Foundation
import SwiftData

/// Parola riconosciuta, con il suo orario e quanto il riconoscitore ne è sicuro.
struct TranscriptWord: Codable, Hashable {
    /// Testo così come esce dal riconoscitore (spazi e punteggiatura inclusi).
    var text: String
    var start: Double
    var end: Double
    var confidence: Double?
}

struct TranscriptSegment: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    /// Identificativo del parlante (nil se le voci non sono state separate).
    var speaker: String?
    /// Parole con orario: servono a dividere la frase quando cambia chi parla.
    /// Restano solo finché il testo è quello originale del riconoscitore.
    var words: [TranscriptWord]?
    /// Parole su cui il riconoscitore era poco sicuro (da evidenziare e far controllare all'AI).
    var uncertain: [String]?

    /// Soglia sotto cui una parola è considerata incerta.
    static let uncertainThreshold = 0.5

    /// Ricostruisce testo e parole incerte a partire dalle parole.
    static func make(from words: [TranscriptWord], speaker: String? = nil) -> TranscriptSegment? {
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let first = words.first, let last = words.last else { return nil }
        let doubts = words.compactMap { w -> String? in
            guard let c = w.confidence, c < uncertainThreshold else { return nil }
            let clean = w.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return clean.count >= 2 ? clean : nil
        }
        return TranscriptSegment(start: first.start, end: last.end, text: text, speaker: speaker,
                                 words: words, uncertain: doubts.isEmpty ? nil : doubts)
    }
}

/// Memoria dei dati già decodificati, per non rileggere il JSON a ogni schermata.
/// Una voce vale finché i byte salvati restano identici.
final class DecodeCache: @unchecked Sendable {
    static let shared = DecodeCache()
    private let lock = NSLock()
    private var entries: [String: (data: Data, value: Any)] = [:]
    private let limit = 80

    func value<T>(_ key: String, _ data: Data, make: (Data) -> T) -> T {
        lock.lock()
        if let entry = entries[key], let value = entry.value as? T, entry.data == data {
            lock.unlock()
            return value
        }
        lock.unlock()
        let value = make(data)
        store(key, data, value)
        return value
    }

    func store<T>(_ key: String, _ data: Data, _ value: T) {
        lock.lock()
        if entries.count >= limit && entries[key] == nil { entries.removeAll(keepingCapacity: true) }
        entries[key] = (data, value)
        lock.unlock()
    }
}

/// Profilo vocale salvato: permette di riconoscere una persona nelle nuove registrazioni.
@Model
final class VoiceProfile {
    var id: UUID = UUID()
    var name: String = ""
    var isMe: Bool = false
    var embeddingData: Data = Data()
    var createdAt: Date = Date.now

    init(name: String, isMe: Bool, embedding: [Float]) {
        self.name = name
        self.isMe = isMe
        self.embeddingData = (try? JSONEncoder().encode(embedding)) ?? Data()
    }

    var embedding: [Float] {
        (try? JSONDecoder().decode([Float].self, from: embeddingData)) ?? []
    }

    /// Id usato dal riconoscitore: così il parlante riconosciuto porta questo id.
    var speakerKey: String { "profile-\(id.uuidString)" }
}

@Model
final class Recording {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date.now
    var duration: Double = 0
    var audioFileName: String = ""
    var inputName: String = ""
    var highlights: [Double] = []
    var notes: String = ""
    var transcript: String?
    var segmentsData: Data?
    var transcriptionError: String?
    /// Trascrizione automatica originale, conservata quando Claude la rivede.
    var originalSegmentsData: Data?
    var revisedByClaude: Bool = false
    /// Voci separate e nomi assegnati (id parlante → nome).
    var diarized: Bool = false
    var speakerNamesData: Data?
    var speakerNamesUpdatedAt: Date?
    /// Nomi o ruoli dei parlanti proposti dall'AI, da confermare (id parlante → nome).
    var speakerSuggestionsData: Data?
    /// Lavorazione automatica avviata e non ancora conclusa (riprende alla riapertura dell'app).
    var pipelinePending: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \Summary.recording)
    var summaries: [Summary] = []

    init(title: String, audioFileName: String, duration: Double, inputName: String, highlights: [Double] = [], createdAt: Date = .now) {
        self.title = title
        self.audioFileName = audioFileName
        self.duration = duration
        self.inputName = inputName
        self.highlights = highlights
        self.createdAt = createdAt
    }

    var audioURL: URL { Storage.url(for: audioFileName) }

    // I dati della trascrizione sono salvati come JSON. Leggerli è costoso (una registrazione
    // lunga ha decine di migliaia di parole), quindi ogni lettura passa da DecodeCache:
    // si decodifica una sola volta finché il contenuto non cambia.

    var segments: [TranscriptSegment] {
        get {
            guard let segmentsData else { return [] }
            return DecodeCache.shared.value("\(id).seg", segmentsData) {
                (try? JSONDecoder().decode([TranscriptSegment].self, from: $0)) ?? []
            }
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            if let data { DecodeCache.shared.store("\(id).seg", data, newValue) }
            segmentsData = data
        }
    }

    var originalSegments: [TranscriptSegment] {
        get {
            guard let originalSegmentsData else { return [] }
            return DecodeCache.shared.value("\(id).orig", originalSegmentsData) {
                (try? JSONDecoder().decode([TranscriptSegment].self, from: $0)) ?? []
            }
        }
        set {
            let data = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
            if let data { DecodeCache.shared.store("\(id).orig", data, newValue) }
            originalSegmentsData = data
        }
    }

    var speakerNames: [String: String] {
        get {
            guard let speakerNamesData else { return [:] }
            return DecodeCache.shared.value("\(id).names", speakerNamesData) {
                (try? JSONDecoder().decode([String: String].self, from: $0)) ?? [:]
            }
        }
        set {
            speakerNamesData = try? JSONEncoder().encode(newValue)
        }
    }

    var speakerSuggestions: [String: String] {
        get {
            guard let speakerSuggestionsData else { return [:] }
            return DecodeCache.shared.value("\(id).sugg", speakerSuggestionsData) {
                (try? JSONDecoder().decode([String: String].self, from: $0)) ?? [:]
            }
        }
        set {
            speakerSuggestionsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    /// Parlanti nell'ordine in cui intervengono per la prima volta.
    var speakerOrder: [String] {
        guard let segmentsData else { return [] }
        let list = segments
        return DecodeCache.shared.value("\(id).order", segmentsData) { _ in
            Recording.order(of: list)
        }
    }

    static func order(of segments: [TranscriptSegment]) -> [String] {
        var seen: [String] = []
        var known = Set<String>()
        for s in segments {
            if let id = s.speaker, known.insert(id).inserted { seen.append(id) }
        }
        return seen
    }

    /// Nome da mostrare: quello assegnato, altrimenti "Persona N".
    func speakerName(_ id: String?) -> String {
        guard let id else { return "" }
        return Recording.displayName(id, names: speakerNames, order: speakerOrder)
    }

    static func displayName(_ id: String, names: [String: String], order: [String]) -> String {
        if let name = names[id], !name.isEmpty { return name }
        if let index = order.firstIndex(of: id) { return "Persona \(index + 1)" }
        return "Persona"
    }

    /// Testo per l'AI: una riga per turno di parola, con il nome se le voci sono separate.
    var plainTranscript: String {
        let segments = self.segments
        guard diarized else { return segments.map(\.text).joined(separator: "\n") }
        let names = speakerNames, order = speakerOrder
        func speakerName(_ id: String?) -> String { id.map { Recording.displayName($0, names: names, order: order) } ?? "" }
        var lines: [String] = []
        var currentSpeaker: String?? = .none
        var buffer = ""
        for s in segments {
            if currentSpeaker != .some(s.speaker) {
                if !buffer.isEmpty { lines.append(buffer) }
                currentSpeaker = .some(s.speaker)
                buffer = "\(speakerName(s.speaker)): \(s.text)"
            } else {
                buffer += " " + s.text
            }
        }
        if !buffer.isEmpty { lines.append(buffer) }
        return lines.joined(separator: "\n")
    }

    /// Testo con orari, per esportazione e lettura.
    var timedTranscript: String {
        let names = speakerNames, order = speakerOrder
        func speakerName(_ id: String?) -> String { id.map { Recording.displayName($0, names: names, order: order) } ?? "" }
        return segments.map { seg in
            let who = diarized && seg.speaker != nil ? "\(speakerName(seg.speaker)): " : ""
            return "[\(formatTime(seg.start))] \(who)\(seg.text)"
        }.joined(separator: "\n")
    }

    /// Versione compatta per Claude: un orario circa ogni minuto invece che a ogni frase
    /// (meno token, stessa informazione).
    var compactTranscript: String {
        let names = speakerNames, order = speakerOrder
        func speakerName(_ id: String?) -> String { id.map { Recording.displayName($0, names: names, order: order) } ?? "" }
        var blocks: [String] = []
        var blockStart: Double = -1000
        var current = ""
        var lastSpeaker: String?? = .none
        for segment in segments {
            let speakerChanged = diarized && lastSpeaker != .some(segment.speaker)
            if segment.start - blockStart >= 60 || speakerChanged {
                if !current.isEmpty { blocks.append(current) }
                blockStart = segment.start
                let who = diarized && segment.speaker != nil ? "\(speakerName(segment.speaker)): " : ""
                current = "[\(formatTime(segment.start))] \(who)\(segment.text)"
            } else {
                current += " " + segment.text
            }
            lastSpeaker = .some(segment.speaker)
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks.joined(separator: "\n")
    }

    /// Contesto dato dall'utente (note scritte e momenti segnati con la bandierina):
    /// l'AI gli dà più peso nelle elaborazioni, come le note di Plaud.
    var userContext: String {
        Recording.userContext(notes: notes, highlights: highlights)
    }

    static func userContext(notes: String, highlights: [Double]) -> String {
        var parts: [String] = []
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanNotes.isEmpty { parts.append("Note dell'utente:\n" + String(cleanNotes.prefix(2_000))) }
        if !highlights.isEmpty {
            parts.append("Momenti segnati dall'utente come importanti: "
                         + highlights.prefix(30).map { "[\(formatTime($0))]" }.joined(separator: ", "))
        }
        return parts.joined(separator: "\n")
    }

    /// Il titolo è ancora quello automatico ("Registrazione del …") e può essere sostituito da uno proposto.
    var hasDefaultTitle: Bool { title.hasPrefix("Registrazione del") || title.isEmpty }

    /// Anteprima per l'elenco: la frase "di cosa si parla" della Sintesi veloce.
    var preview: String? {
        guard let summary = summaries.filter({ $0.templateID == "sintesi" }).sorted(by: { $0.createdAt > $1.createdAt }).first
                ?? sortedSummaries.first else { return nil }
        for raw in summary.text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasSuffix(":") || line.hasSuffix(":**") { continue }  // titoli di sezione
            line = line.replacingOccurrences(of: "**", with: "")
            while let c = line.first, "#-*•0123456789.) ".contains(c) { line.removeFirst() }
            if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) < 25 {
                let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if rest.isEmpty { continue }
                line = rest
            }
            if line.count > 12 { return line }
        }
        return nil
    }

    var sortedSummaries: [Summary] {
        summaries.sorted { $0.createdAt > $1.createdAt }
    }
}

/// Voce del glossario: come la trascrizione sbaglia → come va scritto.
/// Se `wrong` è vuoto, il termine serve solo a Claude come riferimento.
@Model
final class GlossaryEntry {
    var id: UUID = UUID()
    var wrong: String = ""
    var right: String = ""
    var createdAt: Date = Date.now

    init(wrong: String, right: String) {
        self.wrong = wrong
        self.right = right
    }
}

/// Modello di riassunto creato dall'utente.
@Model
final class CustomTemplate {
    var id: UUID = UUID()
    var name: String = ""
    var icon: String = "star"
    var instructions: String = ""
    var createdAt: Date = Date.now
    /// Motore consigliato ("cloud" o "device").
    var engineRaw: String = SummaryEngine.cloud.rawValue

    init(name: String, icon: String = "star", instructions: String, engine: SummaryEngine = .cloud) {
        self.name = name
        self.icon = icon
        self.instructions = instructions
        self.engineRaw = engine.rawValue
    }

    var engine: SummaryEngine {
        get { SummaryEngine(rawValue: engineRaw) ?? .cloud }
        set { engineRaw = newValue.rawValue }
    }

    var asTemplate: SummaryTemplate {
        SummaryTemplate(id: "custom-\(id.uuidString)", name: name, icon: icon, instructions: instructions,
                        isCustom: true, engine: engine)
    }
}

@Model
final class Summary {
    var id: UUID = UUID()
    var templateID: String = ""
    var templateName: String = ""
    var text: String = ""
    var createdAt: Date = Date.now
    var costUSD: Double = 0
    var recording: Recording?

    /// Nome da mostrare (le elaborazioni salvate dalle versioni precedenti dicevano "Claude").
    var displayName: String {
        templateName
            .replacingOccurrences(of: " · Claude", with: " · AI")
            .replacingOccurrences(of: "Claude: ", with: "Domanda: ")
    }

    init(templateID: String, templateName: String, text: String, costUSD: Double = 0) {
        self.templateID = templateID
        self.templateName = templateName
        self.text = text
        self.costUSD = costUSD
    }
}
