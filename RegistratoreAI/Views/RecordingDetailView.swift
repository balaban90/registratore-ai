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
    /// Punto da cui ascoltare all'apertura (da una fonte di "Chiedi all'archivio").
    var startAt: Double? = nil
    @Environment(\.modelContext) private var context
    /// Non osservato qui: altrimenti l'intera schermata si ridisegnerebbe 4 volte al secondo
    /// durante la riproduzione. Lo osservano solo la barra del riproduttore e PlaybackFollower.
    @State private var player = AudioPlayer()
    @State private var currentSegmentID: UUID?
    @Query(sort: \CustomTemplate.createdAt) private var customTemplates: [CustomTemplate]
    @Query(sort: \GlossaryEntry.createdAt) private var glossary: [GlossaryEntry]
    @Query private var voiceProfiles: [VoiceProfile]
    @ObservedObject private var pipeline = Pipeline.shared
    @State private var editingSpeaker: SpeakerEditTarget?

    @State private var tab: DetailTab = .summaries
    @State private var isSummarizing = false
    @State private var progressText = ""
    @State private var errorText: String?
    @State private var shareItem: ShareItem?
    @State private var copiedNotice = false
    @State private var autoStarted = false
    @State private var showAsk = false
    @State private var claudeReady = ClaudeService.isConfigured
    @State private var showOriginal = false
    @State private var engineChoice: EngineChoice = .automatic
    @State private var startApplied = false
    @State private var pendingReminders: PendingReminders?
    @State private var notice: String?

    private var templates: [SummaryTemplate] {
        SummaryTemplate.available(custom: customTemplates)
    }

    private var busy: Bool { isSummarizing || pipeline.isRunning(recording) }
    private var isTranscribing: Bool { pipeline.isRunning(recording) && recording.transcript == nil }

    private var shownSegments: [TranscriptSegment] {
        showOriginal && recording.revisedByClaude ? recording.originalSegments : recording.segments
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
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background {
            PlaybackFollower(player: player, segments: tab == .transcript ? shownSegments : [], current: $currentSegmentID)
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
            } else if let notice {
                Text(notice)
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
        .confirmationDialog(remindersTitle, isPresented: remindersShown, titleVisibility: .visible) {
            Button("Aggiungi") {
                if let pending = pendingReminders { addReminders(pending.tasks) }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text(remindersList)
        }
        .onAppear {
            claudeReady = ClaudeService.isConfigured
            player.load(url: recording.audioURL)
            if let startAt, !startApplied {
                startApplied = true
                tab = .transcript
                player.seek(to: max(0, startAt - 2), play: true)
            }
            if !autoStarted && recording.transcript == nil && recording.transcriptionError == nil {
                autoStarted = true
                pipeline.process(recording, in: context)
            }
        }
        .onDisappear {
            player.stop()
            try? context.save()
        }
        .tint(Theme.accent)
    }

    // MARK: - Promemoria

    private var remindersTitle: String {
        let n = pendingReminders?.tasks.count ?? 0
        return n == 1 ? "Aggiungere 1 cosa da fare a Promemoria?" : "Aggiungere \(n) cose da fare a Promemoria?"
    }

    private var remindersList: String {
        (pendingReminders?.tasks ?? []).map { "• " + $0 }.joined(separator: "\n")
    }

    private var remindersShown: Binding<Bool> {
        Binding(get: { pendingReminders != nil }, set: { if !$0 { pendingReminders = nil } })
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
                Text(pipeline.status[recording.id] ?? progressText).font(.callout)
                Spacer()
            }
            .padding(14)
            .card(cornerRadius: 16)
        }
        if let errorText = errorText ?? pipeline.errors[recording.id] {
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
                    Section {
                        ForEach(templates) { template in
                            let engine = engineToUse(for: template)
                            Button { run(template, on: engine) } label: {
                                Label {
                                    Text(template.name)
                                    Text(engine.label)
                                } icon: {
                                    Image(systemName: template.icon)
                                }
                            }
                        }
                    }
                    // Un'unica scelta: chi fa l'elaborazione. "Automatico" usa il motore consigliato per ogni modello.
                    Section {
                        Picker(selection: $engineChoice) {
                            ForEach(availableChoices) { choice in
                                Text(choice.label).tag(choice)
                            }
                        } label: {
                            Label {
                                Text("Motore")
                                Text(engineChoice.label)
                            } icon: {
                                Image(systemName: "cpu")
                            }
                        }
                        .pickerStyle(.menu)
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
                Text("Per usare l'AI avanzata, inserisci la chiave API in Impostazioni.")
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
                            onRegenerate: canRegenerate(summary) ? { regenerate(summary) } : nil,
                            onAddReminders: { tasks in pendingReminders = PendingReminders(tasks: tasks) })
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
                if recording.revisedByClaude && !showOriginal {
                    Label("Migliorata con l'AI", systemImage: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                transcriptMenu
            }

            if showOriginal && recording.revisedByClaude {
                HStack(spacing: 10) {
                    Label("Trascrizione originale, prima del miglioramento AI", systemImage: "doc.plaintext")
                        .font(.footnote)
                    Spacer(minLength: 4)
                    Button("Chiudi") { showOriginal = false }
                        .font(.footnote.weight(.semibold))
                }
                .padding(12)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

            if recording.diarized && !pendingSuggestions.isEmpty && !showOriginal {
                suggestionsBanner
            }

            if recording.diarized {
                speakerChips
            }

            if shownSegments.contains(where: { !($0.uncertain ?? []).isEmpty }) {
                Label("Le parole evidenziate sono quelle su cui il riconoscimento era incerto.", systemImage: "questionmark.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            transcriptList
        }
    }

    /// Elenco delle frasi. È "pigro": costruisce solo le righe visibili, e ogni riga
    /// si ridisegna solo se cambia (così 2.000 frasi scorrono come 20).
    private var transcriptList: some View {
        let segments = shownSegments
        let order = recording.speakerOrder
        let names = recording.speakerNames
        let diarized = recording.diarized
        let speakers = diarized ? order.map { SpeakerChoice(id: $0, name: Recording.displayName($0, names: names, order: order)) } : []
        let current = currentSegmentID
        return LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { item in
                let index = item.offset
                let segment = item.element
                let newTurn = diarized && segment.speaker != nil
                    && (index == 0 || segments[index - 1].speaker != segment.speaker)
                SegmentRow(
                    index: index,
                    segment: segment,
                    isCurrent: segment.id == current,
                    header: newTurn ? segment.speaker.map {
                        SegmentRow.Header(id: $0, name: Recording.displayName($0, names: names, order: order),
                                          color: SpeakerColors.color(for: $0, in: order))
                    } : nil,
                    speakers: speakers,
                    onTap: { player.seek(to: segment.start) },
                    onEditSpeaker: { editingSpeaker = SpeakerEditTarget(speakerId: $0, segmentId: segment.id) },
                    onReassign: { reassign(segment.id, to: $0) }
                )
                .equatable()
                .id(segment.id)
            }
        }
        .padding(8)
        .card(cornerRadius: 20)
    }

    /// Parlanti senza nome per cui l'AI ha una proposta.
    private var pendingSuggestions: [String] {
        let suggestions = recording.speakerSuggestions
        return recording.speakerOrder.filter { suggestions[$0] != nil && (recording.speakerNames[$0] ?? "").isEmpty }
    }

    private var suggestionsBanner: some View {
        let suggestions = recording.speakerSuggestions
        let ordered = pendingSuggestions
        return VStack(alignment: .leading, spacing: 10) {
            Label("L'AI propone chi parla", systemImage: "person.crop.circle.badge.questionmark")
                .font(.subheadline.weight(.semibold))
            ForEach(ordered, id: \.self) { id in
                HStack(spacing: 6) {
                    Circle()
                        .fill(SpeakerColors.color(for: id, in: recording.speakerOrder))
                        .frame(width: 8, height: 8)
                    Text(recording.speakerName(id))
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(suggestions[id] ?? "").fontWeight(.semibold)
                }
                .font(.footnote)
            }
            HStack {
                Button("Applica") { applySuggestions() }
                    .buttonStyle(.borderedProminent)
                Button("Ignora") {
                    recording.speakerSuggestions = [:]
                    try? context.save()
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 20)
    }

    private func applySuggestions() {
        var names = recording.speakerNames
        for (id, name) in recording.speakerSuggestions where (names[id] ?? "").isEmpty {
            names[id] = name
        }
        recording.speakerNames = names
        recording.speakerSuggestions = [:]
        recording.speakerNamesUpdatedAt = .now
        recording.transcript = recording.plainTranscript
        try? context.save()
    }

    private var speakerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let counts = Dictionary(recording.segments.compactMap(\.speaker).map { ($0, 1) }, uniquingKeysWith: +)
                ForEach(recording.speakerOrder, id: \.self) { speaker in
                    let count = counts[speaker] ?? 0
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
            if recording.revisedByClaude {
                Button {
                    showOriginal.toggle()
                } label: {
                    Label(showOriginal ? "Mostra la versione migliorata" : "Mostra l'originale", systemImage: "doc.plaintext")
                }
            }
            if claudeReady && !recording.revisedByClaude {
                Button {
                    pipeline.improve(recording, in: context)
                } label: {
                    Label("Migliora con l'AI", systemImage: "wand.and.stars")
                }
            }
            if !recording.diarized {
                Button {
                    pipeline.separateSpeakers(recording, in: context)
                } label: {
                    Label("Riconosci chi parla", systemImage: "person.2.wave.2")
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
            .accessibilityIdentifier("notes-field")
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
            Section("Tutto: elaborazioni, note e trascrizione") {
                Button("Markdown (Notion, Obsidian, Note)") { share(ExportService.markdown(recording)) }
            }
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

    /// Rifà tutto da capo (trascrizione, parlanti, miglioramento); le elaborazioni restano.
    private func transcribe() {
        errorText = nil
        showOriginal = false
        pipeline.process(recording, in: context, retranscribe: true)
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

    /// Scelte del menu "Motore": senza chiave API l'AI avanzata non compare.
    private var availableChoices: [EngineChoice] {
        claudeReady ? EngineChoice.allCases : [.automatic, .device]
    }

    /// Motore da usare per un modello, in base alla scelta del menu.
    private func engineToUse(for template: SummaryTemplate) -> SummaryEngine {
        switch engineChoice {
        case .cloud where claudeReady: return .cloud
        case .device: return .device
        default:
            if template.engine == .cloud && !claudeReady { return .device }
            if template.engine == .device && SummaryService.availabilityMessage != nil && claudeReady { return .cloud }
            return template.engine
        }
    }

    private func run(_ template: SummaryTemplate, on engine: SummaryEngine) {
        switch engine {
        case .cloud: summarizeWithClaude(template)
        case .device: summarize(with: template)
        }
    }

    private func summarize(with template: SummaryTemplate, replacing old: Summary? = nil) {
        guard let transcript = recording.transcript, !isSummarizing else { return }
        let userContext = recording.userContext
        isSummarizing = true
        errorText = nil
        progressText = "Avvio…"
        Task {
            do {
                let text = try await SummaryService.summarize(transcript: transcript, template: template,
                                                              userContext: userContext) { message in
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

    private func summarizeWithClaude(_ template: SummaryTemplate, replacing old: Summary? = nil) {
        guard recording.transcript != nil, !isSummarizing else { return }
        isSummarizing = true
        errorText = nil
        progressText = "L'AI sta scrivendo l'elaborazione…"
        let title = recording.title
        let transcript = recording.compactTranscript
        let userContext = recording.userContext
        Task {
            do {
                let reply = try await ClaudeService.summarize(title: title, transcript: transcript, template: template,
                                                              userContext: userContext)
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

    private func addReminders(_ tasks: [String]) {
        let title = recording.title
        Task {
            do {
                let added = try await RemindersService.add(tasks, from: title)
                flash(added == 1 ? "1 promemoria aggiunto" : "\(added) promemoria aggiunti")
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func flash(_ text: String) {
        withAnimation { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { notice = nil }
        }
    }

    private func sendToClaude(with template: SummaryTemplate) {
        guard let transcript = recording.transcript else { return }
        let prompt = template.claudePrompt(title: recording.title, transcript: transcript, userContext: recording.userContext)
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

struct SpeakerChoice: Equatable {
    let id: String
    let name: String
}

/// Una frase della trascrizione. Equatable: SwiftUI la ridisegna solo se cambia qualcosa.
struct SegmentRow: View, Equatable {
    struct Header: Equatable {
        let id: String
        let name: String
        let color: Color
    }

    let index: Int
    let segment: TranscriptSegment
    let isCurrent: Bool
    let header: Header?
    let speakers: [SpeakerChoice]
    let onTap: () -> Void
    let onEditSpeaker: (String) -> Void
    let onReassign: (String) -> Void

    nonisolated static func == (a: SegmentRow, b: SegmentRow) -> Bool {
        a.index == b.index && a.segment == b.segment && a.isCurrent == b.isCurrent
            && a.header == b.header && a.speakers == b.speakers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Button {
                    onEditSpeaker(header.id)
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(header.color).frame(width: 8, height: 8)
                        Text(header.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(header.color)
                        Image(systemName: "pencil").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, index == 0 ? 4 : 12)
                    .padding(.bottom, 2)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Rinomina chi parla")
            }
            Button(action: onTap) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(formatTime(segment.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isCurrent ? Theme.accentText : .secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(Self.highlighted(segment))
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(isCurrent ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("segment-\(index)")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .contextMenu {
                if !speakers.isEmpty {
                    Menu("Attribuisci a…") {
                        ForEach(speakers, id: \.id) { speaker in
                            Button(speaker.name) { onReassign(speaker.id) }
                        }
                        Button("Nuova persona") {
                            onReassign("manual-\(UUID().uuidString.prefix(8))")
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

    /// Testo della frase con le parole incerte evidenziate.
    static func highlighted(_ segment: TranscriptSegment) -> AttributedString {
        var text = AttributedString(segment.text)
        guard let doubts = segment.uncertain, !doubts.isEmpty else { return text }
        for word in Set(doubts) {
            var searchStart = text.startIndex
            while let range = text[searchStart...].range(of: word) {
                text[range].backgroundColor = Theme.highlight.opacity(0.22)
                searchStart = range.upperBound
            }
        }
        return text
    }
}

/// Segue la riproduzione e aggiorna la frase corrente solo quando cambia
/// (non a ogni scatto del riproduttore). Ricerca binaria: costo trascurabile anche con ore di audio.
struct PlaybackFollower: View {
    @ObservedObject var player: AudioPlayer
    let segments: [TranscriptSegment]
    @Binding var current: UUID?

    var body: some View {
        let id = Self.segmentID(at: player.currentTime, in: segments)
        Color.clear
            .onChange(of: id, initial: true) { _, new in
                if current != new { current = new }
            }
    }

    /// Ultima frase iniziata entro `time` (+0,2 s). Le frasi sono in ordine di inizio.
    nonisolated static func segmentID(at time: Double, in segments: [TranscriptSegment]) -> UUID? {
        guard time > 0, !segments.isEmpty else { return nil }
        let target = time + 0.2
        var low = 0, high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].start <= target { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? segments[low - 1].id : nil
    }
}

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
    var onAddReminders: (([String]) -> Void)? = nil
    /// Solo per la Mappa dei concetti: mostra il testo invece del disegno.
    @State private var showAsText = false

    var body: some View {
        let tile = Theme.tile(for: summary.templateID)
        let tasks = RemindersService.tasks(in: summary.text)
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
                    if summary.templateID == "mappa" {
                        Button { showAsText.toggle() } label: {
                            Label(showAsText ? "Mostra la mappa" : "Mostra come testo",
                                  systemImage: showAsText ? "point.3.connected.trianglepath.dotted" : "list.bullet")
                        }
                    }
                    Button {
                        if let url = ExportService.pdf(title: "\(recordingTitle) – \(summary.templateName)", body: summary.text) { onShare([url]) }
                    } label: { Label("PDF", systemImage: "doc.richtext") }
                    Button {
                        if let url = ExportService.rtf(title: "\(recordingTitle) – \(summary.templateName)", body: summary.text) { onShare([url]) }
                    } label: { Label("Word / Pages (RTF)", systemImage: "doc.text") }
                    if let onAddReminders, !tasks.isEmpty {
                        Divider()
                        Button { onAddReminders(tasks) } label: {
                            Label("Aggiungi a Promemoria (\(tasks.count))", systemImage: "checklist")
                        }
                    }
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
            if summary.templateID == "mappa", !showAsText, let map = ConceptMap.parse(summary.text) {
                ConceptMapCard(map: map, title: recordingTitle, onShare: onShare)
            } else {
                MarkdownText(text: summary.text)
            }
        }
        .padding(18)
        .card(cornerRadius: 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary-card")
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
                Button { player.nextRate() } label: {
                    Text(AudioPlayer.label(for: player.rate))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(player.rate == 1 ? Color.secondary : Theme.accentText)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Velocità di riproduzione")
                .accessibilityValue(AudioPlayer.label(for: player.rate))
                .accessibilityIdentifier("playback-rate")
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Scelta del motore nel menu "Nuova elaborazione".
enum EngineChoice: String, CaseIterable, Identifiable {
    case automatic, cloud, device
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatico"
        case .cloud: return SummaryEngine.cloud.label
        case .device: return SummaryEngine.device.label
        }
    }
}

/// Cose da fare in attesa di conferma prima di finire in Promemoria.
struct PendingReminders: Identifiable {
    let id = UUID()
    let tasks: [String]
}
