import Foundation
import SwiftData
import UIKit

/// Lavorazione automatica di una registrazione, come Plaud: dopo aver registrato
/// fa tutto da sola, senza scelte tecniche.
///
/// 1. Trascrizione (motore scelto automaticamente) + glossario
/// 2. Separazione dei parlanti
/// 3. Miglioramento con l'AI (testo, parlanti, nomi, titolo), se c'è la chiave API
/// 4. Sintesi veloce, che fa da anteprima nell'elenco
/// 5. Titolo, se è ancora quello automatico
@MainActor
final class Pipeline: ObservableObject {
    static let shared = Pipeline()

    static let autoImproveKey = "autoImproveWithAI"
    static let autoSummaryKey = "autoSummary"

    static var autoImprove: Bool { UserDefaults.standard.object(forKey: autoImproveKey) as? Bool ?? true }
    static var autoSummary: Bool { UserDefaults.standard.object(forKey: autoSummaryKey) as? Bool ?? true }

    /// Cosa sta facendo, per registrazione.
    @Published private(set) var status: [UUID: String] = [:]
    /// Ultimo problema incontrato, per registrazione.
    @Published var errors: [UUID: String] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var subjects: [UUID: Recording] = [:]
    private var fractions: [UUID: Double] = [:]
    /// Registrazioni da riprendere alla prossima apertura (es. AI non raggiungibile per la rete).
    private var retryLater: Set<UUID> = []
    /// Registrazioni eliminate durante la lavorazione: si fermano senza segnalare errori.
    private var cancelled: Set<UUID> = []

    func isRunning(_ recording: Recording) -> Bool { tasks[recording.id] != nil }
    func isRunning(id: UUID) -> Bool { tasks[id] != nil }

    /// Ferma la lavorazione di una registrazione che sta per essere eliminata.
    /// Da chiamare prima di cancellarne il file e i dati.
    func cancel(_ recording: Recording) {
        let id = recording.id
        guard let task = tasks[id] else { return }
        cancelled.insert(id)
        task.cancel()
        DiagnosticLog.info(.pipeline, "\(id.uuidString.prefix(8)) registrazione eliminata: lavorazione annullata")
    }

    // MARK: - Lavorazione completa

    /// Esegue i passaggi che mancano. Con `retranscribe` riparte dalla trascrizione
    /// (le elaborazioni già fatte restano).
    func process(_ recording: Recording, in context: ModelContext, retranscribe: Bool = false) {
        recording.pipelinePending = true
        try? context.save()
        if TestSupport.fakeProcessingSteps > 0 {
            // Solo nei test automatici: lavorazione finta di durata nota, per verificare il background.
            run(recording, in: context) { [self] in
                try await TestSupport.fakeWork(steps: TestSupport.fakeProcessingSteps) { [weak self] message in
                    self?.report(recording.id, message)
                }
                let summary = Summary(templateID: "sintesi", templateName: "Sintesi veloce", text: TestSupport.fakeSummaryText)
                summary.recording = recording
                context.insert(summary)
                try? context.save()
            }
            return
        }
        run(recording, in: context) { [self] in
            if retranscribe || recording.transcript == nil {
                try await transcribe(recording, in: context)
                // Il motore Preciso occupa molta memoria: lo si libera prima dei passaggi successivi
                // (con registrazioni di ore iOS potrebbe chiudere l'app in background).
                TranscriptionService.releaseMemory()
            }
            try Task.checkCancellation()
            if DiarizationService.isEnabled && !recording.diarized {
                await diarizeQuietly(recording, in: context)
            }
            try Task.checkCancellation()
            var improvedNow = false
            if Self.autoImprove && !recording.revisedByClaude {
                if ClaudeService.isConfigured {
                    improvedNow = await improveQuietly(recording, in: context, applyNames: true)
                } else {
                    DiagnosticLog.warning(.ai, "\(recording.id.uuidString.prefix(8)) miglioramento saltato: chiave AI avanzata non disponibile")
                }
            }
            try Task.checkCancellation()
            // La sintesi fatta prima del miglioramento (es. AI non raggiungibile) si rifà sul testo migliorato,
            // con i nomi delle persone.
            if improvedNow {
                for old in recording.summaries where old.templateID == "sintesi" {
                    context.delete(old)
                }
                try? context.save()
            }
            if Self.autoSummary && !recording.summaries.contains(where: { $0.templateID == "sintesi" }) {
                await summaryQuietly(recording, in: context)
            }
            try Task.checkCancellation()
            if recording.hasDefaultTitle {
                await titleQuietly(recording, in: context)
            }
        }
    }

    /// Solo la separazione dei parlanti (dal menu della registrazione).
    func separateSpeakers(_ recording: Recording, in context: ModelContext) {
        run(recording, in: context) { [self] in try await diarize(recording, in: context) }
    }

    /// Solo il miglioramento con l'AI (dal menu della registrazione).
    func improve(_ recording: Recording, in context: ModelContext) {
        run(recording, in: context) { [self] in try await revise(recording, in: context, applyNames: true) }
    }

    /// Riprende le registrazioni rimaste a metà (es. app chiusa durante la trascrizione).
    func resumePending(_ recordings: [Recording], in context: ModelContext) {
        for r in recordings where (r.pipelinePending || (r.transcript == nil && r.transcriptionError == nil)) && !isRunning(r) {
            DiagnosticLog.info(.pipeline, "\(r.id.uuidString.prefix(8)) riprendo la lavorazione rimasta a metà")
            process(r, in: context)
        }
    }

    /// Come sopra, cercando da sé le registrazioni (all'apertura dell'app e a ogni ritorno in primo piano).
    func resumePending(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        resumePending(all, in: context)
    }

    /// Avvia un lavoro sulla registrazione (interno: usato dai passaggi qui sopra e dalle prove automatiche).
    func run(_ recording: Recording, in context: ModelContext, _ work: @escaping () async throws -> Void) {
        guard tasks[recording.id] == nil else { return }
        let id = recording.id
        errors[id] = nil
        subjects[id] = recording
        fractions[id] = 0
        BackgroundWork.shared.begin(title: "Registratore AI")
        let tag = id.uuidString.prefix(8)
        let started = Date.now
        DiagnosticLog.info(.pipeline, "\(tag) inizio lavorazione · durata audio \(formatTime(recording.duration)) · file \(DiagnosticLog.fileSize(recording.audioURL))")
        tasks[id] = Task {
            var success = true
            do {
                try await work()
            } catch let error where !cancelled.contains(id) {
                success = false
                errors[id] = Self.readable(error)
                DiagnosticLog.error(.pipeline, "\(tag) lavorazione interrotta", error)
            } catch {
                // Registrazione eliminata: nessun errore da segnalare.
            }
            if cancelled.remove(id) != nil {
                // La registrazione non esiste più: non si toccano i suoi dati.
                DiagnosticLog.info(.pipeline, "\(tag) fine lavorazione (annullata) in \(Int(Date.now.timeIntervalSince(started))) s")
                retryLater.remove(id)
                errors[id] = nil
                status[id] = nil
                tasks[id] = nil
                subjects[id] = nil
                fractions[id] = nil
                LiveActivityManager.shared.dismiss(id)
                BackgroundWork.shared.end(success: true)
                return
            }
            DiagnosticLog.info(.pipeline, "\(tag) fine lavorazione (\(success ? "ok" : "con errori")) in \(Int(Date.now.timeIntervalSince(started))) s")
            recording.pipelinePending = retryLater.remove(id) != nil
            try? context.save()
            status[id] = nil
            tasks[id] = nil
            subjects[id] = nil
            fractions[id] = nil
            LiveActivityManager.shared.finished(recording, success: success)
            BackgroundWork.shared.end(success: success)
            WhisperModel.shared.downloadIfAppropriate()
            if !success || errors[id] != nil {
                DiagnosticUploader.shared.sendIfNeeded(reason: "errore nella lavorazione")
            }
        }
    }

    /// Avanzamento indicativo per fase, mostrato nella Dynamic Island e nel sistema.
    private static func fraction(for text: String) -> Double? {
        let t = text.lowercased()
        if t.contains("trascriv") || t.contains("motore") || t.contains("riconoscimento") { return 0.15 }
        if t.contains("manchi") { return 0.45 }
        if t.contains("voci") || t.contains("chi parla") { return 0.55 }
        if t.contains("migliora") { return 0.7 }
        if t.contains("sintesi") || t.contains("parte") || t.contains("elaborazione") { return 0.88 }
        return nil
    }

    private func report(_ id: UUID, _ text: String) {
        guard !cancelled.contains(id) else { return }
        if status[id] != text { DiagnosticLog.info(.pipeline, "\(id.uuidString.prefix(8)) \(text)") }
        status[id] = text
        if let f = Self.fraction(for: text) { fractions[id] = max(fractions[id] ?? 0, f) }
        let f = fractions[id] ?? 0
        if let recording = subjects[id] {
            LiveActivityManager.shared.processing(recording, status: text, progress: f)
        }
        BackgroundWork.shared.update(text, fraction: f)
    }

    private func say(_ recording: Recording, _ text: String) { report(recording.id, text) }

    /// Messaggio comprensibile: i dettagli tecnici lunghi (percorsi di file, codici) non servono all'utente.
    static func readable(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.count <= 160 && !text.contains("/private/") && !text.contains("/var/") { return text }
        return "Si è verificato un problema tecnico. Riprova con ⋯ > Rifai la trascrizione."
    }

    // MARK: - Passaggi

    private func glossary(_ context: ModelContext) -> [GlossaryEntry] {
        (try? context.fetch(FetchDescriptor<GlossaryEntry>())) ?? []
    }

    private func transcribe(_ recording: Recording, in context: ModelContext) async throws {
        let id = recording.id
        say(recording, "Trascrivo…")
        let engine = TranscriptionEngine.current
        let started = Date.now
        DiagnosticLog.info(.transcription, "Motore richiesto \(engine.rawValue) → \(engine.resolved.rawValue) · lingua \(TranscriptionLanguage.current.rawValue)")
        do {
            let segments = try await TranscriptionService.transcribe(url: recording.audioURL) { [weak self] message in
                self?.report(id, message)
            }
            recording.segments = Glossary.apply(glossary(context), to: segments)
            recording.originalSegments = []
            recording.revisedByClaude = false
            recording.diarized = false
            recording.speakerNames = [:]
            recording.speakerSuggestions = [:]
            recording.transcript = recording.plainTranscript
            recording.transcriptionError = nil
            try? context.save()
            let words = recording.transcript?.split(separator: " ").count ?? 0
            let uncertain = segments.reduce(0) { $0 + ($1.uncertain?.count ?? 0) }
            DiagnosticLog.info(.transcription, "Completata in \(Int(Date.now.timeIntervalSince(started))) s · \(segments.count) frasi · \(words) parole · \(uncertain) parole incerte")
        } catch {
            // Registrazione eliminata durante la trascrizione: non è un errore.
            if Task.isCancelled { throw CancellationError() }
            DiagnosticLog.error(.transcription, "Fallita dopo \(Int(Date.now.timeIntervalSince(started))) s", error)
            recording.transcriptionError = Self.readable(error)
            try? context.save()
            throw error
        }
    }

    private func diarize(_ recording: Recording, in context: ModelContext) async throws {
        guard !recording.segments.isEmpty else { return }
        let id = recording.id
        say(recording, "Riconosco chi parla…")
        let profiles = (try? context.fetch(FetchDescriptor<VoiceProfile>())) ?? []
        let known = profiles.map { KnownVoice(id: $0.speakerKey, name: $0.name, embedding: $0.embedding) }
        let profileNames = Dictionary(profiles.map { ($0.speakerKey, $0.name) }, uniquingKeysWith: { a, _ in a })
        let started = Date.now
        let turns = try await DiarizationService.diarize(url: recording.audioURL, known: known) { [weak self] message in
            self?.report(id, message)
        }
        DiagnosticLog.info(.speakers, "\(turns.count) turni · \(Set(turns.map(\.speakerId)).count) voci · profili noti \(known.count) · \(Int(Date.now.timeIntervalSince(started))) s")
        let entries = glossary(context)
        recording.segments = Glossary.apply(entries, to: DiarizationService.assign(turns, to: recording.segments))
        if recording.revisedByClaude {
            recording.originalSegments = Glossary.apply(entries, to: DiarizationService.assign(turns, to: recording.originalSegments))
        }
        var names: [String: String] = [:]
        for speaker in recording.speakerOrder {
            if let n = profileNames[speaker] { names[speaker] = n }
        }
        recording.speakerNames = names
        recording.speakerSuggestions = [:]
        recording.diarized = true
        recording.speakerNamesUpdatedAt = .now
        recording.transcript = recording.plainTranscript
        try? context.save()
    }

    private func revise(_ recording: Recording, in context: ModelContext, applyNames: Bool) async throws {
        // Si rivede sempre partendo dalla trascrizione automatica originale.
        let base = recording.revisedByClaude ? recording.originalSegments : recording.segments
        guard !base.isEmpty else { return }
        let id = recording.id
        say(recording, "L'AI migliora la trascrizione…")
        let entries = glossary(context)
        let result = try await ClaudeService.revise(
            segments: base,
            speakers: recording.diarized ? recording.speakerOrder : [],
            speakerNames: recording.speakerNames,
            title: recording.title, notes: recording.notes,
            glossaryTerms: Glossary.termsForClaude(entries)
        ) { [weak self] message in
            self?.report(id, message)
        }
        if !recording.revisedByClaude { recording.originalSegments = base }
        var revised = Glossary.apply(entries, to: result.segments)
        // Voci non separate: l'AI può averle distinte lei. Vale solo se le persone sono almeno due.
        if !recording.diarized {
            if Set(revised.compactMap(\.speaker)).count >= 2 {
                recording.diarized = true
            } else {
                revised = revised.map { var s = $0; s.speaker = nil; return s }
            }
        }
        recording.segments = revised
        recording.speakerNamesUpdatedAt = .now
        // Nomi o ruoli proposti: applicati subito a chi non ha già un nome (restano modificabili).
        let order = Set(recording.speakerOrder)
        let proposals = result.suggestions.filter { id, _ in
            order.contains(id) && (recording.speakerNames[id] ?? "").isEmpty
        }
        if applyNames {
            var names = recording.speakerNames
            for (speaker, name) in proposals { names[speaker] = name }
            recording.speakerNames = names
            recording.speakerSuggestions = [:]
        } else {
            recording.speakerSuggestions = proposals
        }
        if recording.hasDefaultTitle, let title = result.title, !title.isEmpty {
            recording.title = title
        }
        DiagnosticLog.info(.ai, "Miglioramento: \(base.count) frasi → \(revised.count) · nomi proposti \(proposals.count)")
        recording.revisedByClaude = true
        recording.transcript = recording.plainTranscript
        try? context.save()
    }

    private func diarizeQuietly(_ recording: Recording, in context: ModelContext) async {
        do { try await diarize(recording, in: context) } catch {
            if Task.isCancelled { return }
            DiagnosticLog.error(.speakers, "Separazione parlanti fallita", error)
            // Una voce sola non è un errore. Negli altri casi (es. modelli non ancora scaricati
            // per mancanza di rete) si riprova da solo alla prossima apertura.
            if (error as? DiarizationFailure) == .noVoices { return }
            errors[recording.id] = "Parlanti: \(Self.readable(error))"
            retryLater.insert(recording.id)
        }
    }

    /// true se il miglioramento è riuscito.
    @discardableResult
    private func improveQuietly(_ recording: Recording, in context: ModelContext, applyNames: Bool) async -> Bool {
        do {
            try await revise(recording, in: context, applyNames: applyNames)
            return recording.revisedByClaude
        } catch {
            if Task.isCancelled { return false }
            DiagnosticLog.error(.ai, "Miglioramento fallito", error)
            errors[recording.id] = "Miglioramento AI: \(Self.readable(error))"
            // Si riprova da solo alla prossima apertura dell'app, salvo i problemi che non si risolvono
            // ritentando (chiave non valida, credito esaurito): lì serve l'utente.
            if Self.worthRetrying(error) { retryLater.insert(recording.id) }
            return false
        }
    }

    /// Problemi passeggeri (rete, servizio occupato, app sospesa da iOS) che conviene ritentare.
    static func worthRetrying(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let failure = error as? ClaudeFailure {
            switch failure {
            case .missingKey: return false
            case .http(let code, let message):
                let lower = message.lowercased()
                if lower.contains("credit") || lower.contains("balance") { return false }
                return code != 401 && code != 403
            case .emptyResponse: return true
            }
        }
        let text = String(describing: error).lowercased()
        let permanent = ["credit", "credito", "invalid x-api-key", "authentication", "chiave", "missingkey", "permission"]
        return !permanent.contains { text.contains($0) }
    }

    /// Sintesi veloce: sul dispositivo (gratis); se non è disponibile o non riesce, con l'AI avanzata.
    /// In background iOS limita l'AI sul dispositivo: in quel caso la sintesi si completa
    /// da sola appena si apre l'app, senza spendere credito.
    private func summaryQuietly(_ recording: Recording, in context: ModelContext) async {
        let template = SummaryTemplate.byID("sintesi")
        let id = recording.id
        guard let transcript = recording.transcript, !transcript.isEmpty else { return }
        say(recording, "Preparo la sintesi…")
        let started = Date.now
        // Testi lunghi: sul dispositivo vanno letti a pezzi, uno dopo l'altro (lento, e in background
        // iOS spesso lo interrompe). Con l'AI avanzata la sintesi è pronta in pochi secondi, con il
        // modello più economico (pochi centesimi), e tiene conto di chi parla.
        let long = transcript.count > SummaryService.chunkChars * 2
        let inBackgroundNow = UIApplication.shared.applicationState != .active
        let preferCloud = ClaudeService.isConfigured && (long || inBackgroundNow)
        if preferCloud {
            DiagnosticLog.info(.ai, "Sintesi con l'AI avanzata · \(transcript.count) caratteri\(inBackgroundNow ? " · app in background" : "")")
        }
        if !preferCloud && SummaryService.availabilityMessage == nil {
            do {
                let text = try await SummaryService.summarize(transcript: transcript, template: template,
                                                              userContext: recording.userContext) { [weak self] message in
                    self?.report(id, message)
                }
                let summary = Summary(templateID: template.id, templateName: template.name, text: text)
                summary.recording = recording
                context.insert(summary)
                try? context.save()
                DiagnosticLog.info(.onDevice, "Sintesi sul dispositivo pronta in \(Int(Date.now.timeIntervalSince(started))) s · \(transcript.count) caratteri")
                return
            } catch {
                let inBackground = UIApplication.shared.applicationState != .active
                DiagnosticLog.warning(.onDevice, "Sintesi sul dispositivo non riuscita dopo \(Int(Date.now.timeIntervalSince(started))) s\(inBackground ? " con l'app in background" : ""): \(DiagnosticLog.describe(error))")
                if inBackground {
                    retryLater.insert(id)
                    return
                }
                guard ClaudeService.isConfigured else {
                    DiagnosticLog.error(.onDevice, "Sintesi veloce fallita", error)
                    errors[id] = "Sintesi: \(Self.readable(error))"
                    return
                }
            }
        } else if !preferCloud {
            DiagnosticLog.info(.onDevice, "AI sul dispositivo non disponibile (\(SummaryService.availabilityMessage ?? "?"))")
        }
        guard ClaudeService.isConfigured else { return }
        do {
            say(recording, "Preparo la sintesi…")
            let reply = try await ClaudeService.summarize(title: recording.title, transcript: recording.compactTranscript,
                                                          template: template, userContext: recording.userContext,
                                                          model: .haiku)
            let summary = Summary(templateID: template.id, templateName: "\(template.name) · AI", text: reply.text, costUSD: reply.costUSD)
            summary.recording = recording
            context.insert(summary)
            try? context.save()
        } catch {
            DiagnosticLog.error(.ai, "Sintesi con l'AI avanzata fallita", error)
            errors[id] = "Sintesi: \(Self.readable(error))"
            if Self.worthRetrying(error) { retryLater.insert(id) }
        }
    }

    /// Titolo dal contenuto, sul dispositivo (gratis). Se non riesce, resta quello con data e ora.
    private func titleQuietly(_ recording: Recording, in context: ModelContext) async {
        guard SummaryService.availabilityMessage == nil else { return }
        let source = recording.sortedSummaries.first?.text ?? recording.transcript ?? ""
        guard source.count > 40 else { return }
        if let title = try? await SummaryService.title(for: source), title.count >= 3, recording.hasDefaultTitle {
            recording.title = title
            try? context.save()
        }
    }
}
