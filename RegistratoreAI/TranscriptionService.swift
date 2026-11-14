import Foundation
import AVFoundation
import Speech

enum TranscriptionFailure: LocalizedError {
    case languageNotSupported
    case empty

    var errorDescription: String? {
        switch self {
        case .languageNotSupported:
            return "L'italiano non è disponibile per la trascrizione su questo iPhone."
        case .empty:
            return "Non ho riconosciuto parlato in questa registrazione."
        }
    }
}

/// Trascrizione interamente sul dispositivo con SpeechAnalyzer (iOS 26).
enum TranscriptionService {
    static let requestedLocale = Locale(identifier: "it-IT")

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
            await progress("Scarico il modello per l'italiano (solo la prima volta)…")
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
