import Foundation
import SwiftData
import UIKit

/// Invia il rapporto diagnostico a un repository GitHub privato, dove viene analizzato
/// per correggere i problemi. Parte da solo quando l'app registra un errore o un crash.
@MainActor
final class DiagnosticUploader: ObservableObject {
    static let shared = DiagnosticUploader()

    static let repository = "balaban90/registratore-ai-diagnostica"
    static let tokenKey = "github_diagnostics_token"
    static let autoKey = "diagnosticsAutoUpload"
    static let pendingKey = "diagnosticsPending"
    static let lastSentKey = "diagnosticsLastSent"
    /// Intervallo minimo tra due invii automatici.
    private static let minimumInterval: TimeInterval = 10 * 60

    static var token: String? {
        guard let t = Keychain.get(tokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
    static var isConfigured: Bool { token != nil }
    static var autoUpload: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
    static var lastSent: Date? { UserDefaults.standard.object(forKey: lastSentKey) as? Date }

    /// Segna che c'è un problema nuovo da inviare (chiamato dal registro a ogni errore).
    nonisolated static func markPending() {
        UserDefaults.standard.set(true, forKey: pendingKey)
    }
    static var hasPending: Bool { UserDefaults.standard.bool(forKey: pendingKey) }

    var container: ModelContainer?
    @Published private(set) var sending = false
    @Published var lastResult: String?

    // MARK: - Invio

    /// Invio automatico: solo se attivo, configurato, c'è un problema nuovo e non si è appena inviato.
    func sendIfNeeded(reason: String) {
        guard !TestSupport.isTesting, Self.autoUpload, Self.isConfigured, Self.hasPending, !sending else { return }
        if let last = Self.lastSent, Date.now.timeIntervalSince(last) < Self.minimumInterval { return }
        Task { _ = await send(reason: "automatico · \(reason)", note: nil) }
    }

    /// Invia subito il rapporto. Restituisce true se è arrivato.
    @discardableResult
    func send(reason: String, note: String?) async -> Bool {
        guard !TestSupport.isTesting else { return false }
        guard let token = Self.token else {
            lastResult = "Inserisci prima il token GitHub."
            return false
        }
        guard let container, !sending else { return false }
        sending = true
        defer { sending = false }

        // Finisce l'invio anche se l'app va in background.
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "Invio diagnostica") {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        defer { if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) } }

        // Il problema viene considerato inviato da qui: errori nuovi durante l'invio restano in sospeso.
        UserDefaults.standard.set(false, forKey: Self.pendingKey)
        guard let file = DiagnosticLog.makeReport(context: container.mainContext, reason: reason, note: note, maxLogBytes: 400_000),
              let data = try? Data(contentsOf: file) else {
            UserDefaults.standard.set(true, forKey: Self.pendingKey)
            lastResult = "Non riesco a preparare il rapporto."
            return false
        }

        let path = "diagnostica/\(file.lastPathComponent)"
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/contents/\(path)")!)
        request.httpMethod = "PUT"
        request.timeoutInterval = 60
        Self.authorize(&request, token: token)
        let body: [String: String] = [
            "message": "Diagnostica \(Self.appVersion) · \(reason)",
            "content": data.base64EncodedString()
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                UserDefaults.standard.set(true, forKey: Self.pendingKey)
                lastResult = Self.message(for: status)
                let detail = String(data: responseData, encoding: .utf8)?.prefix(300) ?? ""
                DiagnosticLog.warning(.app, "Invio diagnostica rifiutato: HTTP \(status) \(detail)")
                return false
            }
            UserDefaults.standard.set(Date.now, forKey: Self.lastSentKey)
            lastResult = "Inviato alle \(Date.now.formatted(date: .omitted, time: .shortened))."
            DiagnosticLog.info(.app, "Diagnostica inviata (\(reason)) · \(data.count) byte")
            return true
        } catch {
            UserDefaults.standard.set(true, forKey: Self.pendingKey)
            lastResult = "Invio non riuscito: \(error.localizedDescription). Riproverà più tardi."
            DiagnosticLog.warning(.app, "Invio diagnostica non riuscito: \(DiagnosticLog.describe(error))")
            return false
        }
    }

    /// Verifica che il token possa scrivere nel repository della diagnostica.
    func test(token: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)")!)
        request.timeoutInterval = 30
        Self.authorize(&request, token: token)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return Self.message(for: status) }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let permissions = json["permissions"] as? [String: Bool], permissions["push"] == false {
                return "Il token può solo leggere: dagli il permesso Contents \"Read and write\"."
            }
            return nil
        } catch {
            return "Nessuna connessione: \(error.localizedDescription)"
        }
    }

    // MARK: - Utilità

    private static func authorize(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    private static func message(for status: Int) -> String {
        switch status {
        case 401: return "Token non valido o scaduto."
        case 403: return "Il token non ha il permesso di scrivere (serve Contents \"Read and write\")."
        case 404: return "Repository \(repository) non trovato o non incluso nel token."
        case 422: return "GitHub ha rifiutato il file."
        default: return "Errore GitHub (codice \(status))."
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "v\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
