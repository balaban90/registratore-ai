import Foundation
import EventKit

enum RemindersFailure: LocalizedError {
    case denied
    case noList

    var errorDescription: String? {
        switch self {
        case .denied: return "Consenti l'accesso a Promemoria in Impostazioni > Registratore AI."
        case .noList: return "Nessun elenco di Promemoria disponibile. Creane uno nell'app Promemoria."
        }
    }
}

/// Le cose da fare di un'elaborazione diventano promemoria nell'app Promemoria di Apple
/// (come fanno Earnote e Plaud con le "azioni da fare").
enum RemindersService {
    /// Titoli di sezione che contengono cose da fare.
    private static let sectionWords = ["da fare", "azioni", "prossimi passi", "impegni", "promemoria",
                                       "cose da", "to do", "to-do", "action items", "next steps", "compiti"]

    /// Estrae le cose da fare dal testo (Markdown semplice) di un'elaborazione:
    /// le caselle "- [ ]" ovunque, e gli elenchi sotto un titolo come "Azioni da fare" o "Prossimi passi".
    static func tasks(in text: String) -> [String] {
        var result: [String] = []
        var inSection = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lower = line.lowercased()

            if lower.hasPrefix("- [ ]") || lower.hasPrefix("* [ ]") {
                append(String(line.dropFirst(5)), to: &result)
                continue
            }
            if lower.hasPrefix("- [x]") || lower.hasPrefix("* [x]") { continue }   // già fatte

            if let item = bulletBody(line) {
                if inSection { append(item, to: &result) }
                continue
            }
            if isHeading(line) {
                let title = lower.trimmingCharacters(in: CharacterSet(charactersIn: "#*0123456789.): "))
                inSection = sectionWords.contains { title.contains($0) }
                    && !title.contains("nessun") && !title.contains("non ")
                continue
            }
            // Testo normale: chiude la sezione solo se è un paragrafo lungo, non una riga di elenco spezzata.
            if line.count > 120 { inSection = false }
        }
        return Array(result.prefix(30))
    }

    /// Testo di una voce di elenco puntato, se la riga lo è.
    private static func bulletBody(_ line: String) -> String? {
        for prefix in ["- ", "* ", "• ", "– "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        // Elenco numerato dentro una sezione ("1. Mandare il preventivo"): solo se non sembra un titolo.
        if let dot = line.firstIndex(of: "."), !line[..<dot].isEmpty, line[..<dot].allSatisfy(\.isNumber),
           !isHeading(line) {
            return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func isHeading(_ line: String) -> Bool {
        if line.hasPrefix("#") { return true }
        if line.hasPrefix("**") && (line.hasSuffix("**") || line.hasSuffix("**:") || line.hasSuffix(":**")) { return true }
        if line.hasSuffix(":") && line.count < 70 { return true }
        // "5. Azioni da fare" scritto come elenco numerato breve senza punto finale.
        if let dot = line.firstIndex(of: "."), !line[..<dot].isEmpty, line[..<dot].allSatisfy(\.isNumber) {
            let rest = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces).lowercased()
            return rest.count < 50 && sectionWords.contains { rest.contains($0) }
        }
        return false
    }

    private static func append(_ raw: String, to list: inout [String]) {
        var text = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(".") || text.hasSuffix(";") { text.removeLast() }
        let lower = text.lowercased()
        guard text.count >= 3, !lower.hasPrefix("non specificato"), !lower.hasPrefix("nessun"),
              !list.contains(text) else { return }
        list.append(String(text.prefix(200)))
    }

    /// Aggiunge i promemoria all'elenco predefinito. Restituisce quanti ne ha aggiunti.
    @MainActor
    static func add(_ tasks: [String], from recordingTitle: String) async throws -> Int {
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw RemindersFailure.denied }
        guard let list = store.defaultCalendarForNewReminders() else { throw RemindersFailure.noList }
        var added = 0
        for task in tasks {
            let reminder = EKReminder(eventStore: store)
            reminder.title = task
            reminder.notes = "Da: \(recordingTitle)"
            reminder.calendar = list
            try store.save(reminder, commit: false)
            added += 1
        }
        try store.commit()
        DiagnosticLog.info(.ai, "Promemoria aggiunti: \(added)")
        return added
    }
}
