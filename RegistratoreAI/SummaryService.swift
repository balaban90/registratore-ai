import Foundation
import FoundationModels

enum SummaryFailure: LocalizedError {
    case unavailable(String)
    case tooLong
    case blocked
    case busy

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .tooLong: return "Testo troppo lungo per l'AI sul dispositivo. Usa l'AI avanzata."
        case .blocked: return "L'AI sul dispositivo non può elaborare questo contenuto. Usa l'AI avanzata."
        case .busy: return "L'AI sul dispositivo è occupata. Riprova tra poco."
        }
    }
}

/// Riassunti con il modello Apple sul dispositivo (gratuito, offline).
/// Il modello legge circa 4.096 token alla volta: le trascrizioni lunghe
/// vengono divise in parti, riassunte una per una e poi ricomposte.
/// Se una parte risulta comunque troppo lunga, viene divisa ancora (mai un errore per la lunghezza).
enum SummaryService {
    /// ~6.000 caratteri di italiano ≈ 1.800–2.000 token: lascia spazio a istruzioni e risposta.
    static let chunkChars = 6_000
    /// Sotto questa misura una parte non si divide più.
    static let minChunkChars = 600

    /// Chi risponde: il modello Apple, oppure un sostituto nei test.
    typealias Asker = (_ instructions: String, _ prompt: String) async throws -> String

    static var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "Questo iPhone non supporta Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Attiva Apple Intelligence in Impostazioni di iOS."
            case .modelNotReady:
                return "Modello Apple Intelligence in download. Riprova tra qualche minuto."
            @unknown default:
                return "Apple Intelligence non è disponibile al momento."
            }
        }
    }

    static func summarize(transcript: String, template: SummaryTemplate, userContext: String = "",
                          progress: @escaping @MainActor (String) -> Void) async throws -> String {
        if let message = availabilityMessage { throw SummaryFailure.unavailable(message) }
        return try await summarize(transcript: transcript, template: template, chunkChars: chunkChars,
                                   userContext: userContext,
                                   using: { try await ask(instructions: $0, prompt: $1) }, progress: progress)
    }

    static func summarize(transcript: String, template: SummaryTemplate, chunkChars: Int, userContext: String = "",
                          using ask: Asker, progress: @escaping @MainActor (String) -> Void) async throws -> String {
        var material = transcript
        var isNotes = false
        var size = chunkChars

        var instructions = """
        Sei un assistente che riassume registrazioni. \(template.instructions)

        \(SummaryTemplate.commonRules)
        """
        if !userContext.isEmpty {
            // Il modello sul dispositivo legge poco: il contesto si accorcia.
            instructions += "\n\n" + SummaryTemplate.contextRule + "\n" + String(userContext.prefix(800))
        }
        for _ in 0..<6 {
            // Riduce il testo finché non entra in una sola richiesta.
            var round = 0
            while material.count > size && round < 5 {
                round += 1
                let chunks = split(material, maxChars: size)
                var notes: [String] = []
                for (i, chunk) in chunks.enumerated() {
                    await progress("Leggo la parte \(i + 1) di \(chunks.count)…")
                    notes.append(try await extractNotes(from: chunk, part: i + 1, of: chunks.count, using: ask))
                }
                let joined = notes.joined(separator: "\n\n")
                if joined.count < material.count {
                    material = joined
                    isNotes = true
                } else {
                    // Gli appunti non accorciano il testo: si riprova con parti più piccole, mai all'infinito.
                    if size <= minChunkChars { throw SummaryFailure.tooLong }
                    size = max(minChunkChars, size / 2)
                }
            }

            await progress("Scrivo l'elaborazione…")
            let intro = isNotes
                ? "Ecco gli appunti estratti, in ordine, da una registrazione lunga:"
                : "Ecco la trascrizione della registrazione:"
            do {
                return try await ask(instructions, "\(intro)\n\n\(material)")
            } catch SummaryFailure.tooLong where material.count > minChunkChars {
                // Il testo finale non entra: si riduce ancora con parti più piccole.
                size = max(minChunkChars, min(size, material.count) / 2)
            }
        }
        throw SummaryFailure.tooLong
    }

    /// Titolo breve (3-7 parole) per riconoscere la registrazione nell'elenco. Gratis, sul dispositivo.
    static func title(for text: String) async throws -> String {
        if let message = availabilityMessage { throw SummaryFailure.unavailable(message) }
        let instructions = "Scrivi solo un titolo in italiano di 3-7 parole che dica di cosa parla il testo. Niente virgolette, niente punto finale."
        let raw = try await ask(instructions: instructions, prompt: String(text.prefix(3_000)))
        let firstLine = raw.components(separatedBy: "\n").first ?? raw
        return String(firstLine.trimmingCharacters(in: CharacterSet(charactersIn: " \"«»*#.")).prefix(80))
    }

    /// Alcuni titoli alternativi (3-7 parole) da proporre quando si rinomina. Gratis, sul dispositivo.
    static func titleSuggestions(for text: String) async throws -> [String] {
        if let message = availabilityMessage { throw SummaryFailure.unavailable(message) }
        let raw = try await ask(instructions: TitleSuggestions.instructions, prompt: String(text.prefix(3_000)))
        return TitleSuggestions.parse(raw)
    }

    private static func extractNotes(from chunk: String, part: Int, of total: Int, using ask: Asker) async throws -> String {
        let instructions = """
        Estrai da una parte di trascrizione gli appunti essenziali, in italiano, come elenco puntato.
        Conserva: temi, concetti, posizioni di chi parla, decisioni, numeri, date, nomi, impegni.
        Non aggiungere nulla che non sia nel testo. Massimo 15 punti.
        """
        do {
            return try await ask(instructions, "Parte \(part) di \(total):\n\n\(chunk)")
        } catch SummaryFailure.tooLong where chunk.count > minChunkChars {
            // Parte troppo lunga per il modello: la si divide in due e si riprova.
            let halves = split(chunk, maxChars: chunk.count / 2 + 1)
            var notes: [String] = []
            for half in halves {
                notes.append(try await extractNotes(from: half, part: part, of: total, using: ask))
            }
            return notes.joined(separator: "\n")
        }
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
            case .rateLimited:
                throw SummaryFailure.busy
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
