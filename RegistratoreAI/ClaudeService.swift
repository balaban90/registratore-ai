import Foundation

enum ClaudeModel: String, CaseIterable, Identifiable {
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    case opus = "claude-opus-5-5"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sonnet: return "Sonnet – equilibrato"
        case .haiku: return "Haiku – il più economico"
        case .opus: return "Opus – il più accurato (costa di più)"
        }
    }

    /// Prezzi in dollari per milione di token (listino Anthropic, novembre 2026).
    var inputPrice: Double {
        switch self { case .sonnet: return 2; case .haiku: return 0.10; case .opus: return 4 }
    }
    var outputPrice: Double {
        switch self { case .sonnet: return 10; case .haiku: return 0.50; case .opus: return 20 }
    }
    /// Lettura dalla cache rispetto al prezzo di input.
    var cacheReadMultiplier: Double {
        switch self { case .haiku: return 0.10; case .sonnet, .opus: return 0.05 }
    }
    static let cacheWriteMultiplier = 1.25
}

struct ClaudeMessage: Codable, Identifiable, Hashable {
    var id = UUID()
    let role: String   // "user" o "assistant"
    let content: String

    enum CodingKeys: String, CodingKey { case role, content }
}

struct ClaudeUsage: Decodable {
    var input_tokens: Int = 0
    var output_tokens: Int = 0
    var cache_creation_input_tokens: Int? = 0
    var cache_read_input_tokens: Int? = 0

    func cost(for model: ClaudeModel) -> Double {
        let m = 1_000_000.0
        let input = Double(input_tokens) * model.inputPrice / m
        let write = Double(cache_creation_input_tokens ?? 0) * model.inputPrice * ClaudeModel.cacheWriteMultiplier / m
        let read = Double(cache_read_input_tokens ?? 0) * model.inputPrice * model.cacheReadMultiplier / m
        let output = Double(output_tokens) * model.outputPrice / m
        return input + write + read + output
    }
}

struct ClaudeReply {
    let text: String
    let costUSD: Double
    /// true se Claude si è fermato per il limite di lunghezza.
    let truncated: Bool
}

enum ClaudeFailure: LocalizedError {
    case missingKey
    case http(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Inserisci la chiave API di Claude in Impostazioni."
        case .http(let code, let message):
            let lower = message.lowercased()
            if lower.contains("credit") || lower.contains("balance") {
                return "Credito API esaurito. Ricarica su platform.claude.com (Billing)."
            }
            switch code {
            case 401: return "Chiave API non valida. Controllala in Impostazioni."
            case 429: return "Troppe richieste ravvicinate. Riprova tra poco."
            case 529, 503: return "Claude è sovraccarico in questo momento. Riprova tra poco."
            default: return "Errore di Claude (\(code)): \(message)"
            }
        case .emptyResponse:
            return "Claude non ha restituito testo."
        }
    }
}

/// Tiene il conto della spesa stimata del mese (solo su questo iPhone).
enum UsageTracker {
    private static var monthKey: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return "claudeSpend-\(f.string(from: .now))"
    }

    static func add(_ usd: Double) {
        let d = UserDefaults.standard
        d.set(d.double(forKey: monthKey) + usd, forKey: monthKey)
        d.set(d.integer(forKey: monthKey + "-n") + 1, forKey: monthKey + "-n")
    }

    static var monthTotal: Double { UserDefaults.standard.double(forKey: monthKey) }
    static var monthRequests: Int { UserDefaults.standard.integer(forKey: monthKey + "-n") }
}

func formatUSD(_ value: Double) -> String {
    if value < 0.01 { return "< 0,01 $" }
    return value.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "it_IT"))) + " $"
}

/// Chiamate dirette alla Claude API. Esce solo testo, mai l'audio.
///
/// Per risparmiare: la trascrizione sta in un blocco di sistema identico per
/// riassunti e domande, marcato per la cache. Le richieste successive sulla
/// stessa registrazione (entro 5 minuti) la rileggono dalla cache a una
/// frazione del prezzo.
enum ClaudeService {
    static let keychainKey = "anthropic_api_key"
    static let summaryModelKey = "claudeModel"          // stesso nome della v0.2
    static let chatModelKey = "claudeChatModel"
    static let maxChatMessages = 6
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static var apiKey: String? {
        guard let k = Keychain.get(keychainKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return nil }
        return k
    }

    static var isConfigured: Bool { apiKey != nil }

    static var summaryModel: ClaudeModel {
        ClaudeModel(rawValue: UserDefaults.standard.string(forKey: summaryModelKey) ?? "") ?? .sonnet
    }

    static var chatModel: ClaudeModel {
        ClaudeModel(rawValue: UserDefaults.standard.string(forKey: chatModelKey) ?? "") ?? .haiku
    }

    // MARK: - Richiesta

    private struct CacheControl: Encodable { let type = "ephemeral" }

    private struct SystemBlock: Encodable {
        let type = "text"
        let text: String
        let cache_control: CacheControl?
    }

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let system: [SystemBlock]
        let messages: [ClaudeMessage]
    }

    private struct ResponseBody: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let usage: ClaudeUsage?
        let stop_reason: String?
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    /// `cachedContext` va in cache; `instructions` (facoltativo) viene dopo, fuori dalla cache.
    static func send(cachedContext: String, instructions: String? = nil, messages: [ClaudeMessage],
                     maxTokens: Int, model: ClaudeModel, key: String? = nil) async throws -> ClaudeReply {
        guard let apiKey = key ?? apiKey else { throw ClaudeFailure.missingKey }

        var system = [SystemBlock(text: cachedContext, cache_control: CacheControl())]
        if let instructions, !instructions.isEmpty {
            system.append(SystemBlock(text: instructions, cache_control: nil))
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(model: model.rawValue, max_tokens: maxTokens, system: system, messages: messages)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8) ?? ""
            throw ClaudeFailure.http(status, message)
        }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
        guard !text.isEmpty else { throw ClaudeFailure.emptyResponse }
        let cost = decoded.usage?.cost(for: model) ?? 0
        UsageTracker.add(cost)
        return ClaudeReply(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                           costUSD: cost,
                           truncated: decoded.stop_reason == "max_tokens")
    }

    // MARK: - Contesto condiviso (identico per riassunti e domande → cache)

    static func context(title: String, transcript: String) -> String {
        """
        Sei l'assistente di un funzionario sindacale della sanità. Scrivi sempre in italiano, in modo chiaro e sintetico.
        Lavori sulla trascrizione automatica qui sotto: può contenere errori di riconoscimento, correggi solo quelli evidenti.
        Usa solo informazioni presenti nella trascrizione; se qualcosa manca, dillo invece di inventare.
        Gli orari tra parentesi quadre indicano il punto della registrazione.

        REGISTRAZIONE: "\(title)"

        TRASCRIZIONE:
        \(transcript)
        """
    }

    static func summarize(title: String, transcript: String, template: SummaryTemplate) async throws -> ClaudeReply {
        let request = """
        Prepara un riassunto della registrazione seguendo queste istruzioni.

        \(template.instructions)

        \(SummaryTemplate.commonRules)
        Non citare gli orari nel riassunto, salvo che servano.
        """
        let reply = try await send(
            cachedContext: context(title: title, transcript: transcript),
            messages: [ClaudeMessage(role: "user", content: request)],
            maxTokens: 4_000,
            model: summaryModel
        )
        return withTruncationNotice(reply)
    }

    static func ask(title: String, transcript: String, notes: String, history: [ClaudeMessage]) async throws -> ClaudeReply {
        var trimmed = Array(history.suffix(maxChatMessages))
        while let first = trimmed.first, first.role != "user" { trimmed.removeFirst() }
        var instructions = "Rispondi in modo conciso alle domande sulla registrazione. Quando citi un passaggio indica l'orario, ad esempio [12:30]."
        if !notes.isEmpty { instructions += "\n\nNote dell'utente sulla registrazione:\n\(notes)" }
        let reply = try await send(
            cachedContext: context(title: title, transcript: transcript),
            instructions: instructions,
            messages: trimmed,
            maxTokens: 3_000,
            model: chatModel
        )
        return withTruncationNotice(reply)
    }

    private static func withTruncationNotice(_ reply: ClaudeReply) -> ClaudeReply {
        guard reply.truncated else { return reply }
        return ClaudeReply(text: reply.text + "\n\n[⚠︎ Risposta interrotta perché troppo lunga: chiedi a Claude di continuare.]",
                           costUSD: reply.costUSD, truncated: true)
    }

    // MARK: - Revisione della trascrizione

    /// Corregge solo gli errori evidenti di riconoscimento, riga per riga.
    /// Usa sempre Haiku (economico). Le righe che Claude non restituisce, o che
    /// cambia troppo, restano come nell'originale.
    static func revise(segments: [TranscriptSegment], title: String, notes: String, glossaryTerms: String,
                       progress: @escaping @MainActor (String) -> Void) async throws -> (segments: [TranscriptSegment], cost: Double) {
        var instructions = """
        Sei un correttore di trascrizioni automatiche in italiano, di riunioni sindacali nella sanità.
        Ricevi righe nel formato numero|testo. Correggi SOLO errori evidenti di riconoscimento vocale:
        parole storpiate, sigle, nomi propri, numeri, punteggiatura e maiuscole.
        NON riformulare, NON riassumere, NON togliere né aggiungere frasi, NON cambiare il senso.
        Se non sei sicuro di una correzione, lascia il testo com'è.
        Restituisci TUTTE le righe ricevute, nello stesso formato numero|testo, una per riga,
        nello stesso ordine, senza nessun altro testo prima o dopo.

        Registrazione: "\(title)"
        """
        if !glossaryTerms.isEmpty {
            instructions += "\nTermini e nomi che compaiono spesso (scritti correttamente): \(glossaryTerms)"
        }
        if !notes.isEmpty {
            instructions += "\nNote dell'utente: \(notes)"
        }

        // Blocchi da circa 8.000 caratteri.
        var chunks: [[Int]] = []
        var current: [Int] = []
        var size = 0
        for (i, seg) in segments.enumerated() {
            if size + seg.text.count > 8_000, !current.isEmpty {
                chunks.append(current); current = []; size = 0
            }
            current.append(i); size += seg.text.count + 6
        }
        if !current.isEmpty { chunks.append(current) }

        var result = segments
        var totalCost = 0.0
        for (n, chunk) in chunks.enumerated() {
            await progress("Claude rivede la parte \(n + 1) di \(chunks.count)…")
            let body = chunk.map { "\($0)|\(segments[$0].text)" }.joined(separator: "\n")
            let reply = try await send(cachedContext: instructions,
                                       messages: [ClaudeMessage(role: "user", content: body)],
                                       maxTokens: 8_000, model: .haiku)
            totalCost += reply.costUSD
            for line in reply.text.components(separatedBy: "\n") {
                guard let bar = line.firstIndex(of: "|"),
                      let index = Int(line[..<bar].trimmingCharacters(in: .whitespaces)),
                      chunk.contains(index) else { continue }
                let corrected = String(line[line.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
                let original = segments[index].text
                // Protezione: scarta correzioni che accorciano o allungano troppo la frase.
                let ratio = Double(corrected.count) / Double(max(original.count, 1))
                if !corrected.isEmpty && ratio > 0.6 && ratio < 1.6 {
                    result[index].text = corrected
                }
            }
        }
        return (result, totalCost)
    }

    /// Verifica rapida della chiave con una richiesta minima.
    static func test(key: String) async throws {
        _ = try await send(cachedContext: "Rispondi solo: OK", messages: [ClaudeMessage(role: "user", content: "Test")],
                           maxTokens: 5, model: .haiku, key: key)
    }
}
