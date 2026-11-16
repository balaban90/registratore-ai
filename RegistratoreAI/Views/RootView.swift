import SwiftUI
import SwiftData

enum RootTab: Hashable {
    case record
    case recordings
}

/// Struttura dell'app: due schede, "Registra" (apertura) e "Registrazioni" (elenco).
struct RootView: View {
    @Environment(\.modelContext) private var context
    // Nelle prove automatiche dell'interfaccia si parte dall'elenco, dove ci sono i dati di prova.
    @State private var tab: RootTab = TestSupport.isUITest ? .recordings : .record
    @State private var autoStartRecording = false

    var body: some View {
        TabView(selection: $tab) {
            Tab("Registra", systemImage: "mic.fill", value: RootTab.record) {
                RecordView(autoStart: $autoStartRecording) {
                    tab = .recordings
                }
            }
            Tab("Registrazioni", systemImage: "list.bullet", value: RootTab.recordings) {
                ContentView()
            }
        }
        .tint(Theme.accent)
        .onOpenURL { url in
            // Widget "Registra" e pulsante del Centro di Controllo.
            guard url.host == "record" else { return }
            tab = .record
            autoStartRecording = true
        }
        .task {
            Pipeline.shared.resumePending(in: context)
            WhisperModel.shared.downloadIfAppropriate()
            await UpdateChecker.shared.check()
        }
    }
}
