import Foundation
import Network
import WhisperKit

/// Stato della rete: serve a scaricare il modello del motore Preciso solo con Wi-Fi o rete non a consumo.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private(set) var isUnmetered = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isUnmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
        }
        monitor.start(queue: DispatchQueue(label: "network-status"))
    }
}

/// Modello del motore Preciso (Whisper Large v3 Turbo, circa 630 MB), salvato
/// nei dati dell'app e non nella cartella visibile in File.
@MainActor
final class WhisperModel: ObservableObject {
    static let shared = WhisperModel()

    static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let repo = "argmaxinc/whisperkit-coreml"

    /// Avanzamento del download (0…1), nil se non è in corso.
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var lastError: String?

    nonisolated static var base: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appending(component: "Whisper")
    }

    nonisolated static var folder: URL {
        base.appending(path: "models/\(repo)/\(variant)")
    }

    nonisolated static var isReady: Bool {
        let fm = FileManager.default
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            fm.fileExists(atPath: folder.appending(component: $0).path)
        }
    }

    private init() {
        Self.migrateOldLocation()
    }

    /// Le versioni precedenti scaricavano il modello in Documenti (visibile in File): lo sposta, senza riscaricarlo.
    nonisolated private static func migrateOldLocation() {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let old = documents.appending(component: "huggingface")
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: base.path) else { return }
        try? fm.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: old, to: base)
    }

    /// Avvia il download in background, solo se serve e se la rete non è a consumo.
    func downloadIfAppropriate() {
        guard !Self.isReady, downloadProgress == nil, NetworkStatus.shared.isUnmetered else { return }
        downloadProgress = 0
        lastError = nil
        Task {
            do {
                try FileManager.default.createDirectory(at: Self.base, withIntermediateDirectories: true)
                var url = Self.base
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? url.setResourceValues(values)
                _ = try await WhisperKit.download(variant: Self.variant, downloadBase: Self.base, from: Self.repo) { progress in
                    let value = progress.fractionCompleted
                    Task { @MainActor in WhisperModel.shared.downloadProgress = value }
                }
            } catch {
                lastError = error.localizedDescription
            }
            downloadProgress = nil
        }
    }
}
