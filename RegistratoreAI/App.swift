import SwiftUI
import SwiftData

@main
struct RegistratoreAIApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer

    init() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        DiagnosticLog.info(.app, "Avvio app v\(version) (\(build)) · iOS \(UIDevice.current.systemVersion)")
        // Stessa posizione dei dati di prima (configurazione predefinita).
        do {
            if TestSupport.isTesting {
                // Test automatici: archivio in memoria, mai i dati veri.
                let config = ModelConfiguration(isStoredInMemoryOnly: true)
                container = try ModelContainer(for: Recording.self, Summary.self, CustomTemplate.self, GlossaryEntry.self, VoiceProfile.self,
                                               configurations: config)
            } else {
                container = try ModelContainer(for: Recording.self, Summary.self, CustomTemplate.self, GlossaryEntry.self, VoiceProfile.self)
            }
        } catch {
            DiagnosticLog.error(.app, "Archivio dati non apribile", error)
            fatalError("Archivio dati non apribile: \(error)")
        }
        DiagnosticUploader.shared.container = container
        CrashCollector.shared.start()
        if TestSupport.isUITest {
            UserDefaults.standard.removeObject(forKey: SettingsView.developerModeKey)
            TestSupport.seed(into: container.mainContext)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Theme.accent)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                DiagnosticLog.info(.app, "App in primo piano")
                DiagnosticUploader.shared.sendIfNeeded(reason: "riapertura app")
                // Riprende da sola ciò che si era fermato (rete assente, AI sul dispositivo limitata in background…).
                Pipeline.shared.resumePending(in: container.mainContext)
                Task { await UpdateChecker.shared.check() }
            case .background:
                DiagnosticLog.info(.app, "App in background")
                // Se si stava ascoltando una registrazione, la sessione audio torna "mescolabile"
                // così la lavorazione continua anche mentre si usa un'altra app audio.
                KeepAlive.shared.reassert()
                DiagnosticUploader.shared.sendIfNeeded(reason: "app in background")
            default: break
            }
        }
    }
}
