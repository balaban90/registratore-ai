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

    var segments: [TranscriptSegment] {
        get {
            guard let segmentsData else { return [] }
            return (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? []
        }
        set {
            segmentsData = try? JSONEncoder().encode(newValue)
        }
    }

    var originalSegments: [TranscriptSegment] {
        get {
            guard let originalSegmentsData else { return [] }
            return (try? JSONDecoder().decode([TranscriptSegment].self, from: originalSegmentsData)) ?? []
        }
        set {
            originalSegmentsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    var speakerNames: [String: String] {
        get {
            guard let speakerNamesData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: speakerNamesData)) ?? [:]
        }
        set {
            speakerNamesData = try? JSONEncoder().encode(newValue)
        }
    }

    var speakerSuggestions: [String: String] {
        get {
            guard let speakerSuggestionsData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: speakerSuggestionsData)) ?? [:]
        }
        set {
            speakerSuggestionsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    /// Parlanti nell'ordine in cui intervengono per la prima volta.
    var speakerOrder: [String] {
        var seen: [String] = []
        for s in segments {
            if let id = s.speaker, !seen.contains(id) { seen.append(id) }
        }
        return seen
    }

    /// Nome da mostrare: quello assegnato, altrimenti "Persona N".
    func speakerName(_ id: String?) -> String {
        guard let id else { return "" }
        if let name = speakerNames[id], !name.isEmpty { return name }
        if let index = speakerOrder.firstIndex(of: id) { return "Persona \(index + 1)" }
        return "Persona"
    }

    /// Testo per l'AI: una riga per turno di parola, con il nome se le voci sono separate.
    var plainTranscript: String {
        guard diarized else { return segments.map(\.text).joined(separator: "\n") }
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
        segments.map { seg in
            let who = diarized && seg.speaker != nil ? "\(speakerName(seg.speaker)): " : ""
            return "[\(formatTime(seg.start))] \(who)\(seg.text)"
        }.joined(separator: "\n")
    }

    /// Versione compatta per Claude: un orario circa ogni minuto invece che a ogni frase
    /// (meno token, stessa informazione).
    var compactTranscript: String {
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
