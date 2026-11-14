import Foundation
import FluidAudio

struct SpeakerTurn {
    let speakerId: String
    let start: Double
    let end: Double
}

struct KnownVoice {
    let id: String
    let name: String
    let embedding: [Float]
}

enum DiarizationFailure: LocalizedError {
    case noVoices
    case tooShort

    var errorDescription: String? {
        switch self {
        case .noVoices: return "Non ho trovato voci da separare in questa registrazione."
        case .tooShort: return "Serve almeno qualche secondo di parlato per creare il profilo vocale."
        }
    }
}

/// Separazione dei parlanti sul telefono con FluidAudio (modelli CoreML,
/// scaricati una sola volta). L'audio non lascia mai l'iPhone.
enum DiarizationService {
    static let enabledKey = "diarizationEnabled"
    static let sampleRate = 16_000.0

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static func makeDiarizer() async throws -> DiarizerManager {
        let models = try await DiarizerModels.downloadIfNeeded()
        let diarizer = DiarizerManager()
        diarizer.initialize(models: models)
        return diarizer
    }

    private static func loadSamples(_ url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }

    /// Chi parla quando.
    static func diarize(url: URL, known: [KnownVoice], progress: @escaping @MainActor (String) -> Void) async throws -> [SpeakerTurn] {
        await progress("Preparo il riconoscimento delle voci (la prima volta scarica i modelli)…")
        let diarizer = try await makeDiarizer()
        if !known.isEmpty {
            let speakers = known.map { Speaker(id: $0.id, name: $0.name, currentEmbedding: $0.embedding) }
            diarizer.speakerManager.initializeKnownSpeakers(speakers)
        }
        await progress("Separo le voci…")
        let samples = try loadSamples(url)
        let result = try diarizer.performCompleteDiarization(samples)
        let turns = result.segments.map {
            SpeakerTurn(speakerId: String(describing: $0.speakerId),
                        start: Double($0.startTimeSeconds),
                        end: Double($0.endTimeSeconds))
        }
        guard !turns.isEmpty else { throw DiarizationFailure.noVoices }
        return turns
    }

    /// Impronta vocale da un file (tutto) o da alcuni intervalli (massimo 30 secondi).
    static func embedding(url: URL, ranges: [(Double, Double)]? = nil) async throws -> [Float] {
        let diarizer = try await makeDiarizer()
        let all = try loadSamples(url)
        var samples: [Float] = []
        if let ranges {
            let limit = Int(30 * sampleRate)
            for (start, end) in ranges.sorted(by: { ($0.1 - $0.0) > ($1.1 - $1.0) }) {
                let a = max(0, Int(start * sampleRate))
                let b = min(all.count, Int(end * sampleRate))
                guard b > a else { continue }
                samples.append(contentsOf: all[a..<b])
                if samples.count >= limit { break }
            }
        } else {
            samples = all
        }
        guard samples.count >= Int(3 * sampleRate) else { throw DiarizationFailure.tooShort }
        return try diarizer.extractEmbedding(samples)
    }

    /// Assegna a ogni frase il parlante che la copre di più.
    static func assign(_ turns: [SpeakerTurn], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.map { segment in
            var best: (id: String, overlap: Double)?
            let segEnd = max(segment.end, segment.start + 0.3)
            for turn in turns {
                let overlap = min(segEnd, turn.end) - max(segment.start, turn.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (turn.speakerId, overlap)
                }
            }
            var s = segment
            if let best {
                s.speaker = best.id
            } else {
                // Nessuna sovrapposizione: il turno più vicino.
                let nearest = turns.min { abs($0.start - segment.start) < abs($1.start - segment.start) }
                s.speaker = nearest?.speakerId
            }
            return s
        }
    }
}
