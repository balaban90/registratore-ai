import Foundation
import UIKit

/// Controlla su GitHub se c'è una versione più recente e ne apre la pagina di download.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repository = "balaban90/registratore-ai"
    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases/latest")! }

    struct Release: Equatable {
        let version: String
        let build: Int
        let notes: String
        let ipaURL: URL
    }

    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published var lastMessage: String?
    private var lastCheck: Date?

    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let name: String?
        let body: String?
        let assets: [Asset]
    }

    /// Controlla al massimo una volta ogni 30 minuti, se non forzato.
    func check(force: Bool = false) async {
        if !force, let lastCheck, Date.now.timeIntervalSince(lastCheck) < 30 * 60 { return }
        guard !checking else { return }
        checking = true
        defer { checking = false }
        lastCheck = .now

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                lastMessage = status == 404 ? "Nessuna versione pubblicata." : "Controllo non riuscito (codice \(status))."
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            // Etichetta "v0.15.0-18": il numero dopo il trattino è la build.
            let build = Int(release.tag_name.split(separator: "-").last ?? "") ?? 0
            guard let ipa = release.assets.first(where: { $0.name.hasSuffix(".ipa") }) else { return }
            let version = release.tag_name.split(separator: "-").first.map(String.init) ?? release.tag_name
            if build > Self.currentBuild {
                let found = Release(version: version, build: build, notes: release.body ?? "", ipaURL: ipa.browser_download_url)
                if available != found {
                    DiagnosticLog.info(.app, "Aggiornamento disponibile: \(release.tag_name)")
                }
                available = found
                lastMessage = nil
            } else {
                available = nil
                lastMessage = "L'app è aggiornata."
            }
        } catch {
            lastMessage = "Controllo non riuscito: \(error.localizedDescription)"
        }
    }

    /// Apre la pagina della nuova versione: il file si installa dal Mac con Sideloadly.
    func install(_ release: Release) {
        DiagnosticLog.info(.app, "Apertura pagina della versione \(release.version) (\(release.build))")
        let page = URL(string: "https://github.com/\(Self.repository)/releases/tag/\(release.version)-\(release.build)") ?? Self.releasesPage
        UIApplication.shared.open(page)
    }
}
