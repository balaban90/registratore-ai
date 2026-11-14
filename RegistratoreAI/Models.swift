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

    var sortedSummaries: [Summary] {
        summaries.sorted { $0.createdAt > $1.createdAt }
    }
}

@Model
final class Summary {
    var id: UUID = UUID()
    var templateID: String = ""
    var templateName: String = ""
    var text: String = ""
    var createdAt: Date = Date.now
    var recording: Recording?

    init(templateID: String, templateName: String, text: String) {
        self.templateID = templateID
        self.templateName = templateName
        self.text = text
    }
}
