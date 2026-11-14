import Foundation
import SwiftData

struct TranscriptSegment: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
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

    /// Testo semplice, senza orari: è quello che passa all'AI (risparmia spazio).
    var plainTranscript: String {
        segments.map(\.text).joined(separator: "\n")
    }

    /// Testo con orari, per esportazione e lettura.
    var timedTranscript: String {
        segments.map { "[\(formatTime($0.start))] \($0.text)" }.joined(separator: "\n")
    }

    /// Versione compatta per Claude: un orario circa ogni minuto invece che a ogni frase
    /// (meno token, stessa informazione).
    var compactTranscript: String {
        var blocks: [String] = []
        var blockStart: Double = -1000
        var current = ""
        for segment in segments {
            if segment.start - blockStart >= 60 {
                if !current.isEmpty { blocks.append(current) }
                blockStart = segment.start
                current = "[\(formatTime(segment.start))] \(segment.text)"
            } else {
                current += " " + segment.text
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks.joined(separator: "\n")
    }

    var sortedSummaries: [Summary] {
        summaries.sorted { $0.createdAt > $1.createdAt }
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

    init(name: String, icon: String = "star", instructions: String) {
        self.name = name
        self.icon = icon
        self.instructions = instructions
    }

    var asTemplate: SummaryTemplate {
        SummaryTemplate(id: "custom-\(id.uuidString)", name: name, icon: icon, instructions: instructions, isCustom: true)
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

    init(templateID: String, templateName: String, text: String, costUSD: Double = 0) {
        self.templateID = templateID
        self.templateName = templateName
        self.text = text
        self.costUSD = costUSD
    }
}
