import Foundation

enum ClaudeModel: String, CaseIterable, Identifiable {
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    case opus = "claude-opus-5-5"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sonnet: return "Sonnet – consigliato"
        case .haiku: return "Haiku – veloce ed economico"
        case .opus: return "Opus – il più accurato"
        }
    }
}

struct ClaudeMessage: Codable, Identifiable, Hashable {
    var id = UUID()
    let role: String   // "user" o "assistant"
    let content: String

    enum CodingKeys: String, CodingKey { case role, content }
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
            switch code {
            case 401: return "Chiave API non valida. Controllala in Impostazioni."
            case 402, 403: return "Credito API esaurito o non abilitato: \(message)"
            case 429: return "Troppe richieste o credito esaurito. Riprova tra poco."
            case 529, 503: return "Claude è sovraccarico in questo momento. Riprova tra poco."
            default: return "Errore di Claude (\(code)): \(message)"
            }
        case .emptyResponse:
            return "Claude non ha restituito testo."
        }
    }
}

/// Chiamate dirette alla Claude API. Esce solo testo, mai l'audio.
enum ClaudeService {
    static let keychainKey = "anthropic_api_key"
    static let modelDefaultsKey = "claudeModel"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static var apiKey: String? {
        guard let k = Keychain.get(keychainKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return nil }
        return k
    }

    static var isConfigured: Bool { apiKey != nil }

    static var model: ClaudeModel {
        ClaudeModel(rawValue: UserDefaults.standard.string(forKey: modelDefaultsKey) ?? "") ?? .sonnet
    }

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [ClaudeMessage]
    }

    private struct ResponseBody: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    static func send(system: String, messages: [ClaudeMessage], maxTokens: Int = 4096, model: ClaudeModel? = nil, key: String? = nil) async throws -> String {
        guard let apiKey = key ?? apiKey else { throw ClaudeFailure.missingKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(model: (model ?? self.model).rawValue, max_tokens: maxTokens, system: system, messages: messages)
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
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func summarize(title: String, transcript: String, template: SummaryTemplate) async throws -> String {
        let system = """
        Sei l'assistente di un funzionario sindacale della sanità. \(template.instructions)

        \(SummaryTemplate.commonRules)
        """
        let prompt = "Registrazione: \"\(title)\"\n\nTRASCRIZIONE AUTOMATICA:\n\(transcript)"
        return try await send(system: system, messages: [ClaudeMessage(role: "user", content: prompt)])
    }

    static func chatSystemPrompt(title: String, transcript: String, notes: String) -> String {
        var s = """
        Sei l'assistente di un funzionario sindacale della sanità. Rispondi in italiano, in modo chiaro e conciso.
        Rispondi basandoti sulla trascrizione qui sotto; se qualcosa non è nella trascrizione, dillo.
        Quando citi un passaggio, indica l'orario tra parentesi quadre come appare nel testo, ad esempio [12:34].
        La trascrizione è automatica e può contenere errori di riconoscimento.

        REGISTRAZIONE: "\(title)"
        """
        if !notes.isEmpty { s += "\n\nNOTE DELL'UTENTE:\n\(notes)" }
        s += "\n\nTRASCRIZIONE (con orari):\n\(transcript)"
        return s
    }

    /// Verifica rapida della chiave con una richiesta minima.
    static func test(key: String) async throws {
        _ = try await send(system: "Rispondi solo: OK", messages: [ClaudeMessage(role: "user", content: "Test")], maxTokens: 5, model: .haiku, key: key)
    }
}
