import Foundation
import SwiftData
import AVFoundation

/// Modalità di prova usata solo dai test automatici (GitHub Actions, simulatore).
/// Nell'uso normale non è mai attiva: si accende solo con argomenti di avvio che l'app
/// non riceve mai sull'iPhone.
///
/// - `-UITest`: archivio in memoria, nessun invio di diagnostica, nessun controllo aggiornamenti.
/// - `-UITestSeed long`: una registrazione di 2 ore con 1.800 frasi, 4 parlanti, sintesi e
///   segnalibri, più 40 registrazioni brevi nell'elenco.
/// - `-UITestSeed pending` con `-UITestFakeProcessing N`: una registrazione da lavorare con una
///   lavorazione finta di N passi da un secondo (serve a verificare il lavoro in background).
enum TestSupport {
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isUITest: Bool { arguments.contains("-UITest") }
    /// Test unitari: l'app fa da contenitore ai test.
    static var isUnitTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
    static var isTesting: Bool { isUITest || isUnitTest }

    private static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static var seedKind: String? { isUITest ? value(after: "-UITestSeed") : nil }
    static var fakeProcessingSteps: Int { isUITest ? Int(value(after: "-UITestFakeProcessing") ?? "") ?? 0 : 0 }

    static let longTitle = "Riunione di prova lunga"
    static let pendingTitle = "Registrazione da lavorare"
    static let fakeSummaryText = "Sintesi di prova completata in background."

    // MARK: - Lavorazione finta

    /// Passi da un secondo: se iOS sospende l'app, i passi si fermano e la prova lo rileva.
    static func fakeWork(steps: Int, progress: @escaping @MainActor (String) -> Void) async throws {
        let started = Date.now
        for step in 1...steps {
            await progress("Prova: passo \(step) di \(steps)…")
            try await Task.sleep(for: .seconds(1))
        }
        DiagnosticLog.info(.pipeline, "Lavorazione di prova: \(steps) passi in \(Int(Date.now.timeIntervalSince(started))) s")
    }

    // MARK: - Dati di prova

    @MainActor
    static func seed(into context: ModelContext) {
        switch seedKind {
        case "long": seedLong(into: context)
        case "pending": seedPending(into: context)
        default: break
        }
        try? context.save()
    }

    @MainActor
    private static func seedLong(into context: ModelContext) {
        let longAudio = "prova-lunga.m4a"
        let shortAudio = "prova-breve.m4a"
        writeSilence(fileName: longAudio, seconds: 2 * 3600)
        writeSilence(fileName: shortAudio, seconds: 20)

        let main = Recording(title: longTitle, audioFileName: longAudio, duration: 2 * 3600,
                             inputName: "Microfono iPhone",
                             highlights: [300, 900, 1500, 2400, 3000, 3600, 4300, 5000, 6100, 7000],
                             createdAt: .now.addingTimeInterval(-3600))
        let segments = syntheticSegments(duration: 2 * 3600, speakers: ["S1", "S2", "S3", "S4"], seed: 7)
        main.segments = segments
        main.originalSegments = segments
        main.diarized = true
        main.revisedByClaude = true
        main.speakerNames = ["S1": "Marco", "S2": "Giulia"]
        main.transcript = main.plainTranscript
        main.notes = "Note di prova."
        context.insert(main)
        let summary = Summary(templateID: "sintesi", templateName: "Sintesi veloce", text: longSummary)
        summary.recording = main
        context.insert(summary)
        let second = Summary(templateID: "riunione", templateName: "Riunione · AI", text: longSummary + "\n\n" + longSummary, costUSD: 0.02)
        second.recording = main
        second.createdAt = .now.addingTimeInterval(-60)
        context.insert(second)

        for n in 1...40 {
            let r = Recording(title: "Appunto di prova \(n)", audioFileName: shortAudio, duration: 20,
                              inputName: "Microfono iPhone", createdAt: .now.addingTimeInterval(Double(-n) * 86_400 / 3))
            let segs = syntheticSegments(duration: 20, speakers: ["A"], seed: UInt64(n + 100))
            r.segments = segs
            r.transcript = r.plainTranscript
            context.insert(r)
            let s = Summary(templateID: "sintesi", templateName: "Sintesi veloce",
                            text: "**Di cosa si parla:** appunto numero \(n) sulla prova automatica dell'elenco.\n\n- Punto uno\n- Punto due")
            s.recording = r
            context.insert(s)
        }
    }

    @MainActor
    private static func seedPending(into context: ModelContext) {
        let audio = "prova-breve.m4a"
        writeSilence(fileName: audio, seconds: 20)
        let r = Recording(title: pendingTitle, audioFileName: audio, duration: 20, inputName: "Microfono iPhone")
        r.segments = syntheticSegments(duration: 20, speakers: ["A"], seed: 3)
        r.transcript = r.plainTranscript
        r.pipelinePending = true
        context.insert(r)
    }

    /// Frasi realistiche (parole con orari e affidabilità), deterministiche.
    static func syntheticSegments(duration: Double, speakers: [String], seed: UInt64) -> [TranscriptSegment] {
        var rng = SeededGenerator(seed: seed)
        let vocabulary = ["allora", "dunque", "riunione", "progetto", "contratto", "turni", "reparto", "personale",
                          "proposta", "azienda", "lavoratori", "giovedì", "marzo", "verifica", "budget", "orario",
                          "straordinari", "ferie", "accordo", "punto", "secondo", "terzo", "quindi", "decisione",
                          "domanda", "risposta", "infermieri", "medici", "pazienti", "sicurezza", "formazione",
                          "documento", "tabella", "numeri", "settimana", "mese", "anno", "giusto", "esatto", "bene"]
        var segments: [TranscriptSegment] = []
        var time = 0.5
        var speaker = speakers.first
        while time < duration - 1 {
            if speakers.count > 1, Int.random(in: 0..<4, using: &rng) == 0 {
                speaker = speakers.randomElement(using: &rng)
            }
            let count = Int.random(in: 6...18, using: &rng)
            var words: [TranscriptWord] = []
            for i in 0..<count {
                let w = vocabulary.randomElement(using: &rng)!
                let length = Double.random(in: 0.18...0.42, using: &rng)
                let text = (i == 0 ? w.prefix(1).uppercased() + w.dropFirst() : " " + w) + (i == count - 1 ? "." : "")
                let confidence = Int.random(in: 0..<25, using: &rng) == 0 ? 0.3 : 0.92
                words.append(TranscriptWord(text: text, start: time, end: min(time + length, duration), confidence: confidence))
                time += length + 0.05
            }
            if var segment = TranscriptSegment.make(from: words, speaker: speakers.count > 1 ? speaker : nil) {
                // Come dopo il miglioramento AI: niente parole con orario (più leggero), testo intatto.
                if speakers.count > 1 && segments.count % 3 == 0 { segment.words = nil }
                segments.append(segment)
            }
            time += Double.random(in: 0.3...1.5, using: &rng)
        }
        return segments
    }

    /// File audio di silenzio (AAC mono 16 kHz), per provare il riproduttore con file lunghi.
    static func writeSilence(fileName: String, seconds: Int) {
        let url = Storage.url(for: fileName)
        if FileManager.default.fileExists(atPath: url.path) { return }
        let rate = 16_000.0
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24_000]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate * 10)) else { return }
        buffer.frameLength = buffer.frameCapacity
        var written = 0
        while written < seconds {
            try? file.write(from: buffer)
            written += 10
        }
    }

    private static let longSummary = """
    # Sintesi

    **Di cosa si parla:** riunione di prova lunga per verificare le prestazioni dell'app con registrazioni di ore.

    ## Punti principali
    - Organizzazione dei turni del reparto e straordinari del mese di marzo.
    - Proposta dell'azienda sul nuovo accordo e risposta dei lavoratori.
    - Formazione obbligatoria sulla sicurezza entro la fine dell'anno.
    - Verifica del budget e della tabella degli orari.

    ## Decisioni
    1. Nuovo incontro giovedì prossimo.
    2. Documento condiviso con tutto il personale.

    ## Azioni da fare
    - [ ] Marco: preparare i numeri aggiornati.
    - [ ] Giulia: inviare la convocazione.
    - [x] Raccogliere le domande dei colleghi.
    """
}

/// Generatore pseudo-casuale ripetibile (stessi dati a ogni prova).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
