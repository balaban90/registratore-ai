import SwiftUI
import SwiftData

struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct RecordingDetailView: View {
    @Bindable var recording: Recording
    @Environment(\.modelContext) private var context
    @StateObject private var player = AudioPlayer()

    @State private var isTranscribing = false
    @State private var isSummarizing = false
    @State private var progressText = ""
    @State private var errorText: String?
    @State private var shareItem: ShareItem?
    @State private var copiedNotice = false
    @State private var autoStarted = false

    var body: some View {
        List {
            Section {
                TextField("Titolo", text: $recording.title, axis: .vertical)
                    .font(.headline)
                LabeledContent("Data", value: recording.createdAt.formatted(.dateTime.day().month().year().hour().minute()))
                LabeledContent("Durata", value: formatTime(recording.duration))
                if !recording.inputName.isEmpty {
                    LabeledContent("Microfono", value: recording.inputName)
                }
            }

            playerSection

            if !recording.highlights.isEmpty {
                Section("Momenti segnati") {
                    ForEach(Array(recording.highlights.enumerated()), id: \.offset) { item in
                        Button {
                            player.seek(to: max(0, item.element - 5))
                        } label: {
                            Label("Momento \(item.offset + 1) · \(formatTime(item.element))", systemImage: "flag.fill")
                        }
                        .tint(.orange)
                    }
                }
            }

            if isTranscribing || isSummarizing {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(progressText).font(.callout)
                    }
                }
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            summariesSection
            transcriptSection

            Section("Note") {
                TextField("Aggiungi note…", text: $recording.notes, axis: .vertical)
                    .lineLimit(3...10)
            }
        }
        .navigationTitle("Dettaglio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { exportMenu }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.items)
        }
        .overlay(alignment: .bottom) {
            if copiedNotice {
                Text("Testo copiato: incollalo in Claude se non compare tra le app")
                    .font(.footnote)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .onAppear {
            player.load(url: recording.audioURL)
            if !autoStarted && recording.transcript == nil && recording.transcriptionError == nil {
                autoStarted = true
                transcribe()
            }
        }
        .onDisappear {
            player.stop()
            try? context.save()
        }
    }

    // MARK: - Sezioni

    private var playerSection: some View {
        Section {
            VStack(spacing: 8) {
                Slider(
                    value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                    in: 0...max(player.duration, 1)
                )
                HStack {
                    Text(formatTime(player.currentTime))
                    Spacer()
                    Text(formatTime(player.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                HStack(spacing: 40) {
                    Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                    }
                    Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                }
                .font(.title2)
                .buttonStyle(.borderless)
            }
            if let error = player.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var summariesSection: some View {
        Section {
            if recording.transcript != nil {
                Menu {
                    ForEach(SummaryTemplate.all) { template in
                        Button {
                            summarize(with: template)
                        } label: {
                            Label(template.name, systemImage: template.icon)
                        }
                    }
                } label: {
                    Label("Nuovo riassunto (sul telefono)", systemImage: "sparkles")
                }
                .disabled(isSummarizing || isTranscribing)

                Menu {
                    ForEach(SummaryTemplate.all) { template in
                        Button {
                            sendToClaude(with: template)
                        } label: {
                            Label(template.name, systemImage: template.icon)
                        }
                    }
                } label: {
                    Label("Invia a Claude…", systemImage: "paperplane")
                }

                if let message = SummaryService.availabilityMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach(recording.sortedSummaries) { summary in
                NavigationLink {
                    SummaryDetailView(summary: summary, recordingTitle: recording.title)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.templateName).font(.subheadline.weight(.semibold))
                        Text(summary.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .onDelete { offsets in
                let list = recording.sortedSummaries
                for i in offsets { context.delete(list[i]) }
                try? context.save()
            }
        } header: {
            Text("Riassunti")
        }
    }

    private var transcriptSection: some View {
        Section {
            if recording.transcript == nil {
                Button {
                    transcribe()
                } label: {
                    Label(recording.transcriptionError == nil ? "Trascrivi" : "Riprova la trascrizione", systemImage: "text.bubble")
                }
                .disabled(isTranscribing)
            } else {
                ForEach(recording.segments) { segment in
                    Button {
                        player.seek(to: segment.start)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatTime(segment.start))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(segment.text)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Trascrizione")
                Spacer()
                if recording.transcript != nil {
                    Button("Rifai") { transcribe() }
                        .font(.caption)
                        .disabled(isTranscribing)
                }
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            Section("Trascrizione") {
                Button("PDF") { share(ExportService.pdf(title: recording.title, body: recording.timedTranscript)) }
                Button("Word / Pages (RTF)") { share(ExportService.rtf(title: recording.title, body: recording.timedTranscript)) }
                Button("Testo") { share(ExportService.text(title: recording.title, body: recording.timedTranscript)) }
            }
            .disabled(recording.transcript == nil)
            Section {
                Button("File audio") { shareItem = ShareItem(items: [recording.audioURL]) }
            }
        } label: {
            Label("Esporta", systemImage: "square.and.arrow.up")
        }
    }

    // MARK: - Azioni

    private func share(_ url: URL?) {
        guard let url else {
            errorText = "Esportazione non riuscita"
            return
        }
        shareItem = ShareItem(items: [url])
    }

    private func transcribe() {
        guard !isTranscribing else { return }
        isTranscribing = true
        errorText = nil
        progressText = "Avvio…"
        let url = recording.audioURL
        Task {
            do {
                let segments = try await TranscriptionService.transcribe(url: url) { message in
                    progressText = message
                }
                recording.segments = segments
                recording.transcript = recording.plainTranscript
                recording.transcriptionError = nil
                try? context.save()
            } catch {
                recording.transcriptionError = error.localizedDescription
                errorText = "Trascrizione non riuscita: \(error.localizedDescription)"
            }
            isTranscribing = false
        }
    }

    private func summarize(with template: SummaryTemplate) {
        guard let transcript = recording.transcript, !isSummarizing else { return }
        isSummarizing = true
        errorText = nil
        progressText = "Avvio…"
        Task {
            do {
                let text = try await SummaryService.summarize(transcript: transcript, template: template) { message in
                    progressText = message
                }
                let summary = Summary(templateID: template.id, templateName: template.name, text: text)
                summary.recording = recording
                context.insert(summary)
                try? context.save()
            } catch {
                errorText = error.localizedDescription
            }
            isSummarizing = false
        }
    }

    private func sendToClaude(with template: SummaryTemplate) {
        guard let transcript = recording.transcript else { return }
        let prompt = template.claudePrompt(title: recording.title, transcript: transcript)
        UIPasteboard.general.string = prompt
        shareItem = ShareItem(items: [prompt])
        withAnimation { copiedNotice = true }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { copiedNotice = false }
        }
    }
}

struct SummaryDetailView: View {
    @Bindable var summary: Summary
    let recordingTitle: String
    @State private var shareItem: ShareItem?

    var body: some View {
        ScrollView {
            Text(summary.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(summary.templateName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Condividi testo") { shareItem = ShareItem(items: [summary.text]) }
                    Button("PDF") {
                        if let url = ExportService.pdf(title: "\(recordingTitle) – \(summary.templateName)", body: summary.text) {
                            shareItem = ShareItem(items: [url])
                        }
                    }
                    Button("Word / Pages (RTF)") {
                        if let url = ExportService.rtf(title: "\(recordingTitle) – \(summary.templateName)", body: summary.text) {
                            shareItem = ShareItem(items: [url])
                        }
                    }
                    Button("Copia") { UIPasteboard.general.string = summary.text }
                } label: {
                    Label("Esporta", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.items)
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
