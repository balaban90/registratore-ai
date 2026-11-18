import Foundation
import BackgroundTasks
import UIKit

/// Permette alla lavorazione di continuare a schermo bloccato o con l'app chiusa.
///
/// Usa i "lavori continuati" di iOS 26: iOS mostra l'avanzamento nel sistema e lascia
/// lavorare l'app in background. Se non è disponibile (o iOS lo rifiuta), si ottengono
/// comunque i pochi secondi extra concessi a ogni app; alla riapertura la lavorazione riprende.
@MainActor
final class BackgroundWork {
    static let shared = BackgroundWork()

    private var active = 0
    private var task: BGContinuedProcessingTask?
    private var shortTask: UIBackgroundTaskIdentifier = .invalid
    private var title = "Registratore AI"
    private var subtitle = ""
    private var fraction = 0.0
    /// Avanzamento mostrato a iOS (0…1000): sale piano anche durante i passaggi lunghi,
    /// perché iOS può fermare un lavoro che per molto tempo non segnala progressi.
    private var shown: Int64 = 0
    private var heartbeat: Timer?
    private var lastBeat = Date.now
    private var observer: NSObjectProtocol?

    private init() {
        // Il battito si ferma quando iOS sospende l'app: al rientro, un buco lungo
        // significa che la lavorazione è rimasta ferma. Lo annota nel registro.
        observer = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BackgroundWork.shared.checkSuspension() }
        }
    }

    func begin(title: String) {
        active += 1
        guard active == 1 else { return }
        self.title = title
        subtitle = "Avvio…"
        fraction = 0
        shown = 0
        startHeartbeat()
        KeepAlive.shared.start()

        shortTask = UIApplication.shared.beginBackgroundTask(withName: "lavorazione") { [weak self] in
            MainActor.assumeIsolated { self?.endShortTask() }
        }

        guard let prefix = Self.identifierPrefix() else { return }
        let identifier = prefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] bgTask in
            MainActor.assumeIsolated {
                guard let self, let continued = bgTask as? BGContinuedProcessingTask, self.active > 0 else {
                    bgTask.setTaskCompleted(success: true)
                    return
                }
                self.attach(continued)
            }
        }
        guard registered else {
            DiagnosticLog.warning(.pipeline, "Lavoro in background non registrato da iOS · prefisso \(prefix)")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            DiagnosticLog.warning(.pipeline, "iOS ha rifiutato il lavoro in background: \(DiagnosticLog.describe(error))")
        }
    }

    /// Prefisso dei lavori in background, preso dall'elenco permesso in Info.plist
    /// (es. "it.registratoreai.app.processing."). Chi installa l'app con Sideloadly può
    /// cambiarne l'identificativo: costruirlo dall'identificativo attuale non combacerebbe più.
    static func identifierPrefix(permitted: [String]? = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
                                 bundle: String? = Bundle.main.bundleIdentifier) -> String? {
        if let wildcard = permitted?.first(where: { $0.hasSuffix(".processing.*") }) {
            return String(wildcard.dropLast())
        }
        return bundle.map { "\($0).processing." }
    }

    func update(_ text: String, fraction: Double) {
        subtitle = text
        self.fraction = max(self.fraction, min(fraction, 1))
        shown = max(shown, Int64(self.fraction * 1000))
        guard let task else { return }
        task.updateTitle(title, subtitle: text)
        task.progress.completedUnitCount = shown
    }

    func end(success: Bool) {
        active = max(0, active - 1)
        guard active == 0 else { return }
        if let task {
            task.progress.completedUnitCount = 1000
            task.setTaskCompleted(success: success)
        }
        task = nil
        stopHeartbeat()
        KeepAlive.shared.stop()
        endShortTask()
    }

    private func attach(_ continued: BGContinuedProcessingTask) {
        task = continued
        DiagnosticLog.info(.pipeline, "Lavoro in background concesso da iOS")
        continued.progress.totalUnitCount = 1000
        continued.progress.completedUnitCount = shown
        continued.updateTitle(title, subtitle: subtitle)
        continued.expirationHandler = { [weak self] in
            // iOS ha chiesto di fermarsi: la lavorazione riprenderà alla riapertura dell'app.
            DiagnosticLog.warning(.pipeline, "iOS ha interrotto il lavoro in background")
            Task { @MainActor in
                self?.task?.setTaskCompleted(success: false)
                self?.task = nil
            }
        }
    }

    // MARK: - Battito

    private func startHeartbeat() {
        heartbeat?.invalidate()
        lastBeat = .now
        heartbeat = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { BackgroundWork.shared.beat() }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }

    /// Controlla che l'app non sia stata sospesa. La barra di iOS mostra solo l'avanzamento vero
    /// (calcolato dalla lavorazione ogni secondo), senza avanzamenti finti.
    private func beat() {
        lastBeat = .now
        guard active > 0 else { return }
        shown = max(shown, Int64(fraction * 1000))
        task?.progress.completedUnitCount = shown
    }

    private func checkSuspension() {
        guard active > 0, heartbeat != nil else { return }
        let gap = Int(Date.now.timeIntervalSince(lastBeat))
        lastBeat = .now
        guard gap > 30 else { return }
        DiagnosticLog.warning(.pipeline, "Lavorazione rimasta ferma \(gap) s mentre l'app era in background (\(subtitle)) · sessione audio \(KeepAlive.shared.isPlaying ? "attiva" : "non attiva")")
        DiagnosticUploader.markPending()
        DiagnosticUploader.shared.sendIfNeeded(reason: "lavorazione ferma in background")
    }

    private func endShortTask() {
        guard shortTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(shortTask)
        shortTask = .invalid
    }
}
