import Foundation
import SwiftData
import AVFoundation

/// Salvataggio di una registrazione appena fatta e importazione di un file audio.
/// Usati sia dalla scheda Registra sia dall'elenco delle registrazioni.
enum RecordingActions {
    @MainActor
    static func save(_ finished: FinishedRecording, in context: ModelContext) {
        let recording = Recording(
            title: defaultTitle(for: finished.startedAt),
            audioFileName: finished.fileName,
            duration: finished.duration,
            inputName: finished.inputName,
            highlights: finished.highlights,
            createdAt: finished.startedAt
        )
        context.insert(recording)
        try? context.save()
        // La registrazione si lavora da sola: l'anteprima compare nell'elenco quando è pronta.
        Pipeline.shared.process(recording, in: context)
    }

    /// Elimina una registrazione; se è in lavorazione, prima la ferma.
    @MainActor
    static func delete(_ recording: Recording, in context: ModelContext) {
        Pipeline.shared.cancel(recording)
        Storage.delete(fileName: recording.audioFileName)
        context.delete(recording)
        try? context.save()
    }

    @MainActor
    static func importAudio(_ result: Result<[URL], Error>, in context: ModelContext) async throws {
        guard let source = try result.get().first else { return }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let name = Storage.newFileName(ext: ext)
        try FileManager.default.copyItem(at: source, to: Storage.url(for: name))

        let asset = AVURLAsset(url: Storage.url(for: name))
        let duration = (try? await asset.load(.duration).seconds) ?? 0

        let title = source.deletingPathExtension().lastPathComponent
        let recording = Recording(title: title, audioFileName: name, duration: duration, inputName: "File importato")
        context.insert(recording)
        try? context.save()
        Pipeline.shared.process(recording, in: context)
    }
}
