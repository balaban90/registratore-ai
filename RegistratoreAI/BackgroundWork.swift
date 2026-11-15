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

    func begin(title: String) {
        active += 1
        guard active == 1 else { return }
        self.title = title
        subtitle = "Avvio…"
        fraction = 0

        shortTask = UIApplication.shared.beginBackgroundTask(withName: "lavorazione") { [weak self] in
            MainActor.assumeIsolated { self?.endShortTask() }
        }

        guard let bundle = Bundle.main.bundleIdentifier else { return }
        let identifier = "\(bundle).processing.\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] bgTask in
            MainActor.assumeIsolated {
                guard let self, let continued = bgTask as? BGContinuedProcessingTask, self.active > 0 else {
                    bgTask.setTaskCompleted(success: true)
                    return
                }
                self.attach(continued)
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    func update(_ text: String, fraction: Double) {
        subtitle = text
        self.fraction = max(self.fraction, min(fraction, 1))
        guard let task else { return }
        task.updateTitle(title, subtitle: text)
        task.progress.completedUnitCount = Int64(self.fraction * 100)
    }

    func end(success: Bool) {
        active = max(0, active - 1)
        guard active == 0 else { return }
        if let task {
            task.progress.completedUnitCount = 100
            task.setTaskCompleted(success: success)
        }
        task = nil
        endShortTask()
    }

    private func attach(_ continued: BGContinuedProcessingTask) {
        task = continued
        continued.progress.totalUnitCount = 100
        continued.progress.completedUnitCount = Int64(fraction * 100)
        continued.updateTitle(title, subtitle: subtitle)
        continued.expirationHandler = { [weak self] in
            // iOS ha chiesto di fermarsi: la lavorazione riprenderà alla riapertura dell'app.
            Task { @MainActor in
                self?.task?.setTaskCompleted(success: false)
                self?.task = nil
            }
        }
    }

    private func endShortTask() {
        guard shortTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(shortTask)
        shortTask = .invalid
    }
}
