import Foundation
import FoundationModels

enum SummaryFailure: LocalizedError {
    case unavailable(String)
    case tooLong
    case blocked

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .tooLong: return "Il testo è troppo lungo per il modello sul dispositivo. Usa \"Invia a Claude\"."
        case .blocked: return "Il modello Apple si è rifiutato di elaborare questo contenuto. Usa \"Invia a Claude\"."
        }
    }
}

/// Riassunti con il modello Apple sul dispositivo (gratuito, offline).
/// Il modello legge circa 4.096 token alla volta: le trascrizioni lunghe
/// vengono divise in parti, riassunte una per una e poi ricomposte.
enum SummaryService {
    /// ~4.500 caratteri di italiano ≈ 1.300–1.500 token: lascia spazio a istruzioni e risposta.
    static let chunkChars = 4_500

    static var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "Questo iPhone non supporta Apple Intelligence. Usa \"Invia a Claude\"."
            case .appleIntelligenceNotEnabled:
                return "Attiva Apple Intelligence in Impostazioni > Apple Intelligence e Siri."
            case .modelNotReady:
                return "Il modello Apple si sta ancora scaricando. Riprova tra qualche minuto."
            @unknown default:
                return "Il modello Apple non è disponibile al momento."
            }
        }
    }

    static func summarize(transcript: String, template: SummaryTemplate, progress: @escaping @MainActor (String) -> Void) async throws -> String {
        if let message = availabilityMessage { throw SummaryFailure.unavailable(message) }

        var material = transcript
        var isNotes = false
        var round = 0

        // Riduce il testo finché non entra in una sola richiesta.
        while material.count > chunkChars && round < 4 {
            round += 1
            let chunks = split(material, maxChars: chunkChars)
            var notes: [String] = []
            for (i, chunk) in chunks.enumerated() {
                await progress("Leggo la parte \(i + 1) di \(chunks.count)…")
                notes.append(try await extractNotes(from: chunk, part: i + 1, of: chunks.count))
            }
            material = notes.joined(separator: "\n\n")
            isNotes = true
        }

        await progress("Scrivo il riassunto…")
        let instructions = """
        Sei un assistente che riassume registrazioni. \(template.instructions)

        \(SummaryTemplate.commonRules)
        """
        let intro = isNotes
            ? "Ecco gli appunti estratti, in ordine, da una registrazione lunga:"
            : "Ecco la trascrizione della registrazione:"
        return try await ask(instructions: instructions, prompt: "\(intro)\n\n\(material)")
    }

    private static func extractNotes(from chunk: String, part: Int, of total: Int) async throws -> String {
        let instructions = """
        Estrai da una parte di trascrizione gli appunti essenziali, in italiano, come elenco puntato.
        Conserva: temi, concetti, posizioni di chi parla, decisioni, numeri, date, nomi, impegni.
        Non aggiungere nulla che non sia nel testo. Massimo 15 punti.
        """
        return try await ask(instructions: instructions, prompt: "Parte \(part) di \(total):\n\n\(chunk)")
    }

    private static func ask(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                throw SummaryFailure.tooLong
            case .guardrailViolation:
                throw SummaryFailure.blocked
            default:
                throw error
            }
        }
    }

    /// Divide per righe, poi per frasi se una riga è troppo lunga.
    static func split(_ text: String, maxChars: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { chunks.append(t) }
            current = ""
        }
        for line in text.components(separatedBy: "\n") {
            var pieces = [line]
            if line.count > maxChars {
                pieces = line.components(separatedBy: ". ").map { $0 + "." }
            }
            for piece in pieces {
                if current.count + piece.count + 1 > maxChars { flush() }
                if piece.count > maxChars {
                    // Caso limite: taglio netto.
                    var rest = Substring(piece)
                    while !rest.isEmpty {
                        let head = rest.prefix(maxChars)
                        chunks.append(String(head))
                        rest = rest.dropFirst(head.count)
                    }
                } else {
                    current += (current.isEmpty ? "" : "\n") + piece
                }
            }
        }
        flush()
        return chunks
    }
}
