import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

struct RecordingSection: Identifiable {
    let id: String
    let items: [Recording]
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]

    @State private var showRecorder = false
    @State private var autoStartRecording = false
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var importError: String?
    @State private var path: [Recording] = []
    @State private var search = ""
    @ObservedObject private var pipeline = Pipeline.shared
    @State private var toDelete: Recording?
    @ObservedObject private var updates = UpdateChecker.shared

    private var filtered: [Recording] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recordings }
        return recordings.filter { r in
            r.title.localizedCaseInsensitiveContains(q)
                || (r.transcript ?? "").localizedCaseInsensitiveContains(q)
                || r.notes.localizedCaseInsensitiveContains(q)
                || r.summaries.contains { $0.text.localizedCaseInsensitiveContains(q) }
                || r.speakerNames.values.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private var sections: [RecordingSection] {
        let cal = Calendar.current
        var order: [String] = []
        var groups: [String: [Recording]] = [:]
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "it_IT")
        monthFormatter.dateFormat = "LLLL yyyy"
        for r in filtered {
            let key: String
            if cal.isDateInToday(r.createdAt) {
                key = "Oggi"
            } else if cal.isDateInYesterday(r.createdAt) {
                key = "Ieri"
            } else if let days = cal.dateComponents([.day], from: r.createdAt, to: .now).day, days < 7 {
                key = "Questa settimana"
            } else {
                key = monthFormatter.string(from: r.createdAt).capitalized
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(r)
        }
        return order.map { RecordingSection(id: $0, items: groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let release = updates.available {
                    Button {
                        updates.install(release)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Aggiornamento disponibile · \(release.version)").font(.subheadline.weight(.semibold))
                                Text(release.notes.isEmpty ? "Installala dal Mac con Sideloadly" : release.notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text("Scarica").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                if recordings.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if filtered.isEmpty {
                    Text("Nessun risultato")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { recording in
                            ZStack {
                                NavigationLink(value: recording) { EmptyView() }.opacity(0)
                                RecordingCard(recording: recording)
                            }
                            .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    toDelete = recording
                                } label: {
                                    Label("Elimina", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    toDelete = recording
                                } label: {
                                    Label("Elimina", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text(section.id.uppercased())
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                Color.clear.frame(height: 90)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Registrazioni")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $search, prompt: "Cerca per argomento, persona o parola")
            .onOpenURL { url in
                // Widget "Registra" e pulsante del Centro di Controllo.
                guard url.host == "record" else { return }
                path = []
                autoStartRecording = true
                showRecorder = true
            }
            .onChange(of: showRecorder) { _, shown in
                if !shown { autoStartRecording = false }
            }
            .task {
                Pipeline.shared.resumePending(recordings, in: context)
                WhisperModel.shared.downloadIfAppropriate()
                await UpdateChecker.shared.check()
            }
            .navigationDestination(for: Recording.self) { recording in
                RecordingDetailView(recording: recording)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Impostazioni", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Importa audio", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .overlay(alignment: .bottom) { recordBar }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .fullScreenCover(isPresented: $showRecorder) {
                RecordView(autoStart: autoStartRecording) { finished in
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
            .confirmationDialog("Eliminare la registrazione?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
                Button("Elimina", role: .destructive) {
                    if let r = toDelete { delete(r) }
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Audio, trascrizione ed elaborazioni verranno cancellati.")
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - Pezzi

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.recordGradient)
            Text("Nessuna registrazione").font(.title3.bold())
            Text("Tocca il pulsante rosso per registrare, oppure importa un file audio.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 30)
    }

    private var recordBar: some View {
        HStack(spacing: 14) {
            Text("Nuova registrazione")
                .font(.subheadline.weight(.semibold))
                .padding(.leading, 12)
            Button {
                showRecorder = true
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Theme.recordGradient, in: Circle())
                    .shadow(color: Theme.magenta.opacity(0.35), radius: 9, y: 6)
            }
            .accessibilityLabel("Avvia registrazione")
        }
        .padding(10)
        .glass(cornerRadius: 42)
        .padding(.bottom, 8)
    }

    // MARK: - Azioni

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
        // Resta nell'elenco: la registrazione si lavora da sola e l'anteprima compare quando è pronta.
        pipeline.process(recording, in: context)
    }

    private func delete(_ recording: Recording) {
        Storage.delete(fileName: recording.audioFileName)
        context.delete(recording)
        try? context.save()
        toDelete = nil
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
            pipeline.process(recording, in: context)
        } catch {
            importError = error.localizedDescription
        }
    }
}

struct RecordingCard: View {
    let recording: Recording
    @ObservedObject private var pipeline = Pipeline.shared

    private var latestTemplateID: String? {
        recording.sortedSummaries.first?.templateID
    }

    private var meta: String {
        let time = recording.createdAt.formatted(.dateTime.hour().minute())
        let minutes = Int((recording.duration / 60).rounded())
        let length: String
        if recording.duration < 60 {
            length = "\(Int(recording.duration)) s"
        } else if minutes < 60 {
            length = "\(minutes) min"
        } else {
            length = "\(minutes / 60) h \(minutes % 60) min"
        }
        return "\(time) · \(length)"
    }

    var body: some View {
        let tile = Theme.tile(for: latestTemplateID)
        HStack(spacing: 12) {
            Image(systemName: Theme.icon(for: latestTemplateID))
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tile.foreground)
                .frame(width: 44, height: 44)
                .background(tile.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let status = pipeline.status[recording.id] {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(status).lineLimit(1)
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.accentText)
                } else if let preview = recording.preview {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(2)
                } else if recording.transcriptionError != nil {
                    Text("Trascrizione non riuscita: apri per riprovare")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Text(meta)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(14)
        .card()
    }
}
