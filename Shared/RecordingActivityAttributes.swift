import Foundation
import ActivityKit

/// Dati della Live Activity (Dynamic Island e schermata di blocco), condivisi tra app e widget.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording, paused, processing, done
        }

        var phase: Phase
        /// Riferimento per il cronometro: inizio della registrazione al netto delle pause.
        var timerStart: Date
        /// Durata ferma da mostrare quando la registrazione è in pausa.
        var pausedElapsed: Double
        /// Cosa sta succedendo, in breve ("Trascrivo…", "Pronta").
        var status: String
        /// Avanzamento della lavorazione (0…1), se noto.
        var progress: Double?
        /// Inizio e fine previsti della lavorazione: la barra e il tempo rimanente si muovono da soli
        /// nella Dynamic Island e nella schermata di blocco, anche quando iOS non mostra subito
        /// gli aggiornamenti mandati dall'app in background.
        var progressStart: Date? = nil
        var progressEnd: Date? = nil

        var progressWindow: ClosedRange<Date>? {
            guard let progressStart, let progressEnd, progressEnd > progressStart else { return nil }
            return progressStart...progressEnd
        }
    }

    /// Titolo della registrazione.
    var title: String
}

enum AppLinks {
    static let record = URL(string: "registratoreai://record")!
    static let open = URL(string: "registratoreai://open")!
}
