import AppIntents
import Foundation

/// Azione "Nuova registrazione": apre l'app e avvia subito la registrazione.
/// Usata dal pulsante del Centro di Controllo.
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Nuova registrazione"
    static var description = IntentDescription("Apre Registratore AI e avvia una registrazione.")

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(AppLinks.record))
    }
}
