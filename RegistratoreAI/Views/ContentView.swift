import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]

    @State private var showRecorder = false
    @State private var showImporter = false
    @State private var importError: String?
    @State private var path: [Recording] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if recordings.isEmpty {
                    ContentUnavailableView(
                        "Nessuna registrazione",
                        systemImage: "waveform",
                        description: Text("Tocca il pulsante rosso per registrare, oppure importa un file audio.")
                    )
                } else {
                    List {
                        ForEach(recordings) { recording in
                            NavigationLink(value: recording) {
                                RecordingRow(recording: recording)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Registratore AI")
            .navigationDestination(for: Recording.self) { recording in
                RecordingDetailView(recording: recording)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Importa audio", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showRecorder = true
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(.red))
                        .shadow(radius: 4)
                }
                .accessibilityLabel("Nuova registrazione")
                .padding(.bottom, 8)
            }
            .fullScreenCover(isPresented: $showRecorder) {
                RecordView { finished in
                    save(finished)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                Task { await importAudio(result) }
            }
            .alert("Importazione non riuscita", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func save(_ finished: FinishedRecording) {
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
        path = [recording] // apre subito il dettaglio, che avvia la trascrizione
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let recording = recordings[index]
            Storage.delete(fileName: recording.audioFileName)
            context.delete(recording)
        }
        try? context.save()
    }

    private func importAudio(_ result: Result<[URL], Error>) async {
        do {
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
            path = [recording]
        } catch {
            importError = error.localizedDescription
        }
    }
}

struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(recording.createdAt.formatted(.dateTime.day().month().year().hour().minute()))
                Text("·")
                Text(formatTime(recording.duration))
                Spacer()
                if !recording.summaries.isEmpty {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                } else if recording.transcript != nil {
                    Image(systemName: "text.alignleft").foregroundStyle(.blue)
                } else {
                    Text("Da trascrivere").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
