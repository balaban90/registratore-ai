import Foundation

enum ClaudeModel: String, CaseIterable, Identifiable {
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    case opus = "claude-opus-5-5"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sonnet: return "Bilanciato"
        case .haiku: return "Economico"
        case .opus: return "Avanzato"
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
            return "Inserisci la chiave API in Impostazioni > AI avanzata."
        case .http(let code, let message):
            let lower = message.lowercased()
            if lower.contains("credit") || lower.contains("balance") {
                return "Credito API esaurito. Ricarica il credito dal sito del servizio (Billing)."
            }
            switch code {
            case 401: return "Chiave API non valida. Controllala in Impostazioni."
            case 429: return "Troppe richieste ravvicinate. Riprova tra poco."
            case 529, 503: return "Il servizio AI è sovraccarico in questo momento. Riprova tra poco."
            default: return "Errore del servizio AI (\(code)): \(message)"
            }
        case .emptyResponse:
            return "L'AI non ha restituito testo."
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

    static let maxAttempts = 3

    /// Attesa prima del nuovo tentativo: 2 s, poi 6 s.
    static func retryDelay(_ attempt: Int) -> Int { attempt <= 1 ? 2 : 6 }

    /// Problemi di rete passeggeri, per cui ha senso riprovare.
    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Risposte del server temporanee: troppe richieste, sovraccarico, errori interni.
    static func isTransient(status: Int) -> Bool {
        [408, 429, 500, 502, 503, 504, 529].contains(status)
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

        let started = Date.now
        let sentBytes = request.httpBody?.count ?? 0
        var attempt = 0
        var data = Data()
        requestLoop: while true {
            attempt += 1
            let attemptStarted = Date.now
            do {
                let (body, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) {
                    data = body
                    break requestLoop
                }
                let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error.message
                    ?? String(data: body, encoding: .utf8) ?? ""
                if isTransient(status: status) && attempt < maxAttempts {
                    // Server occupato o sovraccarico: si riprova poco dopo.
                    DiagnosticLog.warning(.ai, "Richiesta \(model.rawValue): HTTP \(status), tentativo \(attempt) di \(maxAttempts): riprovo")
                    try await Task.sleep(for: .seconds(retryDelay(attempt)))
                    continue requestLoop
                }
                DiagnosticLog.error(.ai, "Richiesta \(model.rawValue) rifiutata: HTTP \(status) — \(message.prefix(400))")
                throw ClaudeFailure.http(status, message)
            } catch let error as URLError where isTransient(error) && attempt < maxAttempts {
                // Connessione caduta o rimasta appesa (rete instabile, cambio Wi-Fi/cellulare): si riprova.
                DiagnosticLog.warning(.ai, "Richiesta \(model.rawValue) senza risposta dopo \(Int(Date.now.timeIntervalSince(attemptStarted))) s (\(error.code.rawValue)), tentativo \(attempt) di \(maxAttempts): riprovo")
                try await Task.sleep(for: .seconds(retryDelay(attempt)))
            } catch let error as URLError {
                DiagnosticLog.error(.ai, "Richiesta \(model.rawValue) non riuscita (rete) dopo \(attempt) tentativi in \(Int(Date.now.timeIntervalSince(started))) s, inviati \(sentBytes) byte", error)
                throw error
            }
        }
        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            DiagnosticLog.error(.ai, "Risposta \(model.rawValue) non leggibile (\(data.count) byte)", error)
            throw error
        }
        let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
        guard !text.isEmpty else {
            DiagnosticLog.error(.ai, "Risposta \(model.rawValue) vuota · stop \(decoded.stop_reason ?? "?")")
            throw ClaudeFailure.emptyResponse
        }
        let cost = decoded.usage?.cost(for: model) ?? 0
        UsageTracker.add(cost)
        DiagnosticLog.info(.ai, "Richiesta \(model.rawValue) ok in \(String(format: "%.1f", Date.now.timeIntervalSince(started))) s · inviati \(sentBytes) byte · risposta \(text.count) caratteri · costo \(String(format: "%.4f", cost)) USD · stop \(decoded.stop_reason ?? "?")")
        return ClaudeReply(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                           costUSD: cost,
                           truncated: decoded.stop_reason == "max_tokens")
    }

    // MARK: - Contesto condiviso (identico per riassunti e domande → cache)

    static func context(title: String, transcript: String) -> String {
        """
        Sei un assistente che aiuta a lavorare sulle registrazioni. Scrivi sempre in italiano, in modo chiaro e sintetico.
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
        return ClaudeReply(text: reply.text + "\n\n[⚠︎ Risposta interrotta perché troppo lunga: chiedi all'AI di continuare.]",
                           costUSD: reply.costUSD, truncated: true)
    }

    // MARK: - Revisione della trascrizione

    struct RevisionResult {
        var segments: [TranscriptSegment]
        /// Nomi o ruoli proposti dall'AI per i parlanti (id → nome), da confermare.
        var suggestions: [String: String]
        /// Titolo breve proposto dall'AI per la registrazione.
        var title: String?
        var cost: Double
    }

    private static let uncertainOpen = "⟨"
    private static let uncertainClose = "⟩"

    /// Testo della riga con le parole incerte marcate ⟨così⟩.
    private static func marked(_ segment: TranscriptSegment) -> String {
        guard let doubts = segment.uncertain, !doubts.isEmpty else { return segment.text }
        var text = segment.text
        for word in Set(doubts) {
            let pattern = "(?<![\\p{L}\\p{N}⟨])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}⟩])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: uncertainOpen + "$0" + uncertainClose)
        }
        return text
    }

    /// Un solo passaggio con il modello economico che, insieme:
    /// 1. corregge le parole sbagliate (soprattutto quelle marcate come incerte),
    /// 2. rimette punteggiatura ed elenchi,
    /// 3. controlla chi parla in base al contenuto e divide le righe in cui parlano due persone,
    /// 4. propone nomi o ruoli dei parlanti.
    /// Per risparmiare, l'AI restituisce solo le righe che cambia.
    /// Le righe cambiate troppo (più corte o più lunghe del normale) restano come nell'originale.
    static func revise(segments: [TranscriptSegment], speakers: [String], speakerNames: [String: String],
                       title: String, notes: String, glossaryTerms: String,
                       progress: @escaping @MainActor (String) -> Void) async throws -> RevisionResult {
        // Etichette brevi per l'AI: P1, P2… nell'ordine in cui intervengono.
        var labelFor: [String: String] = [:]
        var idFor: [String: String] = [:]
        for (i, id) in speakers.enumerated() {
            labelFor[id] = "P\(i + 1)"
            idFor["P\(i + 1)"] = id
        }
        let diarized = !speakers.isEmpty

        var instructions = """
        Sei un correttore di trascrizioni automatiche di registrazioni (riunioni, lezioni, colloqui, telefonate, appunti).
        Ricevi righe nel formato numero|parlante|testo. Mantieni la lingua originale.

        COSA FARE
        1. Parole sbagliate: il riconoscitore confonde spesso parole dal suono simile (es. "preposti" per "posti",
           "un'andata" per "una data", "ma i" per "mai"). Correggi le parole che nel contesto non hanno senso.
           Le parole tra ⟨ ⟩ sono quelle su cui il riconoscitore era incerto: controllale con più attenzione.
           Nel testo corretto non scrivere mai i simboli ⟨ ⟩.
        2. Punteggiatura e struttura: rimetti punti, virgole, maiuscole e i due punti. Rendi chiari gli elenchi parlati
           ("primo, …; secondo, …; terzo, …"). Correggi sigle, nomi propri e numeri.
        3. Chi parla: il separatore delle voci sbaglia soprattutto quando le persone si rispondono senza pause.
           Usa il contenuto (chi chiede, chi risponde, chi propone, chi accetta) per correggere il parlante.
           Se in una riga parlano due persone, dividila: scrivi più righe con lo STESSO numero, una per parlante, nell'ordine.
        """
        if diarized {
            instructions += "\n   Parlanti presenti: " + speakers.map { id -> String in
                let label = labelFor[id] ?? "?"
                if let name = speakerNames[id], !name.isEmpty { return "\(label) (\(name))" }
                return label
            }.joined(separator: ", ") + ". Usa queste etichette; una nuova (P\(speakers.count + 1)…) solo se compare davvero un'altra persona."
        } else {
            instructions += "\n   Le voci non sono state separate (parlante \"?\"). Se è chiaramente un dialogo, assegna tu P1, P2…; altrimenti lascia \"?\"."
        }
        instructions += """

        4. Non riformulare, non riassumere, non togliere né aggiungere frasi, non cambiare il senso. Se non sei sicuro, lascia com'è.

        FORMATO DELLA RISPOSTA
        - Restituisci SOLO le righe che modifichi (testo o parlante), nel formato numero|parlante|testo, una per riga.
          Se dividi una riga, restituisci tutte le sue parti. Le righe che non cambi non vanno ripetute.
        - In fondo, solo se dal contenuto si capisce chiaramente il nome o il ruolo di qualcuno, aggiungi una riga:
          #PARLANTI P1=nome o ruolo; P2=nome o ruolo
          (es. "Marco", "Docente", "Cliente"). Non inventare: se non è chiaro, ometti quella persona.
        - Sempre in fondo, una riga con un titolo di 3-7 parole che descriva di cosa si parla:
          #TITOLO titolo
        - Nessun altro testo prima o dopo.

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
            current.append(i); size += seg.text.count + 10
        }
        if !current.isEmpty { chunks.append(current) }

        var replacements: [Int: [TranscriptSegment]] = [:]
        var suggestions: [String: String] = [:]
        var proposedTitle: String?
        var totalCost = 0.0

        func resolve(_ label: String, fallback: String?) -> String? {
            let l = label.trimmingCharacters(in: .whitespaces).uppercased()
            if l.isEmpty || l == "?" { return fallback }
            if let id = idFor[l] { return id }
            guard l.hasPrefix("P"), let n = Int(l.dropFirst()), n > 0, n < 20 else { return fallback }
            let id = "ai-\(n)"
            idFor[l] = id
            return id
        }

        for (n, chunk) in chunks.enumerated() {
            await progress("L'AI migliora la parte \(n + 1) di \(chunks.count)…")
            let body = chunk.map { i -> String in
                let label = segments[i].speaker.flatMap { labelFor[$0] } ?? "?"
                return "\(i)|\(label)|\(marked(segments[i]))"
            }.joined(separator: "\n")
            let reply = try await send(cachedContext: instructions,
                                       messages: [ClaudeMessage(role: "user", content: body)],
                                       maxTokens: 8_000, model: .haiku)
            totalCost += reply.costUSD

            var pieces: [Int: [(label: String, text: String)]] = [:]
            for raw in reply.text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.uppercased().hasPrefix("#TITOLO") {
                    let t = line.dropFirst("#TITOLO".count)
                        .trimmingCharacters(in: CharacterSet(charactersIn: " :\"«»*"))
                    if proposedTitle == nil, !t.isEmpty { proposedTitle = String(t.prefix(80)) }
                    continue
                }
                if line.uppercased().hasPrefix("#PARLANTI") {
                    let list = line.dropFirst("#PARLANTI".count)
                    for pair in list.split(separator: ";") {
                        let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                        guard parts.count == 2, !parts[1].isEmpty, parts[1] != "?",
                              let id = resolve(parts[0], fallback: nil), suggestions[id] == nil else { continue }
                        suggestions[id] = String(parts[1].prefix(40))
                    }
                    continue
                }
                let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 3,
                      let index = Int(fields[0].trimmingCharacters(in: .whitespaces)),
                      chunk.contains(index) else { continue }
                let text = fields[2]
                    .replacingOccurrences(of: uncertainOpen, with: "")
                    .replacingOccurrences(of: uncertainClose, with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                pieces[index, default: []].append((fields[1], text))
            }

            for (index, parts) in pieces {
                let original = segments[index]
                let total = parts.reduce(0) { $0 + $1.text.count }
                // Protezione: scarta correzioni che accorciano o allungano troppo.
                let ratio = Double(total) / Double(max(original.text.count, 1))
                guard ratio > 0.6 && ratio < 1.6 else { continue }

                if parts.count == 1 {
                    var s = original
                    let part = parts[0]
                    if part.text != original.text { s.text = part.text; s.words = nil }
                    s.speaker = resolve(part.label, fallback: original.speaker)
                    s.uncertain = original.uncertain?.filter { part.text.contains($0) }
                    if s.uncertain?.isEmpty == true { s.uncertain = nil }
                    replacements[index] = [s]
                    continue
                }

                // Riga divisa: l'orario si ripartisce in proporzione alla lunghezza delle parti.
                var result: [TranscriptSegment] = []
                var cursor = original.start
                let span = max(original.end - original.start, 0)
                for part in parts {
                    let share = span * Double(part.text.count) / Double(max(total, 1))
                    var s = TranscriptSegment(start: cursor, end: cursor + share, text: part.text,
                                              speaker: resolve(part.label, fallback: original.speaker))
                    let doubts = original.uncertain?.filter { part.text.contains($0) } ?? []
                    s.uncertain = doubts.isEmpty ? nil : doubts
                    result.append(s)
                    cursor += share
                }
                replacements[index] = result
            }
        }

        var output: [TranscriptSegment] = []
        for (i, seg) in segments.enumerated() {
            output.append(contentsOf: replacements[i] ?? [seg])
        }
        return RevisionResult(segments: output, suggestions: suggestions, title: proposedTitle, cost: totalCost)
    }

    /// Verifica rapida della chiave con una richiesta minima.
    static func test(key: String) async throws {
        _ = try await send(cachedContext: "Rispondi solo: OK", messages: [ClaudeMessage(role: "user", content: "Test")],
                           maxTokens: 5, model: .haiku, key: key)
    }
}
