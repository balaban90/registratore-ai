import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ClaudeService.summaryModelKey) private var summaryModelRaw = ClaudeModel.sonnet.rawValue
    @AppStorage(ClaudeService.chatModelKey) private var chatModelRaw = ClaudeModel.haiku.rawValue
    @AppStorage(TranscriptionLanguage.defaultsKey) private var languageRaw = TranscriptionLanguage.italian.rawValue

    @State private var keyInput = ""
    @State private var hasKey = ClaudeService.isConfigured
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Lingua parlata", selection: $languageRaw) {
                        ForEach(TranscriptionLanguage.allCases) { language in
                            Text(language.label).tag(language.rawValue)
                        }
                    }
                } header: {
                    Text("Trascrizione")
                } footer: {
                    Text("La lingua in cui si parla nelle registrazioni. Le elaborazioni sono sempre in italiano. Per ritrascrivere una registrazione già fatta: menu ⋯ > Rifai la trascrizione.")
                }

                Section {
                    if hasKey {
                        Label("Chiave API salvata", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Button("Verifica la chiave") { testSaved() }
                            .disabled(testing)
                        Button("Rimuovi la chiave", role: .destructive) {
                            Keychain.delete(ClaudeService.keychainKey)
                            hasKey = false
                            testResult = nil
                        }
                    } else {
                        SecureField("sk-ant-…", text: $keyInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Salva e verifica") { saveAndTest() }
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
                    Text("AI avanzata (online)")
                } footer: {
                    Text("Incolla la chiave API del tuo account del servizio AI (Settings > API keys). Resta salvata solo in questo iPhone, nel Portachiavi. All'AI viene inviato solo il testo della trascrizione, mai l'audio.")
                }

                Section {
                    Picker("Per le elaborazioni", selection: $summaryModelRaw) {
                        ForEach(ClaudeModel.allCases) { model in
                            Text(model.label).tag(model.rawValue)
                        }
                    }
                    Picker("Per le domande", selection: $chatModelRaw) {
                        ForEach(ClaudeModel.allCases) { model in
                            Text(model.label).tag(model.rawValue)
                        }
                    }
                } header: {
                    Text("Qualità dell'AI avanzata")
                } footer: {
                    Text("Consigliato: Equilibrato per le elaborazioni, Economico per le domande (costa circa venti volte meno). Per risparmiare, la trascrizione resta in memoria per 5 minuti: elaborazioni e domande fatte di seguito sulla stessa registrazione costano molto meno.")
                }

                Section {
                    LabeledContent("Spesa stimata", value: formatUSD(UsageTracker.monthTotal))
                    LabeledContent("Richieste", value: "\(UsageTracker.monthRequests)")
                } header: {
                    Text("Questo mese")
                } footer: {
                    Text("Stima calcolata dall'app. Il saldo esatto è nel tuo account del servizio AI, nelle sezioni Usage e Billing.")
                }

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
                }

                Section("Informazioni") {
                    LabeledContent("Versione", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    if let message = SummaryService.availabilityMessage {
                        Text("AI sul telefono: \(message)").font(.footnote)
                    } else {
                        Label("AI sul telefono disponibile", systemImage: "iphone")
                            .font(.footnote)
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
                testResult = "Funziona: l'AI avanzata è collegata."
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
                testResult = "Funziona: l'AI avanzata è collegata."
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
                } else if let startingFrom {
                    name = "\(startingFrom.name) (mio)"
                    icon = startingFrom.icon
                    instructions = startingFrom.instructions
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
        } else {
            context.insert(CustomTemplate(name: n, icon: icon, instructions: i))
        }
        try? context.save()
        dismiss()
    }
}
