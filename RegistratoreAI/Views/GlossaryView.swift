import SwiftUI
import SwiftData

struct GlossaryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \GlossaryEntry.right) private var entries: [GlossaryEntry]
    @State private var editing: GlossaryEntry?
    @State private var showNew = false

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    Button {
                        editing = entry
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.right).font(.body.weight(.medium)).foregroundStyle(.primary)
                            if entry.wrong.isEmpty {
                                Text("Solo come riferimento per Claude").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("sostituisce \"\(entry.wrong)\"").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(entries[i]) }
                    try? context.save()
                }
                Button {
                    showNew = true
                } label: {
                    Label("Aggiungi voce", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("Le sostituzioni si applicano da sole a ogni nuova trascrizione, gratis. Per quelle già fatte: menu ⋯ della trascrizione > Applica il glossario. I termini corretti vengono passati anche a Claude quando rivede una trascrizione.")
            }

            if entries.isEmpty {
                Section("Esempi") {
                    Button("Aggiungi alcuni esempi del sindacato") { addExamples() }
                }
            }
        }
        .navigationTitle("Glossario")
        .sheet(isPresented: $showNew) {
            GlossaryEditor(entry: nil)
        }
        .sheet(item: $editing) { entry in
            GlossaryEditor(entry: entry)
        }
    }

    private func addExamples() {
        let examples: [(String, String)] = [
            ("ci gi elle", "CGIL"),
            ("cigielle", "CGIL"),
            ("erre esse u", "RSU"),
            ("ci ci enne elle", "CCNL"),
            ("a esse esse ti", "ASST"),
            ("", "Carlo Poma"),
            ("", "FP CGIL")
        ]
        for (wrong, right) in examples {
            context.insert(GlossaryEntry(wrong: wrong, right: right))
        }
        try? context.save()
    }
}

struct GlossaryEditor: View {
    let entry: GlossaryEntry?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var wrong = ""
    @State private var right = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Es. CGIL, Carlo Poma, Ferri", text: $right)
                        .autocorrectionDisabled()
                } header: {
                    Text("Scritto correttamente")
                }
                Section {
                    TextField("Es. ci gi elle (facoltativo)", text: $wrong)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Come lo sbaglia la trascrizione")
                } footer: {
                    Text("Copialo da una trascrizione in cui è uscito sbagliato. Lascialo vuoto se vuoi solo che Claude conosca il termine (nomi di persone, reparti, sigle).")
                }
            }
            .navigationTitle(entry == nil ? "Nuova voce" : "Modifica voce")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") { save() }
                        .disabled(right.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let entry {
                    wrong = entry.wrong
                    right = entry.right
                }
            }
        }
    }

    private func save() {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if let entry {
            entry.wrong = w
            entry.right = r
        } else {
            context.insert(GlossaryEntry(wrong: w, right: r))
        }
        try? context.save()
        dismiss()
    }
}
