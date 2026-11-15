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
            container = try ModelContainer(for: Recording.self, Summary.self, CustomTemplate.self, GlossaryEntry.self, VoiceProfile.self)
        } catch {
            DiagnosticLog.error(.app, "Archivio dati non apribile", error)
            fatalError("Archivio dati non apribile: \(error)")
        }
        DiagnosticUploader.shared.container = container
        CrashCollector.shared.start()
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
                Task { await UpdateChecker.shared.check() }
            case .background:
                DiagnosticLog.info(.app, "App in background")
                DiagnosticUploader.shared.sendIfNeeded(reason: "app in background")
            default: break
            }
        }
    }
}
