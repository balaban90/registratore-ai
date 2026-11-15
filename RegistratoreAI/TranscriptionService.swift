import Foundation
import AVFoundation
import Speech
import WhisperKit

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

/// Motore di trascrizione. Entrambi lavorano sul dispositivo: l'audio non esce mai dall'iPhone.
enum TranscriptionEngine: String, CaseIterable, Identifiable {
    /// Riconoscimento vocale di Apple: veloce, nessun download aggiuntivo.
    case fast
    /// Whisper Large v3 Turbo (WhisperKit): più preciso sul parlato colloquiale, più lento.
    case accurate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: return "Veloce"
        case .accurate: return "Preciso"
        }
    }

    static let defaultsKey = "transcriptionEngine"

    static var current: TranscriptionEngine {
        TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .fast
    }
}

enum TranscriptionService {
    static var requestedLocale: Locale { Locale(identifier: TranscriptionLanguage.current.rawValue) }

    static func transcribe(url: URL, engine: TranscriptionEngine = .current,
                           progress: @escaping @MainActor (String) -> Void) async throws -> [TranscriptSegment] {
        switch engine {
        case .fast: return try await transcribeWithApple(url: url, progress: progress)
        case .accurate: return try await transcribeWithWhisper(url: url, progress: progress)
        }
    }

    // MARK: - Whisper

    /// Variante compressa di Whisper Large v3 Turbo (circa 630 MB), adatta all'iPhone.
    static let whisperModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    private static var whisper: WhisperKit?

    private static func transcribeWithWhisper(url: URL, progress: @escaping @MainActor (String) -> Void) async throws -> [TranscriptSegment] {
        let pipe: WhisperKit
        if let whisper {
            pipe = whisper
        } else {
            await progress("Preparo il motore Preciso (la prima volta scarica circa 630 MB)…")
            let config = WhisperKitConfig(model: whisperModel)
            pipe = try await WhisperKit(config)
            whisper = pipe
        }

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = String(TranscriptionLanguage.current.rawValue.prefix(2))
        options.temperature = 0
        options.skipSpecialTokens = true
        options.wordTimestamps = true
        options.chunkingStrategy = .vad
        // Mai saltare una finestra perché "sembra silenzio": WhisperKit scarterebbe 30 secondi interi.
        // Con parlato sovrapposto o audio di qualità bassa capitava di perdere pezzi di registrazione.
        options.noSpeechThreshold = nil

        await progress("Trascrivo con il motore Preciso (può richiedere qualche minuto)…")
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)

        var segments: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                let words = (seg.words ?? []).map {
                    TranscriptWord(text: $0.word, start: Double($0.start), end: Double($0.end),
                                   confidence: Double($0.probability))
                }
                if let segment = TranscriptSegment.make(from: words) {
                    segments.append(segment)
                } else {
                    let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    segments.append(TranscriptSegment(start: Double(seg.start), end: Double(seg.end), text: text))
                }
            }
        }
        segments.sort { $0.start < $1.start }

        // Rete di sicurezza: se restano buchi, li riempie con il motore Veloce,
        // così nessuna parte della registrazione va persa.
        if hasGaps(segments, duration: audioDuration(url)) {
            await progress("Controllo che non manchi nessuna parte…")
            if let apple = try? await transcribeWithApple(url: url, progress: { _ in }) {
                segments = fillGaps(segments, with: apple)
            }
        }

        guard !segments.isEmpty else { throw TranscriptionFailure.empty }
        return segments
    }

    /// Buco minimo (in secondi) oltre il quale si prova a recuperare il parlato.
    private static let minGap = 6.0

    private static func audioDuration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func gaps(in segments: [TranscriptSegment], duration: Double) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        var cursor = 0.0
        for s in segments {
            if s.start - cursor >= minGap { result.append((cursor, s.start)) }
            cursor = max(cursor, s.end)
        }
        if duration - cursor >= minGap { result.append((cursor, duration)) }
        return result
    }

    private static func hasGaps(_ segments: [TranscriptSegment], duration: Double) -> Bool {
        !gaps(in: segments, duration: duration).isEmpty
    }

    /// Inserisce le frasi del secondo motore che cadono interamente nei buchi del primo.
    private static func fillGaps(_ segments: [TranscriptSegment], with other: [TranscriptSegment]) -> [TranscriptSegment] {
        let holes = gaps(in: segments, duration: other.last?.end ?? 0)
        let extra = other.filter { seg in
            holes.contains { seg.start >= $0.0 - 0.5 && seg.end <= $0.1 + 0.5 }
        }
        return (segments + extra).sorted { $0.start < $1.start }
    }

    // MARK: - Apple (SpeechAnalyzer, iOS 26)

    private static func transcribeWithApple(url: URL, progress: @escaping @MainActor (String) -> Void) async throws -> [TranscriptSegment] {
        await progress("Preparo il riconoscimento vocale…")

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionFailure.languageNotSupported
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
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
                // Parola per parola, con orario e affidabilità.
                var words: [TranscriptWord] = []
                var pending = ""   // testo senza orario (spazi, punteggiatura): va alla parola vicina
                for run in result.text.runs {
                    let piece = String(result.text[run.range].characters)
                    if let range = run.audioTimeRange {
                        words.append(TranscriptWord(text: pending + piece,
                                                    start: range.start.seconds,
                                                    end: range.end.seconds,
                                                    confidence: run.transcriptionConfidence))
                        pending = ""
                    } else if !words.isEmpty {
                        words[words.count - 1].text += piece
                    } else {
                        pending += piece
                    }
                }
                if let segment = TranscriptSegment.make(from: words) {
                    segments.append(segment)
                } else {
                    // Nessun orario disponibile: frase intera, come prima.
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let s = segments.last?.end ?? 0
                    segments.append(TranscriptSegment(start: s, end: s, text: text))
                }
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
