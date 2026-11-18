import SwiftUI
import SwiftData

/// Rinomina una registrazione, con proposte di nome: subito quelle semplici (data, persone, tema),
/// poi quelle scritte dall'AI leggendo il contenuto.
struct RenameSheet: View {
    @Bindable var recording: Recording
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var aiSuggestions: [String] = []
    @State private var loading = false
    @State private var aiUnavailable = false
    @FocusState private var focused: Bool

    private var basic: [String] { TitleSuggestions.basic(for: recording) }

    private var source: String {
        let sintesi = recording.summaries.first(where: { $0.templateID == "sintesi" })?.text
        return sintesi ?? recording.sortedSummaries.first?.text ?? recording.transcript ?? ""
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Nome", text: $name, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("rename-field")
                        .overlay(alignment: .trailing) {
                            if !name.isEmpty {
                                Button {
                                    name = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Cancella")
                            }
                        }
                }

                Section {
                    if loading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Leggo il contenuto…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(aiSuggestions, id: \.self) { suggestion in
                        suggestionRow(suggestion, icon: "sparkles")
                    }
                    ForEach(basic.filter { b in !aiSuggestions.contains { $0.lowercased() == b.lowercased() } }, id: \.self) { suggestion in
                        suggestionRow(suggestion, icon: "text.badge.plus")
                    }
                    if !loading && !source.isEmpty && (aiSuggestions.isEmpty ? !aiUnavailable : true) {
                        Button {
                            Task { await loadSuggestions() }
                        } label: {
                            Label(aiSuggestions.isEmpty ? "Proponi nomi dal contenuto" : "Altre proposte",
                                  systemImage: "arrow.clockwise")
                        }
                    }
                } header: {
                    Text("Suggerimenti")
                } footer: {
                    if aiUnavailable && aiSuggestions.isEmpty && !source.isEmpty {
                        Text("Le proposte dal contenuto richiedono l'AI sul dispositivo o l'AI avanzata.")
                    }
                }
            }
            .navigationTitle("Rinomina")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva", action: save)
                        .fontWeight(.semibold)
                        .disabled(trimmed.isEmpty || trimmed == recording.title)
                }
            }
            .task {
                name = recording.title
                focused = true
                if !source.isEmpty { await loadSuggestions() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func suggestionRow(_ suggestion: String, icon: String) -> some View {
        Button {
            name = suggestion
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                Text(suggestion)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if trimmed == suggestion {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold)
                }
            }
        }
        .accessibilityHint("Usa questo nome")
    }

    private func loadSuggestions() async {
        let text = source
        guard text.count > 40 else { aiUnavailable = true; return }
        loading = true
        defer { loading = false }
        var found: [String] = []
        // Prima sul dispositivo (gratis); se non c'è, l'AI avanzata con il modello più economico.
        if SummaryService.availabilityMessage == nil {
            found = (try? await SummaryService.titleSuggestions(for: text)) ?? []
        }
        if found.isEmpty && ClaudeService.isConfigured {
            do {
                found = try await ClaudeService.titleSuggestions(for: text)
            } catch {
                DiagnosticLog.warning(.ai, "Proposte di nome non riuscite: \(DiagnosticLog.describe(error))")
            }
        }
        aiUnavailable = found.isEmpty
        let fresh = found.filter { f in !aiSuggestions.contains { $0.lowercased() == f.lowercased() } }
        withAnimation { aiSuggestions = Array((fresh + aiSuggestions).prefix(6)) }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        recording.title = trimmed
        try? context.save()
        DiagnosticLog.info(.app, "Registrazione rinominata")
        dismiss()
    }
}
