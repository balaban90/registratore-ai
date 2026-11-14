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

        }
        .navigationTitle("Glossario")
        .sheet(isPresented: $showNew) {
            GlossaryEditor(entry: nil)
        }
        .sheet(item: $editing) { entry in
            GlossaryEditor(entry: entry)
        }
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
                    TextField("Es. un nome, una sigla, un termine tecnico", text: $right)
                        .autocorrectionDisabled()
                } header: {
                    Text("Scritto correttamente")
                }
                Section {
                    TextField("Facoltativo: come esce sbagliato", text: $wrong)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Come lo sbaglia la trascrizione")
                } footer: {
                    Text("Copialo da una trascrizione in cui è uscito sbagliato. Lascialo vuoto se vuoi solo che Claude conosca il termine (nomi di persone, luoghi, sigle, termini tecnici).")
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
