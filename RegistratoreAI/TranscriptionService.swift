import Foundation
import AVFoundation
import Speech
import WhisperKit
import CoreML

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
    /// Preciso quando il suo modello è scaricato, altrimenti Veloce (e intanto scarica il modello con il Wi-Fi).
    case automatic
    /// Riconoscimento vocale di Apple: veloce, nessun download aggiuntivo.
    case fast
    /// Whisper Large v3 Turbo (WhisperKit): più preciso sul parlato colloquiale, più lento.
    case accurate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatico"
        case .fast: return "Veloce"
        case .accurate: return "Preciso"
        }
    }

    static let defaultsKey = "transcriptionEngine"

    static var current: TranscriptionEngine {
        TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .automatic
    }

    /// Motore effettivo da usare adesso. La trascrizione non aspetta mai un download:
    /// finché il modello Preciso non è completo si usa Veloce (il modello si scarica a parte).
    var resolved: TranscriptionEngine {
        switch self {
        case .fast: return .fast
        case .automatic, .accurate: return WhisperModel.isReady ? .accurate : .fast
        }
    }
}

enum TranscriptionService {
    static var requestedLocale: Locale { Locale(identifier: TranscriptionLanguage.current.rawValue) }

    static func transcribe(url: URL, engine: TranscriptionEngine = .current,
                           progress: @escaping @MainActor (String) -> Void) async throws -> [TranscriptSegment] {
        switch engine.resolved {
        case .accurate:
            do {
                return try await transcribeWithWhisper(url: url, progress: progress)
            } catch let error as TranscriptionFailure {
                if Task.isCancelled { throw CancellationError() }
                DiagnosticLog.error(.whisper, "Trascrizione Preciso fallita", error)
                throw error
            } catch {
                // Lavorazione annullata (registrazione eliminata): non si passa al motore Veloce.
                if Task.isCancelled { throw CancellationError() }
                DiagnosticLog.error(.whisper, "Motore Preciso non utilizzabile, passo a Veloce", error)
                // Modello incompleto o danneggiato: lo cancella (verrà riscaricato con il Wi-Fi)
                // e completa comunque la trascrizione con il motore Veloce.
                await MainActor.run { whisper = nil }
                // Cancella il modello solo se i suoi file risultano danneggiati o mancanti.
                let text = String(describing: error)
                if text.contains("mlmodelc") || text.contains("weight.bin") || !WhisperModel.isReady {
                    WhisperModel.discard()
                    DiagnosticLog.warning(.whisper, "Modello Preciso cancellato: verrà riscaricato")
                }
                await progress("Il motore Preciso non è disponibile: uso il motore Veloce…")
                return try await transcribeWithApple(url: url, progress: progress)
            }
        default:
            return try await transcribeWithApple(url: url, progress: progress)
        }
    }

    // MARK: - Whisper

    @MainActor private static var whisper: WhisperKit?
    @MainActor private static var loading: Task<WhisperKit, Error>?

    /// Avanzamento reale della trascrizione in corso (0…1), letto dal motore. nil se non si sta trascrivendo.
    @MainActor static var liveFraction: Double?

    /// La prima preparazione del motore Preciso dopo ogni installazione dura minuti: iOS adatta il modello
    /// al chip del telefono e lo tiene da parte. Dalla seconda volta in poi bastano pochi secondi.
    /// Qui si ricorda per quale versione dell'app la preparazione è già stata fatta.
    static let preparedBuildKey = "whisperPreparedBuild"
    nonisolated static var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    nonisolated static var isPreparedForThisVersion: Bool {
        UserDefaults.standard.string(forKey: preparedBuildKey) == currentBuild
    }

    /// Secondi che ci si aspetta per preparare il motore Preciso adesso (0 se è già pronto in memoria).
    @MainActor static var expectedPreparation: TimeInterval {
        if whisper != nil { return 0 }
        return isPreparedForThisVersion ? 10 : 210
    }

    @MainActor static var isLoaded: Bool { whisper != nil }

    /// Dopo un aggiornamento dell'app, prepara subito il motore Preciso (la parte lunga, una volta sola),
    /// così la prima registrazione non deve aspettare. Non cambia nulla nella precisione.
    @MainActor
    static func prepareAfterUpdate() {
        guard !TestSupport.isTesting, WhisperModel.isReady, TranscriptionEngine.current.resolved == .accurate,
              !isPreparedForThisVersion, whisper == nil, loading == nil else { return }
        Task { @MainActor in
            let started = Date.now
            DiagnosticLog.info(.whisper, "Preparo il motore Preciso per la nuova versione")
            do {
                _ = try await loadWhisper()
                DiagnosticLog.info(.whisper, "Motore Preciso preparato dopo l'aggiornamento in \(Int(Date.now.timeIntervalSince(started))) s")
                // Se nel frattempo non è partita una trascrizione, si libera la memoria: la prossima volta
                // il motore si ricarica in pochi secondi.
                if !Pipeline.shared.isBusy { releaseMemory() }
            } catch {
                DiagnosticLog.warning(.whisper, "Preparazione dopo l'aggiornamento non riuscita: \(DiagnosticLog.describe(error))")
            }
        }
    }

    /// Prepara il motore Preciso mentre si registra: l'app in quel momento è attiva
    /// (anche a schermo bloccato), così a fine registrazione la trascrizione parte subito.
    @MainActor
    static func prewarm() {
        guard TranscriptionEngine.current.resolved == .accurate, whisper == nil, loading == nil else { return }
        Task { @MainActor in
            let started = Date.now
            do {
                _ = try await loadWhisper()
                DiagnosticLog.info(.whisper, "Motore Preciso preparato in anticipo in \(Int(Date.now.timeIntervalSince(started))) s")
            } catch {
                DiagnosticLog.warning(.whisper, "Preparazione anticipata non riuscita: \(DiagnosticLog.describe(error))")
            }
        }
    }

    /// Libera la memoria del motore Preciso (si ricarica in pochi secondi quando serve).
    @MainActor
    static func releaseMemory() {
        guard loading == nil, whisper != nil else { return }
        whisper = nil
        DiagnosticLog.info(.whisper, "Motore Preciso scaricato dalla memoria")
    }

    @MainActor
    private static func loadWhisper() async throws -> WhisperKit {
        if let whisper { return whisper }
        if let loading { return try await loading.value }
        // Niente GPU: in background iOS non la concede. Lo spettrogramma va sulla CPU (è leggero),
        // il resto sul Neural Engine.
        let compute = ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine,
                                          textDecoderCompute: .cpuAndNeuralEngine)
        let config = WhisperKitConfig(model: WhisperModel.variant, downloadBase: WhisperModel.base,
                                      modelFolder: WhisperModel.folder.path, tokenizerFolder: WhisperModel.base,
                                      computeOptions: compute, download: false)
        let task = Task.detached(priority: .userInitiated) { try await WhisperKit(config) }
        loading = task
        defer { loading = nil }
        let pipe = try await task.value
        whisper = pipe
        UserDefaults.standard.set(currentBuild, forKey: preparedBuildKey)
        return pipe
    }

    private static func transcribeWithWhisper(url: URL, progress: @escaping @MainActor (String) -> Void) async throws -> [TranscriptSegment] {
        let ready = await MainActor.run { whisper != nil }
        if !ready {
            let firstTime = !isPreparedForThisVersion
            await progress(firstTime ? "Preparo il motore Preciso (dopo un aggiornamento serve qualche minuto)…"
                                     : "Preparo il motore Preciso…")
        }
        let started = Date.now
        let pipe = try await loadWhisper()
        if !ready { DiagnosticLog.info(.whisper, "Motore Preciso pronto in \(Int(Date.now.timeIntervalSince(started))) s") }

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

        await progress("Trascrivo con il motore Preciso…")
        // Avanzamento vero, letto dal motore ogni secondo.
        await MainActor.run { liveFraction = 0 }
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                let f = pipe.progress.fractionCompleted
                if f.isFinite, f > 0 { liveFraction = min(1, max(liveFraction ?? 0, f)) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { poller.cancel() }
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        await MainActor.run { liveFraction = 1 }

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

        // Rete di sicurezza: cerca i tratti in cui si sente una voce ma non c'è testo
        // (es. l'inizio, se il motore lo salta) e i silenzi lunghi, e li ritrascrive.
        // Prima con lo stesso motore Preciso (stessa qualità), poi con il Veloce se non trova nulla.
        // Si ritrascrivono solo quei tratti, non tutta la registrazione.
        let duration = audioDuration(url)
        let holes = holesToCheck(url: url, segments: segments, duration: duration)
        if !holes.isEmpty {
            await progress("Controllo che non manchi nessuna parte…")
            let gapStarted = Date.now
            var recovered: [TranscriptSegment] = []
            var byPrecise = 0
            for hole in holes {
                try Task.checkCancellation()
                guard let piece = try? excerpt(of: url, from: hole.0 - 1, to: hole.1 + 1) else { continue }
                defer { try? FileManager.default.removeItem(at: piece.url) }
                var found = await whisperPiece(pipe, url: piece.url, language: options.language)
                if found.isEmpty {
                    found = (try? await transcribeWithApple(url: piece.url, tracksProgress: false, progress: { _ in })) ?? []
                } else {
                    byPrecise += 1
                }
                recovered += found.map { shifted($0, by: piece.offset) }
            }
            let before = segments.count
            segments = merge(segments, with: recovered)
            DiagnosticLog.info(.whisper, "Tratti controllati: \(holes.count) (\(Int(holes.reduce(0) { $0 + $1.1 - $1.0 })) s) · frasi recuperate \(segments.count - before) · col Preciso \(byPrecise) · \(Int(Date.now.timeIntervalSince(gapStarted))) s")
        }

        guard !segments.isEmpty else { throw TranscriptionFailure.empty }
        return segments
    }

    /// Buco minimo (in secondi) oltre il quale si prova a recuperare il parlato.
    private static let minGap = 6.0

    /// Tratti da ricontrollare: silenzi lunghi del testo e tratti con voce non trascritti. Al massimo 40.
    static func holesToCheck(url: URL, segments: [TranscriptSegment], duration: Double) -> [(Double, Double)] {
        var holes = gaps(in: segments, duration: duration)
        if let levels = try? energyLevels(url: url, frame: levelFrame) {
            holes += uncoveredSpeech(levels: levels, frame: levelFrame, segments: segments)
        }
        return Array(mergeRanges(holes).prefix(40))
    }

    static let levelFrame = 0.25

    /// Volume medio (RMS) dell'audio ogni `frame` secondi, letto a pezzi per non riempire la memoria.
    static func energyLevels(url: URL, frame: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let perFrame = AVAudioFrameCount(max(1, format.sampleRate * frame))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: perFrame * 64) else { return [] }
        var levels: [Float] = []
        levels.reserveCapacity(Int(Double(file.length) / Double(perFrame)) + 1)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: perFrame * 64)
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            let channels = Int(format.channelCount)
            var i = 0
            while i < n {
                let end = min(n, i + Int(perFrame))
                var sum: Float = 0
                for c in 0..<channels {
                    let ch = data[c]
                    for k in i..<end { sum += ch[k] * ch[k] }
                }
                levels.append(sqrt(sum / Float(max(1, (end - i) * channels))))
                i = end
            }
        }
        return levels
    }

    /// Tratti di almeno `minSpeech` secondi in cui il volume è da voce ma nessuna frase li copre.
    /// La soglia si adatta al rumore di fondo della registrazione.
    static func uncoveredSpeech(levels: [Float], frame: Double, segments: [TranscriptSegment],
                                minSpeech: Double = 1.5) -> [(Double, Double)] {
        guard levels.count > 8 else { return [] }
        let sorted = levels.sorted()
        let noise = sorted[Int(Double(sorted.count - 1) * 0.15)]
        let median = sorted[sorted.count / 2]
        // Sopra il rumore di fondo, ma mai sopra metà del volume tipico (registrazioni con poche pause).
        let threshold = max(min(noise * 3.2, median * 0.5), 0.004)
        var covered = [Bool](repeating: false, count: levels.count)
        for s in segments {
            let a = max(0, Int((s.start - 0.4) / frame))
            let b = min(levels.count, Int(((s.end + 0.4) / frame).rounded(.up)))
            if a < b { for i in a..<b { covered[i] = true } }
        }
        var result: [(Double, Double)] = []
        var start: Int?
        var last = 0
        var voiced = 0
        func close() {
            if let s = start, Double(voiced) * frame >= minSpeech {
                result.append((Double(s) * frame, Double(last + 1) * frame))
            }
            start = nil
            voiced = 0
        }
        for i in levels.indices {
            if covered[i] {
                if start != nil { close() }
                continue
            }
            if levels[i] > threshold {
                if start == nil { start = i }
                last = i
                voiced += 1
            } else if start != nil && i - last > 3 {
                close()   // pausa di oltre 0,75 s: il tratto finisce
            }
        }
        close()
        return result
    }

    static func mergeRanges(_ ranges: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for r in ranges.sorted(by: { $0.0 < $1.0 }) where r.1 > r.0 {
            if let last = out.last, r.0 <= last.1 + 1 {
                out[out.count - 1].1 = max(last.1, r.1)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Trascrive un tratto breve con il motore Preciso, tenendo solo le frasi affidabili
    /// (niente testo inventato su musica o rumore).
    private static func whisperPiece(_ pipe: WhisperKit, url: URL, language: String?) async -> [TranscriptSegment] {
        var o = DecodingOptions()
        o.task = .transcribe
        o.language = language
        o.temperature = 0
        o.skipSpecialTokens = true
        o.wordTimestamps = true
        guard let results = try? await pipe.transcribe(audioPath: url.path, decodeOptions: o) else { return [] }
        var out: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments where seg.noSpeechProb < 0.6 && seg.avgLogprob > -1.0 && seg.compressionRatio < 2.4 {
                let words = (seg.words ?? []).map {
                    TranscriptWord(text: $0.word, start: Double($0.start), end: Double($0.end),
                                   confidence: Double($0.probability))
                }
                if let segment = TranscriptSegment.make(from: words) {
                    out.append(segment)
                } else {
                    let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { out.append(TranscriptSegment(start: Double(seg.start), end: Double(seg.end), text: text)) }
                }
            }
        }
        return out
    }

    /// Aggiunge le frasi recuperate senza doppioni: delle frasi con gli orari delle parole si tengono
    /// solo le parole che cadono fuori dal testo già presente; le altre entrano se stanno per lo più fuori.
    static func merge(_ segments: [TranscriptSegment], with recovered: [TranscriptSegment]) -> [TranscriptSegment] {
        func inside(_ t: Double) -> Bool { segments.contains { t > $0.start + 0.1 && t < $0.end - 0.1 } }
        var extra: [TranscriptSegment] = []
        for r in recovered {
            if let words = r.words, !words.isEmpty {
                let kept = words.filter { !inside(($0.start + $0.end) / 2) }
                guard kept.count >= 1, let seg = TranscriptSegment.make(from: kept) else { continue }
                // Una parola sola di una o due lettere è quasi sempre un residuo: si scarta.
                if kept.count == 1 && seg.text.count < 3 { continue }
                extra.append(seg)
            } else {
                let span = max(0.1, r.end - r.start)
                let steps = 10
                let outside = (0..<steps).filter { !inside(r.start + span * (Double($0) + 0.5) / Double(steps)) }.count
                if Double(outside) / Double(steps) >= 0.6 { extra.append(r) }
            }
        }
        // Le frasi recuperate non devono sovrapporsi tra loro (tratti contigui ritrascritti due volte).
        var accepted: [TranscriptSegment] = []
        for e in extra.sorted(by: { $0.start < $1.start }) {
            if let last = accepted.last, e.start < last.end - 0.2 { continue }
            accepted.append(e)
        }
        return (segments + accepted).sorted { $0.start < $1.start }
    }

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

    /// Inserisce le frasi del secondo motore che cadono interamente nei buchi del primo.
    static func fillGaps(_ segments: [TranscriptSegment], with other: [TranscriptSegment], duration: Double) -> [TranscriptSegment] {
        let holes = gaps(in: segments, duration: max(duration, other.last?.end ?? 0))
        let extra = other.filter { seg in
            holes.contains { seg.start >= $0.0 - 0.5 && seg.end <= $0.1 + 0.5 }
        }
        return (segments + extra).sorted { $0.start < $1.start }
    }

    /// Copia un tratto dell'audio in un file temporaneo (per trascrivere solo quel pezzo).
    static func excerpt(of url: URL, from start: Double, to end: Double) throws -> (url: URL, offset: Double) {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tratto-\(UUID().uuidString).caf")
        let offset: Double
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let rate = format.sampleRate
            let a = AVAudioFramePosition(max(0, start) * rate)
            let b = min(file.length, AVAudioFramePosition(max(0, end) * rate))
            guard b > a else { throw TranscriptionFailure.empty }
            file.framePosition = a
            offset = Double(a) / rate
            let writer = try AVAudioFile(forWriting: out, settings: format.settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            var remaining = AVAudioFrameCount(b - a)
            while remaining > 0 {
                let n = min(AVAudioFrameCount(65_536), remaining)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { break }
                try file.read(into: buffer, frameCount: n)
                if buffer.frameLength == 0 { break }
                try writer.write(from: buffer)
                remaining -= buffer.frameLength
            }
        }
        return (out, offset)
    }

    /// Sposta gli orari di una frase (trascritta da un tratto) alla posizione nella registrazione intera.
    static func shifted(_ segment: TranscriptSegment, by offset: Double) -> TranscriptSegment {
        var s = segment
        s.start += offset
        s.end += offset
        s.words = segment.words?.map { var w = $0; w.start += offset; w.end += offset; return w }
        return s
    }

    // MARK: - Apple (SpeechAnalyzer, iOS 26)

    private static func transcribeWithApple(url: URL, tracksProgress: Bool = true,
                                            progress: @escaping @MainActor (String) -> Void) async throws -> [TranscriptSegment] {
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
        let totalSeconds = max(1, Double(file.length) / file.processingFormat.sampleRate)
        if tracksProgress { await MainActor.run { liveFraction = 0 } }

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
                    if tracksProgress {
                        let done = min(1, segment.end / totalSeconds)
                        await MainActor.run { liveFraction = max(liveFraction ?? 0, done) }
                    }
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
