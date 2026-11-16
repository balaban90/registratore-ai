import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(ClaudeService.summaryModelKey) private var summaryModelRaw = ClaudeModel.sonnet.rawValue
    @AppStorage(ClaudeService.chatModelKey) private var chatModelRaw = ClaudeModel.haiku.rawValue
    @AppStorage(TranscriptionLanguage.defaultsKey) private var languageRaw = TranscriptionLanguage.italian.rawValue
    @AppStorage(TranscriptionEngine.defaultsKey) private var engineRaw = TranscriptionEngine.automatic.rawValue
    @AppStorage(Pipeline.autoImproveKey) private var autoImprove = true
    @AppStorage(Pipeline.autoSummaryKey) private var autoSummary = true
    @ObservedObject private var whisper = WhisperModel.shared

    @State private var keyInput = ""
    @State private var hasKey = ClaudeService.isConfigured
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false
    @State private var report: DiagnosticReport?
    @State private var logSize = DiagnosticLog.sizeDescription
    @State private var confirmClear = false
    @AppStorage(DiagnosticUploader.autoKey) private var autoUpload = true
    @ObservedObject private var uploader = DiagnosticUploader.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var githubTokenInput = ""
    @State private var hasGitHubToken = DiagnosticUploader.isConfigured
    @State private var githubMessage: String?
    @State private var problemNote = ""

    /// Opzioni tecniche nascoste: si attivano toccando 7 volte "Versione", come su iPhone.
    @AppStorage(SettingsView.developerModeKey) private var developerMode = false
    @State private var versionTaps = 0
    @State private var developerNotice: String?

    static let developerModeKey = "developerMode"

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Lingua", selection: $languageRaw) {
                        ForEach(TranscriptionLanguage.allCases) { language in
                            Text(language.label).tag(language.rawValue)
                        }
                    }
                } header: {
                    Text("Trascrizione")
                } footer: {
                    Text("Lingua parlata nelle registrazioni.")
                }

                aiKeySection

                Section {
                    NavigationLink {
                        TemplatesListView()
                    } label: {
                        Label("Modelli di elaborazione", systemImage: "list.bullet.rectangle")
                    }
                    NavigationLink {
                        GlossaryView()
                    } label: {
                        Label("Glossario", systemImage: "character.book.closed")
                    }
                    NavigationLink {
                        VoiceProfilesView()
                    } label: {
                        Label("Voci e parlanti", systemImage: "person.2.wave.2")
                    }
                } header: {
                    Text("Personalizza")
                }

                updatesSection

                Section {
                    LabeledContent("Versione", value: version)
                        .contentShape(Rectangle())
                        .onTapGesture { tappedVersion() }
                        .accessibilityIdentifier("version-row")
                        .accessibilityAddTraits(.isButton)
                    if developerMode {
                        NavigationLink {
                            developerView
                        } label: {
                            Label("Modalità sviluppatore", systemImage: "hammer")
                        }
                    }
                } header: {
                    Text("Informazioni")
                } footer: {
                    if let developerNotice {
                        Text(developerNotice)
                    }
                }
            }
            .tint(Theme.accent)
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }

    private func tappedVersion() {
        guard !developerMode else {
            developerNotice = "La modalità sviluppatore è già attiva."
            return
        }
        versionTaps += 1
        let left = 7 - versionTaps
        if left <= 0 {
            developerMode = true
            versionTaps = 0
            developerNotice = "Modalità sviluppatore attivata."
            DiagnosticLog.info(.app, "Modalità sviluppatore attivata")
        } else if left <= 3 {
            developerNotice = left == 1 ? "Ancora 1 tocco per la modalità sviluppatore." : "Ancora \(left) tocchi per la modalità sviluppatore."
        }
    }

    // MARK: - Sezioni visibili a tutti

    private var aiKeySection: some View {
        Section {
            if hasKey {
                Label("AI avanzata attiva", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button("Verifica") { testSaved() }
                    .disabled(testing)
                Button("Rimuovi chiave", role: .destructive) {
                    Keychain.delete(ClaudeService.keychainKey)
                    hasKey = false
                    testResult = nil
                }
            } else {
                SecureField("Chiave API", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Salva") { saveAndTest() }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty || testing)
            }
            if testing {
                HStack { ProgressView(); Text("Verifico…") }
            }
            if let testResult {
                Text(testResult)
                    .font(.footnote)
                    .foregroundStyle(testOK ? .green : .red)
            }
        } header: {
            Text("AI avanzata")
        } footer: {
            Text("Facoltativa: migliora trascrizioni ed elaborazioni. Viene inviato solo il testo, mai l'audio.")
        }
    }

    private var updatesSection: some View {
        Section {
            if let release = updates.available {
                Button {
                    updates.install(release)
                } label: {
                    Label("Scarica la versione \(release.version)", systemImage: "arrow.down.circle.fill")
                }
                if !release.notes.isEmpty {
                    Text(release.notes).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await updates.check(force: true) }
                } label: {
                    if updates.checking {
                        HStack { ProgressView(); Text("Controllo…") }
                    } else {
                        Label("Controlla aggiornamenti", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            if let message = updates.lastMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Aggiornamenti")
        }
    }

    // MARK: - Modalità sviluppatore

    private var developerView: some View {
        Form {
            Section {
                Picker("Elaborazioni", selection: $summaryModelRaw) {
                    ForEach(ClaudeModel.allCases) { model in
                        Text(model.label).tag(model.rawValue)
                    }
                }
                Picker("Domande", selection: $chatModelRaw) {
                    ForEach(ClaudeModel.allCases) { model in
                        Text(model.label).tag(model.rawValue)
                    }
                }
            } header: {
                Text("Modello AI")
            } footer: {
                Text("Consigliati: Bilanciato per le elaborazioni, Economico per le domande. Avanzato offre la massima qualità a un costo maggiore.")
            }

            Section {
                Picker("Motore di trascrizione", selection: $engineRaw) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.label).tag(engine.rawValue)
                    }
                }
                if let progress = whisper.downloadProgress {
                    LabeledContent("Motore Preciso", value: "Download \(Int(progress * 100))%")
                } else {
                    LabeledContent("Motore Preciso", value: WhisperModel.isReady ? "Pronto" : "Non scaricato")
                    if !WhisperModel.isReady && engineRaw != TranscriptionEngine.fast.rawValue {
                        Button("Scarica ora") { whisper.downloadIfAppropriate() }
                    }
                }
                if let error = whisper.lastError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Migliora con l'AI", isOn: $autoImprove)
                Toggle("Sintesi automatica", isOn: $autoSummary)
            } header: {
                Text("Lavorazione")
            } footer: {
                Text("Automatico usa il motore Preciso quando il suo modello è scaricato (circa 630 MB, solo con Wi-Fi), altrimenti Veloce. \"Migliora con l'AI\" corregge testo e parlanti dopo ogni trascrizione. \"Sintesi automatica\" crea l'anteprima mostrata nell'elenco.")
            }

            Section {
                LabeledContent("Spesa stimata", value: formatUSD(UsageTracker.monthTotal))
                LabeledContent("Richieste", value: "\(UsageTracker.monthRequests)")
                if let message = SummaryService.availabilityMessage {
                    LabeledContent("AI sul dispositivo", value: message)
                } else {
                    LabeledContent("AI sul dispositivo", value: "Disponibile")
                }
            } header: {
                Text("Consumo del mese")
            } footer: {
                Text("Stima calcolata dall'app. Il saldo effettivo è nel tuo account del provider AI.")
            }

            Section {
                Button {
                    if let url = DiagnosticLog.makeReport(context: context) {
                        report = DiagnosticReport(url: url)
                    }
                } label: {
                    Label("Esporta file diagnostico", systemImage: "stethoscope")
                }
                Button("Cancella registro", role: .destructive) { confirmClear = true }
                LabeledContent("Dimensione registro", value: logSize)
            } header: {
                Text("Diagnostica")
            } footer: {
                Text("File con impostazioni, stato delle registrazioni e registro delle attività. Non contiene audio, testi o la chiave API.")
            }

            Section {
                if hasGitHubToken {
                    Toggle("Invio automatico", isOn: $autoUpload)
                    TextField("Cosa è successo? (facoltativo)", text: $problemNote, axis: .vertical)
                        .lineLimit(1...4)
                    Button {
                        Task {
                            if await uploader.send(reason: "segnalazione manuale", note: problemNote) { problemNote = "" }
                        }
                    } label: {
                        if uploader.sending {
                            HStack { ProgressView(); Text("Invio…") }
                        } else {
                            Label("Invia segnalazione ora", systemImage: "paperplane")
                        }
                    }
                    .disabled(uploader.sending)
                    if let last = DiagnosticUploader.lastSent {
                        LabeledContent("Ultimo invio", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Rimuovi token", role: .destructive) {
                        Keychain.delete(DiagnosticUploader.tokenKey)
                        hasGitHubToken = false
                    }
                } else {
                    SecureField("Token GitHub", text: $githubTokenInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Salva") { saveGitHubToken() }
                        .disabled(githubTokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let message = githubMessage ?? uploader.lastResult {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Segnalazione automatica dei problemi")
            } footer: {
                Text("A ogni errore o crash il file diagnostico viene inviato a \(DiagnosticUploader.repository) per la correzione. Il token è salvato nel Portachiavi.")
            }

            Section {
                Button("Disattiva modalità sviluppatore", role: .destructive) {
                    developerMode = false
                    developerNotice = nil
                }
            } footer: {
                Text("Le impostazioni restano come sono. Per riattivarla tocca 7 volte \"Versione\".")
            }
        }
        .tint(Theme.accent)
        .sheet(item: $report) { item in
            ActivityView(items: [item.url])
        }
        .confirmationDialog("Cancellare il registro diagnostico?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Cancella", role: .destructive) {
                DiagnosticLog.clear()
                logSize = DiagnosticLog.sizeDescription
            }
        }
        .onAppear { logSize = DiagnosticLog.sizeDescription }
        .navigationTitle("Modalità sviluppatore")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func saveGitHubToken() {
        let token = githubTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        githubMessage = "Verifico…"
        Task {
            if let problem = await uploader.test(token: token) {
                githubMessage = problem
            } else {
                Keychain.set(token, for: DiagnosticUploader.tokenKey)
                githubTokenInput = ""
                hasGitHubToken = true
                githubMessage = "Token verificato. Le segnalazioni partiranno da sole."
            }
        }
    }

    private func saveAndTest() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        testing = true
        testResult = nil
        Task {
            do {
                try await ClaudeService.test(key: key)
                Keychain.set(key, for: ClaudeService.keychainKey)
                hasKey = true
                keyInput = ""
                testOK = true
                testResult = "Chiave verificata."
            } catch {
                testOK = false
                testResult = error.localizedDescription
            }
            testing = false
        }
    }

    private func testSaved() {
        guard let key = ClaudeService.apiKey else { return }
        testing = true
        testResult = nil
        Task {
            do {
                try await ClaudeService.test(key: key)
                testOK = true
                testResult = "Chiave verificata."
            } catch {
                testOK = false
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}

// MARK: - Modelli di riassunto

struct TemplatesListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CustomTemplate.createdAt) private var custom: [CustomTemplate]
    @State private var editing: CustomTemplate?
    @State private var showNew = false
    @State private var draftFrom: SummaryTemplate?

    var body: some View {
        List {
            Section {
                ForEach(custom) { template in
                    Button {
                        editing = template
                    } label: {
                        Label(template.name, systemImage: template.icon)
                            .foregroundStyle(.primary)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(custom[i]) }
                    try? context.save()
                }
                Button {
                    draftFrom = nil
                    showNew = true
                } label: {
                    Label("Nuovo modello", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("I tuoi modelli")
            } footer: {
                Text("Scrivi cosa vuoi ottenere e con quali sezioni, come se lo spiegassi a un collega.")
            }

            Section {
                ForEach(SummaryTemplate.all) { template in
                    NavigationLink {
                        BuiltInTemplateView(template: template) {
                            draftFrom = template
                            showNew = true
                        }
                    } label: {
                        Label(template.name, systemImage: template.icon)
                    }
                }
            } header: {
                Text("Predefiniti")
            } footer: {
                Text("Apri un predefinito e tocca \"Duplica\" per partire da quello.")
            }
        }
        .navigationTitle("Modelli di elaborazione")
        .sheet(isPresented: $showNew) {
            TemplateEditorView(template: nil, startingFrom: draftFrom)
        }
        .sheet(item: $editing) { template in
            TemplateEditorView(template: template, startingFrom: nil)
        }
    }
}

struct BuiltInTemplateView: View {
    let template: SummaryTemplate
    let onDuplicate: () -> Void

    var body: some View {
        ScrollView {
            Text(template.instructions)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(template.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Duplica", action: onDuplicate)
            }
        }
    }
}

struct TemplateEditorView: View {
    let template: CustomTemplate?
    let startingFrom: SummaryTemplate?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var icon = "star"
    @State private var instructions = ""
    @State private var engine: SummaryEngine = .cloud

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") {
                    TextField("Es. Riunione di condominio", text: $name)
                }
                Section("Icona") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(SummaryTemplate.icons, id: \.self) { symbol in
                            Image(systemName: symbol)
                                .font(.title3)
                                .frame(width: 40, height: 40)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(symbol == icon ? Color.accentColor.opacity(0.2) : Color.clear)
                                )
                                .onTapGesture { icon = symbol }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    TextField("Istruzioni", text: $instructions, axis: .vertical)
                        .lineLimit(8...30)
                } header: {
                    Text("Istruzioni per l'elaborazione")
                } footer: {
                    Text("Esempio: \"Riassumi una riunione di condominio. Sezioni: 1. Presenti 2. Problemi segnalati 3. Spese approvate con importi 4. Lavori decisi e tempi 5. Cose da fare\". Le regole comuni (italiano, niente invenzioni) vengono aggiunte da sole.")
                }
                Section {
                    Picker("Motore", selection: $engine) {
                        ForEach(SummaryEngine.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("AI avanzata per riunioni e documenti con impegni e scadenze. Sul dispositivo per sintesi semplici, gratis e offline.")
                }
            }
            .navigationTitle(template == nil ? "Nuovo modello" : "Modifica modello")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let template {
                    name = template.name
                    icon = template.icon
                    instructions = template.instructions
                    engine = template.engine
                } else if let startingFrom {
                    name = "\(startingFrom.name) (copia)"
                    icon = startingFrom.icon
                    instructions = startingFrom.instructions
                    engine = startingFrom.engine
                }
            }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let i = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if let template {
            template.name = n
            template.icon = icon
            template.instructions = i
            template.engine = engine
        } else {
            context.insert(CustomTemplate(name: n, icon: icon, instructions: i, engine: engine))
        }
        try? context.save()
        dismiss()
    }
}

struct DiagnosticReport: Identifiable {
    let id = UUID()
    let url: URL
}
