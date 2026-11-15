import Foundation
import SwiftData
import UIKit
import MetricKit

/// Registro diagnostico: annota cosa fa l'app (registrazione, trascrizione, AI, errori)
/// in un file sul telefono. Da Impostazioni > Diagnostica si esporta un rapporto da inviare
/// a chi sviluppa l'app.
///
/// Privacy: non contiene mai audio, testo delle trascrizioni, elaborazioni o la chiave API.
enum DiagnosticLog {
    enum Area: String {
        case app = "APP"
        case recording = "REGISTRAZIONE"
        case transcription = "TRASCRIZIONE"
        case speakers = "PARLANTI"
        case ai = "AI"
        case onDevice = "AI-DISPOSITIVO"
        case whisper = "MOTORE-PRECISO"
        case pipeline = "LAVORAZIONE"
        case crash = "CRASH"
    }

    private static let queue = DispatchQueue(label: "it.registratoreai.diagnostica")
    /// Oltre questa dimensione il registro viene ruotato (si tiene anche il precedente).
    private static let maxBytes = 800_000

    private static var directory: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Diagnostica", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    private static var currentURL: URL { directory.appending(path: "registro.log") }
    private static var previousURL: URL { directory.appending(path: "registro-precedente.log") }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    // MARK: - Scrittura

    static func info(_ area: Area, _ message: String) { write("INFO ", area, message) }
    static func warning(_ area: Area, _ message: String) { write("AVV  ", area, message) }

    static func error(_ area: Area, _ message: String, _ error: Error? = nil) {
        var text = message
        if let error { text += " — \(describe(error))" }
        write("ERR  ", area, text)
        DiagnosticUploader.markPending()
    }

    /// Descrizione tecnica completa dell'errore (tipo, dominio, codice), più utile del messaggio per l'utente.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["\(error.localizedDescription)", "[\(String(reflecting: type(of: error))) \(ns.domain) \(ns.code)]"]
        let raw = String(describing: error)
        if raw != error.localizedDescription { parts.append("dettaglio: \(raw.prefix(600))") }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("causa: \(underlying.domain) \(underlying.code) \(underlying.localizedDescription)")
        }
        return parts.joined(separator: " ")
    }

    private static func write(_ level: String, _ area: Area, _ message: String) {
        let date = Date()
        let clean = sanitize(message)
        queue.async {
            let line = "\(stamp.string(from: date)) \(level)[\(area.rawValue)] \(clean)\n"
            guard let data = line.data(using: .utf8) else { return }
            rotateIfNeeded()
            let url = currentURL
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Toglie dal testo qualsiasi cosa somigli a una chiave API.
    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: #"sk-ant-[A-Za-z0-9_\-]+"#, with: "sk-ant-•••", options: .regularExpression)
    }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: currentURL.path))?[.size] as? Int,
              size > maxBytes else { return }
        try? fm.removeItem(at: previousURL)
        try? fm.moveItem(at: currentURL, to: previousURL)
    }

    static func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: currentURL)
            try? FileManager.default.removeItem(at: previousURL)
        }
        info(.app, "Registro cancellato dall'utente")
    }

    /// Dimensione attuale del registro, per le Impostazioni.
    static var sizeDescription: String {
        let fm = FileManager.default
        let bytes = [currentURL, previousURL].compactMap {
            (try? fm.attributesOfItem(atPath: $0.path))?[.size] as? Int
        }.reduce(0, +)
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Rapporto da esportare

    /// Crea il file di testo con le informazioni sull'app e il registro, pronto da condividere.
    @MainActor
    static func makeReport(context: ModelContext, reason: String = "esportazione manuale", note: String? = nil, maxLogBytes: Int? = nil) -> URL? {
        queue.sync {} // attende che le ultime righe siano scritte
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        let defaults = UserDefaults.standard

        var r = "RAPPORTO DIAGNOSTICO — Registratore AI\n"
        r += "Creato: \(stamp.string(from: .now)) (\(TimeZone.current.identifier))\n"
        r += "Motivo: \(reason)\n"
        r += "Non contiene audio, testi delle trascrizioni, elaborazioni o la chiave API.\n\n"
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            r += "== NOTA DELL'UTENTE ==\n\(note.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }

        r += "== APP E DISPOSITIVO ==\n"
        r += "Versione app: \(version) (build \(build))\n"
        r += "Dispositivo: \(machineModel()) · \(device.systemName) \(device.systemVersion)\n"
        r += "Lingua sistema: \(Locale.current.identifier)\n"
        r += "Spazio libero: \(freeSpace())\n"
        r += "Modalità risparmio energetico: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "sì" : "no")\n"
        r += "Stato termico: \(thermal())\n\n"

        r += "== IMPOSTAZIONI ==\n"
        r += "Lingua trascrizione: \(TranscriptionLanguage.current.rawValue)\n"
        r += "Motore trascrizione: \(TranscriptionEngine.current.rawValue) → in uso: \(TranscriptionEngine.current.resolved.rawValue)\n"
        r += "Motore Preciso scaricato: \(WhisperModel.isReady ? "sì" : "no")"
        if let p = WhisperModel.shared.downloadProgress { r += " (download \(Int(p * 100))%)" }
        if let e = WhisperModel.shared.lastError { r += " · ultimo errore: \(e)" }
        r += "\n"
        r += "AI sul dispositivo: \(SummaryService.availabilityMessage ?? "disponibile")\n"
        r += "AI avanzata (chiave API): \(ClaudeService.isConfigured ? "configurata" : "non configurata")\n"
        r += "Modello elaborazioni: \(defaults.string(forKey: ClaudeService.summaryModelKey) ?? "predefinito")\n"
        r += "Modello domande: \(defaults.string(forKey: ClaudeService.chatModelKey) ?? "predefinito")\n"
        r += "Migliora con l'AI: \(Pipeline.autoImprove ? "sì" : "no") · Sintesi automatica: \(Pipeline.autoSummary ? "sì" : "no")\n"
        r += "Separazione parlanti: \(DiarizationService.isEnabled ? "attiva" : "non attiva")\n"
        r += "Consumo del mese: \(String(format: "%.4f", UsageTracker.monthTotal)) USD in \(UsageTracker.monthRequests) richieste\n"
        let glossary = (try? context.fetchCount(FetchDescriptor<GlossaryEntry>())) ?? 0
        let voices = (try? context.fetchCount(FetchDescriptor<VoiceProfile>())) ?? 0
        let templates = (try? context.fetchCount(FetchDescriptor<CustomTemplate>())) ?? 0
        r += "Voci glossario: \(glossary) · Profili vocali: \(voices) · Modelli personalizzati: \(templates)\n\n"

        r += "== REGISTRAZIONI (ultime 25) ==\n"
        var descriptor = FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 25
        let recordings = (try? context.fetch(descriptor)) ?? []
        if recordings.isEmpty { r += "nessuna\n" }
        let running = Pipeline.shared
        for rec in recordings {
            let segments = rec.segments
            let fileExists = FileManager.default.fileExists(atPath: rec.audioURL.path)
            r += "• \(rec.id.uuidString.prefix(8)) · \(stamp.string(from: rec.createdAt)) · durata \(formatTime(rec.duration))"
            r += " · audio \(fileExists ? fileSize(rec.audioURL) : "MANCANTE") · ingresso \(rec.inputName.isEmpty ? "?" : rec.inputName)\n"
            r += "   frasi \(segments.count) · parole \(rec.transcript?.split(separator: " ").count ?? 0)"
            r += " · parlanti \(rec.diarized ? "\(rec.speakerOrder.count)" : "no") · migliorata AI \(rec.revisedByClaude ? "sì" : "no")"
            r += " · elaborazioni \(rec.summaries.count) · titolo automatico \(rec.hasDefaultTitle ? "sì" : "no")"
            r += " · in sospeso \(rec.pipelinePending ? "sì" : "no") · in corso \(running.isRunning(rec) ? "sì" : "no")\n"
            if let e = rec.transcriptionError { r += "   errore trascrizione: \(e)\n" }
            if let e = running.errors[rec.id] { r += "   ultimo errore: \(e)\n" }
        }
        r += "\n== REGISTRO ==\n"
        var log = ""
        for url in [previousURL, currentURL] {
            if let text = try? String(contentsOf: url, encoding: .utf8) { log += text }
        }
        if let maxLogBytes, log.utf8.count > maxLogBytes {
            let tail = String(decoding: Array(log.utf8.suffix(maxLogBytes)), as: UTF8.self)
            log = "[… parte più vecchia del registro omessa …]\n" + (tail.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? tail)
        }
        r += log

        let name = "diagnostica-registratore-\(Storage.newFileName(ext: "txt"))"
        let out = URL.temporaryDirectory.appending(path: name)
        do {
            try r.write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            DiagnosticLog.error(.app, "Impossibile creare il rapporto", error)
            return nil
        }
    }

    // MARK: - Utilità

    private static func machineModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private static func freeSpace() -> String {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return "?" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func fileSize(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "normale"
        case .fair: return "tiepido"
        case .serious: return "caldo"
        case .critical: return "critico"
        @unknown default: return "?"
        }
    }
}

/// Raccoglie da iOS i rapporti sui crash e sui blocchi dell'app (arrivano al lancio successivo)
/// e li aggiunge al registro.
final class CrashCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashCollector()

    func start() {
        MXMetricManager.shared.add(self)
        // Rapporti già disponibili (es. crash dell'ultima sessione).
        let pending = MXMetricManager.shared.pastDiagnosticPayloads
        if !pending.isEmpty { record(pending) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        record(payloads)
    }

    private func record(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
            let disk = payload.diskWriteExceptionDiagnostics?.count ?? 0
            guard crashes + hangs + cpu + disk > 0 else { continue }
            DiagnosticLog.error(.crash, "Rapporto iOS: crash \(crashes), blocchi \(hangs), eccessi CPU \(cpu), eccessi scrittura \(disk)")
            let json = String(decoding: payload.jsonRepresentation(), as: UTF8.self)
            DiagnosticLog.error(.crash, "Dettaglio: \(json.prefix(12_000))")
        }
    }
}
