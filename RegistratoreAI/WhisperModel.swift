import Foundation
import Network
import WhisperKit
import UIKit

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

    /// true mentre il modello si sta scaricando: in quel momento non va usato.
    nonisolated(unsafe) static var isDownloading = false

    /// Pronto solo se ci sono davvero tutti i file pesanti (non solo le cartelle) e non è in corso un download.
    nonisolated static var isReady: Bool {
        guard !isDownloading else { return false }
        let fm = FileManager.default
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].flatMap {
            ["\($0)/coremldata.bin", "\($0)/weights/weight.bin"]
        } + ["config.json"]
        return required.allSatisfy { fm.fileExists(atPath: folder.appending(path: $0).path) }
    }

    /// Cancella un modello danneggiato o incompleto: verrà riscaricato con il Wi-Fi.
    nonisolated static func discard() {
        try? FileManager.default.removeItem(at: folder)
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
    /// Se per 2 minuti non avanza, lo interrompe: riproverà alla prossima occasione.
    func downloadIfAppropriate() {
        guard TranscriptionEngine.current != .fast, !Self.isReady, downloadProgress == nil,
              NetworkStatus.shared.isUnmetered else { return }
        downloadProgress = 0
        lastError = nil
        Self.isDownloading = true
        DiagnosticLog.info(.whisper, "Inizio download del modello Preciso")

        let download = Task {
            try FileManager.default.createDirectory(at: Self.base, withIntermediateDirectories: true)
            var url = Self.base
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            // Sessione di download in background: continua anche a schermo bloccato.
            _ = try await WhisperKit.download(variant: Self.variant, downloadBase: Self.base,
                                              useBackgroundSession: true, from: Self.repo) { progress in
                let value = progress.fractionCompleted
                Task { @MainActor in
                    WhisperModel.shared.downloadProgress = value
                }
            }
        }
        let watchdog = Task {
            // Conta solo il tempo con l'app aperta: in background il download prosegue per conto suo.
            var stalled = 0.0
            var lastSeen = downloadProgress ?? 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard UIApplication.shared.applicationState == .active else { continue }
                let now = downloadProgress ?? 0
                stalled = now > lastSeen ? 0 : stalled + 15
                lastSeen = now
                if stalled >= 180 { download.cancel(); break }
            }
        }
        Task {
            do {
                try await download.value
                DiagnosticLog.info(.whisper, "Download completato · pronto: \(Self.isReady ? "sì" : "no")")
            } catch {
                lastError = download.isCancelled ? "Download fermo: riproverà più tardi." : error.localizedDescription
                if download.isCancelled {
                    DiagnosticLog.warning(.whisper, "Download fermo da 3 minuti al \(Int((downloadProgress ?? 0) * 100))%: interrotto")
                } else {
                    DiagnosticLog.error(.whisper, "Download fallito al \(Int((downloadProgress ?? 0) * 100))%", error)
                }
            }
            watchdog.cancel()
            Self.isDownloading = false
            downloadProgress = nil
        }
    }
}
