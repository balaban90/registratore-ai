import SwiftUI
import SwiftData

struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct SpeakerEditTarget: Identifiable {
    let speakerId: String
    let segmentId: UUID?
    var id: String { speakerId + (segmentId?.uuidString ?? "") }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case summaries = "Elaborazioni"
    case transcript = "Trascrizione"
    case notes = "Note"
    var id: String { rawValue }
}

struct RecordingDetailView: View {
    @Bindable var recording: Recording
    @Environment(\.modelContext) private var context
    @StateObject private var player = AudioPlayer()
    @Query(sort: \CustomTemplate.createdAt) private var customTemplates: [CustomTemplate]
    @Query(sort: \GlossaryEntry.createdAt) private var glossary: [GlossaryEntry]
    @Query private var voiceProfiles: [VoiceProfile]
    @State private var isDiarizing = false
    @State private var editingSpeaker: SpeakerEditTarget?

    @State private var tab: DetailTab = .summaries
    @State private var isTranscribing = false
    @State private var isSummarizing = false
    @State private var isRevising = false
    @State private var progressText = ""
    @State private var errorText: String?
    @State private var shareItem: ShareItem?
    @State private var copiedNotice = false
    @State private var autoStarted = false
    @State private var showAsk = false
    @State private var claudeReady = ClaudeService.isConfigured
    @State private var showOriginal = false
    @State private var revisionCost: Double?

    private var templates: [SummaryTemplate] {
        SummaryTemplate.available(custom: customTemplates)
    }

    private var busy: Bool { isTranscribing || isSummarizing || isRevising || isDiarizing }

    private var shownSegments: [TranscriptSegment] {
        showOriginal && recording.revisedByClaude ? recording.originalSegments : recording.segments
    }

    private var currentSegmentID: UUID? {
        guard player.currentTime > 0 else { return nil }
        return shownSegments.last(where: { $0.start <= player.currentTime + 0.2 })?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    Picker("Sezione", selection: $tab) {
                        ForEach(DetailTab.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)

                    banners

                    switch tab {
                    case .summaries: summariesTab
                    case .transcript: transcriptTab
                    case .notes: notesTab
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 170)
            }
            .onChange(of: currentSegmentID) { _, id in
                guard let id, player.isPlaying, tab == .transcript else { return }
                withAnimation(.easeInOut) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { exportMenu }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
        .overlay(alignment: .bottom) {
            PlayerBar(player: player, highlights: recording.highlights)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
        .overlay(alignment: .top) {
            if copiedNotice {
                Text("Testo copiato: incollalo nella tua app AI se non compare tra le app")
                    .font(.footnote)
                    .padding(10)
                    .glass(cornerRadius: 20)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.items)
        }
        .sheet(isPresented: $showAsk) {
            AskClaudeView(recording: recording)
        }
        .sheet(item: $editingSpeaker) { target in
            SpeakerEditSheet(recording: recording, speakerId: target.speakerId, segmentId: target.segmentId)
        }
        .onAppear {
            claudeReady = ClaudeService.isConfigured
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
        .tint(Theme.accent)
    }

    // MARK: - Intestazione e avvisi

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Titolo", text: $recording.title, axis: .vertical)
                .font(.title.bold())
                .lineLimit(1...3)
            HStack(spacing: 14) {
                Label(recording.createdAt.formatted(.dateTime.day().month().hour().minute()), systemImage: "calendar")
                Label(formatTime(recording.duration), systemImage: "clock")
                if !recording.inputName.isEmpty {
                    Label(recording.inputName, systemImage: "mic").lineLimit(1)
                }
            }
            .labelStyle(CompactLabelStyle())
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if busy {
            HStack(spacing: 12) {
                ProgressView()
                Text(progressText).font(.callout)
                Spacer()
            }
            .padding(14)
            .card(cornerRadius: 16)
        }
        if let errorText {
            Label(errorText, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(cornerRadius: 16)
        }
    }

    // MARK: - Riassunti

    @ViewBuilder
    private var summariesTab: some View {
        if recording.transcript == nil {
            needsTranscript
        } else {
            HStack(spacing: 10) {
                Menu {
                    if claudeReady {
                        Section("AI avanzata (online)") {
                            ForEach(templates) { template in
                                Button { summarizeWithClaude(template) } label: {
                                    Label(template.name, systemImage: template.icon)
                                }
                            }
                        }
                    }
                    Section("AI sul telefono (offline)") {
                        ForEach(templates) { template in
                            Button { summarize(with: template) } label: {
                                Label(template.name, systemImage: template.icon)
                            }
                        }
                    }
                } label: {
                    Label("Nuova elaborazione", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                .disabled(busy)

                if claudeReady {
                    Button {
                        showAsk = true
                    } label: {
                        Label("Chiedi all'AI", systemImage: "bubble.left")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(Theme.accentDeep)
                    }
                } else {
                    sendToClaudeMenu {
                        Label("Condividi con un'app AI", systemImage: "paperplane")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(Theme.accentDeep)
                    }
                }
            }

            if !claudeReady {
                Text("Per usare l'AI avanzata dentro l'app, inserisci la chiave API in Impostazioni.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = SummaryService.availabilityMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            if recording.summaries.isEmpty {
                Text("Nessuna elaborazione. Scegli un modello da \"Nuova elaborazione\".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            }

            ForEach(recording.sortedSummaries) { summary in
                SummaryCard(summary: summary, recordingTitle: recording.title,
                            isStale: isStale(summary),
                            onShare: { items in shareItem = ShareItem(items: items) },
                            onDelete: {
                                context.delete(summary)
                                try? context.save()
                            },
                            onRegenerate: canRegenerate(summary) ? { regenerate(summary) } : nil)
            }
        }
    }

    private var needsTranscript: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.recordGradient)
            Text(isTranscribing ? "Trascrizione in corso…" : "Serve prima la trascrizione")
                .font(.headline)
            if !isTranscribing {
                Button {
                    transcribe()
                } label: {
                    Text(recording.transcriptionError == nil ? "Trascrivi" : "Riprova la trascrizione")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 22)
                        .frame(minHeight: 44)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .card(cornerRadius: 20)
    }

    private func sendToClaudeMenu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu {
            Section("Condividi con un'app AI") {
                ForEach(templates) { template in
                    Button { sendToClaude(with: template) } label: {
                        Label(template.name, systemImage: template.icon)
                    }
                }
            }
        } label: {
            label()
        }
    }

    // MARK: - Trascrizione

    @ViewBuilder
    private var transcriptTab: some View {
        if recording.transcript == nil {
            needsTranscript
        } else {
            HStack {
                if recording.revisedByClaude {
                    Picker("Versione", selection: $showOriginal) {
                        Text("Migliorata").tag(false)
                        Text("Originale").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
                Spacer()
                transcriptMenu
            }

            if let revisionCost {
                Text("Trascrizione migliorata · \(formatUSD(revisionCost))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !recording.highlights.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(recording.highlights.enumerated()), id: \.offset) { item in
                            Button {
                                player.seek(to: max(0, item.element - 5))
                            } label: {
                                Label(formatTime(item.element), systemImage: "flag.fill")
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .frame(height: 32)
                                    .background(Theme.highlight.opacity(0.16), in: Capsule())
                                    .foregroundStyle(Color(red: 0.6, green: 0.32, blue: 0))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if recording.diarized {
                speakerChips
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shownSegments.enumerated()), id: \.element.id) { item in
                    let index = item.offset
                    let segment = item.element
                    let isCurrent = segment.id == currentSegmentID
                    let newTurn = recording.diarized && segment.speaker != nil
                        && (index == 0 || shownSegments[index - 1].speaker != segment.speaker)
                    if newTurn, let speaker = segment.speaker {
                        Button {
                            editingSpeaker = SpeakerEditTarget(speakerId: speaker, segmentId: segment.id)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(SpeakerColors.color(for: speaker, in: recording.speakerOrder))
                                    .frame(width: 8, height: 8)
                                Text(recording.speakerName(speaker))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(SpeakerColors.color(for: speaker, in: recording.speakerOrder))
                                Image(systemName: "pencil").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, index == 0 ? 4 : 12)
                            .padding(.bottom, 2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Rinomina chi parla")
                    }
                    Button {
                        player.seek(to: segment.start)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(formatTime(segment.start))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(isCurrent ? Theme.accentText : .secondary)
                                .frame(width: 44, alignment: .leading)
                            Text(segment.text)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(isCurrent ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .id(segment.id)
                    .contextMenu {
                        if recording.diarized {
                            Menu("Attribuisci a…") {
                                ForEach(recording.speakerOrder, id: \.self) { speaker in
                                    Button(recording.speakerName(speaker)) {
                                        reassign(segment.id, to: speaker)
                                    }
                                }
                                Button("Nuova persona") {
                                    reassign(segment.id, to: "manual-\(UUID().uuidString.prefix(8))")
                                }
                            }
                        }
                        Button {
                            UIPasteboard.general.string = segment.text
                        } label: {
                            Label("Copia la frase", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            .padding(8)
            .card(cornerRadius: 20)
        }
    }

    private var speakerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recording.speakerOrder, id: \.self) { speaker in
                    let count = recording.segments.filter { $0.speaker == speaker }.count
                    Button {
                        editingSpeaker = SpeakerEditTarget(speakerId: speaker, segmentId: nil)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(SpeakerColors.color(for: speaker, in: recording.speakerOrder))
                                .frame(width: 8, height: 8)
                            Text(recording.speakerName(speaker)).font(.footnote.weight(.semibold))
                            Text("\(count)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var transcriptMenu: some View {
        Menu {
            Button {
                separateSpeakers()
            } label: {
                Label(recording.diarized ? "Separa di nuovo i parlanti" : "Separa i parlanti", systemImage: "person.2.wave.2")
            }
            if claudeReady {
                Button {
                    reviseWithClaude()
                } label: {
                    Label(recording.revisedByClaude ? "Migliora di nuovo con l'AI" : "Migliora con l'AI (≈1 cent/ora)", systemImage: "wand.and.stars")
                }
            }
            Button {
                applyGlossary()
            } label: {
                Label("Applica il glossario", systemImage: "character.book.closed")
            }
            if recording.revisedByClaude {
                Button(role: .destructive) {
                    restoreOriginal()
                } label: {
                    Label("Ripristina l'originale", systemImage: "arrow.uturn.backward")
                }
            }
            Button {
                transcribe()
            } label: {
                Label("Rifai la trascrizione", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())
        }
        .disabled(busy)
        .accessibilityLabel("Azioni sulla trascrizione")
    }

    // MARK: - Note

    private var notesTab: some View {
        TextField("Scrivi qui le tue note: partecipanti, contesto, cose da ricordare…", text: $recording.notes, axis: .vertical)
            .lineLimit(8...40)
            .padding(16)
            .card(cornerRadius: 20)
    }

    // MARK: - Menu della barra

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

    private var moreMenu: some View {
        Menu {
            if recording.transcript != nil {
                Menu {
                    ForEach(templates) { template in
                        Button { sendToClaude(with: template) } label: {
                            Label(template.name, systemImage: template.icon)
                        }
                    }
                } label: {
                    Label("Condividi con un'app AI", systemImage: "paperplane")
                }
            }
            Button {
                tab = .transcript
                transcribe()
            } label: {
                Label("Rifai la trascrizione", systemImage: "arrow.clockwise")
            }
            .disabled(busy)
        } label: {
            Label("Altro", systemImage: "ellipsis.circle")
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
                recording.segments = Glossary.apply(glossary, to: segments)
                recording.originalSegments = []
                recording.revisedByClaude = false
                showOriginal = false
                revisionCost = nil
                recording.diarized = false
                recording.speakerNames = [:]
                recording.transcript = recording.plainTranscript
                recording.transcriptionError = nil
                try? context.save()
                isTranscribing = false
                if DiarizationService.isEnabled {
                    separateSpeakers()
                }
            } catch {
                recording.transcriptionError = error.localizedDescription
                errorText = "Trascrizione non riuscita: \(error.localizedDescription)"
                isTranscribing = false
            }
        }
    }

    private func separateSpeakers() {
        guard !isDiarizing, !recording.segments.isEmpty else { return }
        isDiarizing = true
        errorText = nil
        progressText = "Separo le voci…"
        let url = recording.audioURL
        let known = voiceProfiles.map { KnownVoice(id: $0.speakerKey, name: $0.name, embedding: $0.embedding) }
        let profileNames = Dictionary(uniqueKeysWithValues: voiceProfiles.map { ($0.speakerKey, $0.name) })
        Task {
            do {
                let turns = try await DiarizationService.diarize(url: url, known: known) { message in
                    progressText = message
                }
                recording.segments = DiarizationService.assign(turns, to: recording.segments)
                if recording.revisedByClaude {
                    recording.originalSegments = DiarizationService.assign(turns, to: recording.originalSegments)
                }
                // I parlanti riconosciuti dai profili vocali prendono subito il nome.
                var names: [String: String] = [:]
                for id in recording.speakerOrder {
                    if let n = profileNames[id] { names[id] = n }
                }
                recording.speakerNames = names
                recording.diarized = true
                recording.speakerNamesUpdatedAt = .now
                recording.transcript = recording.plainTranscript
                try? context.save()
            } catch {
                errorText = "Separazione delle voci non riuscita: \(error.localizedDescription)"
            }
            isDiarizing = false
        }
    }

    private func reassign(_ segmentId: UUID, to speaker: String) {
        recording.segments = recording.segments.map { seg in
            var s = seg
            if s.id == segmentId { s.speaker = speaker }
            return s
        }
        recording.speakerNamesUpdatedAt = .now
        recording.transcript = recording.plainTranscript
        try? context.save()
    }

    // MARK: - Elaborazioni da aggiornare

    private func isStale(_ summary: Summary) -> Bool {
        guard recording.diarized, let changed = recording.speakerNamesUpdatedAt else { return false }
        return summary.templateID != "domanda" && changed > summary.createdAt
    }

    private func templateFor(_ summary: Summary) -> SummaryTemplate? {
        templates.first { $0.id == summary.templateID }
    }

    private func canRegenerate(_ summary: Summary) -> Bool {
        templateFor(summary) != nil
    }

    private func regenerate(_ summary: Summary) {
        guard let template = templateFor(summary) else { return }
        if summary.displayName.hasSuffix("· AI") && claudeReady {
            summarizeWithClaude(template, replacing: summary)
        } else {
            summarize(with: template, replacing: summary)
        }
    }

    private func summarize(with template: SummaryTemplate, replacing old: Summary? = nil) {
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
                if let old { context.delete(old) }
                try? context.save()
            } catch {
                errorText = error.localizedDescription
            }
            isSummarizing = false
        }
    }

    private func applyGlossary() {
        recording.segments = Glossary.apply(glossary, to: recording.segments)
        recording.transcript = recording.plainTranscript
        try? context.save()
    }

    private func restoreOriginal() {
        let original = recording.originalSegments
        guard !original.isEmpty else { return }
        recording.segments = original
        recording.originalSegments = []
        recording.revisedByClaude = false
        recording.transcript = recording.plainTranscript
        showOriginal = false
        try? context.save()
    }

    private func reviseWithClaude() {
        guard !isRevising else { return }
        // Si rivede sempre partendo dalla trascrizione automatica originale.
        let base = recording.revisedByClaude ? recording.originalSegments : recording.segments
        guard !base.isEmpty else { return }
        isRevising = true
        errorText = nil
        progressText = "L'AI migliora la trascrizione…"
        let title = recording.title
        let notes = recording.notes
        let terms = Glossary.termsForClaude(glossary)
        Task {
            do {
                let result = try await ClaudeService.revise(segments: base, title: title, notes: notes, glossaryTerms: terms) { message in
                    progressText = message
                }
                if !recording.revisedByClaude {
                    recording.originalSegments = base
                }
                recording.segments = Glossary.apply(glossary, to: result.segments)
                recording.revisedByClaude = true
                recording.transcript = recording.plainTranscript
                showOriginal = false
                try? context.save()
                revisionCost = result.cost
            } catch {
                errorText = "Miglioramento non riuscito: \(error.localizedDescription)"
            }
            isRevising = false
        }
    }

    private func summarizeWithClaude(_ template: SummaryTemplate, replacing old: Summary? = nil) {
        guard recording.transcript != nil, !isSummarizing else { return }
        isSummarizing = true
        errorText = nil
        progressText = "L'AI sta scrivendo l'elaborazione…"
        let title = recording.title
        let transcript = recording.compactTranscript
        Task {
            do {
                let reply = try await ClaudeService.summarize(title: title, transcript: transcript, template: template)
                let summary = Summary(templateID: template.id, templateName: "\(template.name) · AI", text: reply.text, costUSD: reply.costUSD)
                summary.recording = recording
                context.insert(summary)
                if let old { context.delete(old) }
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

// MARK: - Componenti

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

struct SummaryCard: View {
    let summary: Summary
    let recordingTitle: String
    var isStale: Bool = false
    let onShare: ([Any]) -> Void
    let onDelete: () -> Void
    var onRegenerate: (() -> Void)? = nil

    var body: some View {
        let tile = Theme.tile(for: summary.templateID)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: Theme.icon(for: summary.templateID))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tile.foreground)
                    .frame(width: 28, height: 28)
                    .background(tile.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(summary.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if summary.costUSD > 0 {
                    Text(formatUSD(summary.costUSD)).font(.caption).foregroundStyle(.secondary)
                }
                Menu {
                    Button { UIPasteboard.general.string = summary.text } label: { Label("Copia", systemImage: "doc.on.doc") }
                    Button { onShare([summary.text]) } label: { Label("Condividi testo", systemImage: "square.and.arrow.up") }
                    Button {
                        if let url = ExportService.pdf(title: "\(recordingTitle) – \(summary.templateName)", body: summary.text) { onShare([url]) }
                    } label: { Label("PDF", systemImage: "doc.richtext") }
                    Button {
                        if let url = ExportService.rtf(title: "\(recordingTitle) – \(summary.templateName)", body: summary.text) { onShare([url]) }
                    } label: { Label("Word / Pages (RTF)", systemImage: "doc.text") }
                    Divider()
                    Button(role: .destructive, action: onDelete) { Label("Elimina", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Azioni sull'elaborazione")
            }
            if isStale {
                HStack(spacing: 10) {
                    Image(systemName: "person.2.badge.gearshape")
                        .foregroundStyle(Theme.accentText)
                    Text("I nomi dei parlanti sono cambiati dopo questa elaborazione.")
                        .font(.footnote)
                    Spacer(minLength: 4)
                    if let onRegenerate {
                        Button("Rigenera", action: onRegenerate)
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            MarkdownText(text: summary.text)
        }
        .padding(18)
        .card(cornerRadius: 20)
    }
}

/// Riproduttore agganciato in basso, con i momenti segnati sulla barra.
struct PlayerBar: View {
    @ObservedObject var player: AudioPlayer
    let highlights: [Double]
    @State private var dragProgress: Double?

    private var progress: Double {
        if let dragProgress { return dragProgress }
        guard player.duration > 0 else { return 0 }
        return min(1, player.currentTime / player.duration)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray4)).frame(height: 4)
                    Capsule().fill(Theme.accent).frame(width: geo.size.width * progress, height: 4)
                    ForEach(Array(highlights.enumerated()), id: \.offset) { item in
                        if player.duration > 0 {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Theme.highlight)
                                .frame(width: 3, height: 10)
                                .offset(x: geo.size.width * min(1, item.element / player.duration) - 1.5)
                        }
                    }
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragProgress = max(0, min(1, value.location.x / max(geo.size.width, 1)))
                        }
                        .onEnded { value in
                            let p = max(0, min(1, value.location.x / max(geo.size.width, 1)))
                            player.seek(to: p * player.duration, play: player.isPlaying)
                            dragProgress = nil
                        }
                )
            }
            .frame(height: 24)

            HStack {
                Text(formatTime(dragProgress.map { $0 * player.duration } ?? player.currentTime))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 36) {
                Button { player.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title2).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Indietro di 15 secondi")
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 54, height: 54)
                        .background(Color(.label), in: Circle())
                }
                .accessibilityLabel(player.isPlaying ? "Pausa" : "Riproduci")
                Button { player.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title2).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Avanti di 15 secondi")
            }
            .foregroundStyle(.primary)
            .buttonStyle(.plain)

            if let error = player.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glass(cornerRadius: 26)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
