import SwiftUI
import SwiftData

@main
struct RegistratoreAIApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        DiagnosticLog.info(.app, "Avvio app v\(version) (\(build)) · iOS \(UIDevice.current.systemVersion)")
        CrashCollector.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Theme.accent)
        }
        .modelContainer(for: [Recording.self, Summary.self, CustomTemplate.self, GlossaryEntry.self, VoiceProfile.self])
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: DiagnosticLog.info(.app, "App in primo piano")
            case .background: DiagnosticLog.info(.app, "App in background")
            default: break
            }
        }
    }
}
