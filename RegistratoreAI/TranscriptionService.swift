import Foundation
import AVFoundation
import Speech

enum TranscriptionFailure: LocalizedError {
    case languageNotSupported
    case empty

    var errorDescription: String? {
        switch self {
        case .languageNotSupported:
            return "Questa lingua non è disponibile per la trascrizione su questo iPhone. Scegline un'altra in Impostazioni."
        case .empty:
            return "Non ho riconosciuto parlato in questa registrazione."
        }
    }
}

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case italian = "it-IT"
    case englishUS = "en-US"
    case englishUK = "en-GB"
    case french = "fr-FR"
    case german = "de-DE"
    case spanish = "es-ES"
    case portuguese = "pt-BR"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .italian: return "Italiano"
        case .englishUS: return "Inglese (USA)"
        case .englishUK: return "Inglese (UK)"
        case .french: return "Francese"
        case .german: return "Tedesco"
        case .spanish: return "Spagnolo"
        case .portuguese: return "Portoghese (Brasile)"
        }
    }

    static let defaultsKey = "transcriptionLanguage"

    static var current: TranscriptionLanguage {
        TranscriptionLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .italian
    }
}

/// Trascrizione interamente sul dispositivo con SpeechAnalyzer (iOS 26).
enum TranscriptionService {
    static var requestedLocale: Locale { Locale(identifier: TranscriptionLanguage.current.rawValue) }

    static func transcribe(url: URL, progress: @escaping @MainActor (String) -> Void) async throws -> [TranscriptSegment] {
        await progress("Preparo il riconoscimento vocale…")

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionFailure.languageNotSupported
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await progress("Scarico il modello per \(TranscriptionLanguage.current.label.lowercased()) (solo la prima volta)…")
            try await request.downloadAndInstall()
        }

        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                var start: Double?
                var end: Double?
                for run in result.text.runs {
                    if let range = run.audioTimeRange {
                        if start == nil { start = range.start.seconds }
                        end = range.end.seconds
                    }
                }
                let s = start ?? segments.last?.end ?? 0
                segments.append(TranscriptSegment(start: s, end: end ?? s, text: text))
            }
            return segments
        }

        await progress("Trascrivo sul dispositivo…")
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            try? await analyzer.cancelAndFinishNow()
        }

        let segments = try await collector.value
        guard !segments.isEmpty else { throw TranscriptionFailure.empty }
        return segments
    }
}
