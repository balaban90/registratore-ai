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
        // L'impronta è quella della voce che parla di più nel campione.
        let result = try diarizer.performCompleteDiarization(samples)
        var durations: [String: Double] = [:]
        for segment in result.segments {
            let id = String(describing: segment.speakerId)
            durations[id, default: 0] += Double(segment.endTimeSeconds) - Double(segment.startTimeSeconds)
        }
        guard let main = durations.max(by: { $0.value < $1.value })?.key,
              let speaker = diarizer.speakerManager.getSpeaker(for: main) else {
            throw DiarizationFailure.tooShort
        }
        return speaker.currentEmbedding
    }

    /// Turni ordinati per inizio, per trovare in fretta chi parla in un istante
    /// (con registrazioni di ore i turni sono migliaia e le parole decine di migliaia).
    struct TurnIndex {
        let turns: [SpeakerTurn]
        private let maxLength: Double

        init(_ turns: [SpeakerTurn]) {
            self.turns = turns.sorted { $0.start < $1.start }
            maxLength = turns.map { $0.end - $0.start }.max() ?? 0
        }

        /// Primo turno che inizia dopo `time`.
        private func upperBound(_ time: Double) -> Int {
            var low = 0, high = turns.count
            while low < high {
                let mid = (low + high) / 2
                if turns[mid].start < time { low = mid + 1 } else { high = mid }
            }
            return low
        }

        /// Parlante che copre di più l'intervallo; se nessuno lo copre, il turno più vicino.
        func speaker(for start: Double, _ end: Double) -> String? {
            guard !turns.isEmpty else { return nil }
            var best: (id: String, overlap: Double)?
            let e = max(end, start + 0.2)
            let ub = upperBound(e)
            var i = ub - 1
            while i >= 0 && turns[i].start >= start - maxLength {
                let turn = turns[i]
                let overlap = min(e, turn.end) - max(start, turn.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (turn.speakerId, overlap) }
                i -= 1
            }
            if let best { return best.id }
            let mid = (start + e) / 2
            let range = max(0, ub - 3)..<min(turns.count, ub + 3)
            return turns[range].min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }?.speakerId
        }
    }

    /// Assegna i parlanti parola per parola: quando nella stessa frase cambia
    /// chi parla, la frase viene divisa. Così una risposta breve detta senza
    /// pausa ("Va bene, verifica a marzo") non finisce nel turno dell'altro.
    /// Le frasi senza orari delle parole (es. già riviste dall'AI) ricevono un solo parlante.
    static func assign(_ turns: [SpeakerTurn], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let index = TurnIndex(turns)
        func speaker(for start: Double, _ end: Double, in _: [SpeakerTurn]) -> String? { index.speaker(for: start, end) }
        var output: [TranscriptSegment] = []
        output.reserveCapacity(segments.count)
        for segment in segments {
            guard let words = segment.words, words.count > 1 else {
                var s = segment
                s.speaker = speaker(for: segment.start, segment.end, in: turns)
                output.append(s)
                continue
            }

            // 1. Un parlante per parola.
            var labels = words.map { speaker(for: $0.start, $0.end, in: turns) }

            // 2. Niente cambi di voce su frammenti minimi (meno di 2 parole e di 0,6 s):
            //    sono quasi sempre errori di confine e vengono assorbiti dal vicino.
            var changed = true
            while changed {
                changed = false
                var runs: [(from: Int, to: Int)] = []
                var a = 0
                for i in 1...labels.count where i == labels.count || labels[i] != labels[a] {
                    runs.append((a, i - 1)); a = i
                }
                guard runs.count > 1 else { break }
                for (k, run) in runs.enumerated() {
                    let count = run.to - run.from + 1
                    let duration = words[run.to].end - words[run.from].start
                    guard count < 2 && duration < 0.6 else { continue }
                    let neighbour = k > 0 ? labels[runs[k - 1].to] : labels[runs[k + 1].from]
                    for i in run.from...run.to { labels[i] = neighbour }
                    changed = true
                    break
                }
            }

            // 3. Una frase per ogni tratto con lo stesso parlante.
            if Set(labels.map { $0 ?? "" }).count == 1 {
                var s = segment
                s.speaker = labels[0]
                output.append(s)
                continue
            }
            var a = 0
            for i in 1...words.count where i == words.count || labels[i] != labels[a] {
                if let piece = TranscriptSegment.make(from: Array(words[a..<i]), speaker: labels[a]) {
                    output.append(piece)
                }
                a = i
            }
        }
        return output
    }
}
