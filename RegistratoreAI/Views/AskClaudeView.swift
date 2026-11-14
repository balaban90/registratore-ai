import SwiftUI
import SwiftData

/// Domande libere a Claude su una registrazione.
struct AskClaudeView: View {
    let recording: Recording

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var messages: [ClaudeMessage] = []
    @State private var input = ""
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var savedNotice: String?
    @State private var sessionCost: Double = 0
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "Quali impegni sono stati presi, da chi e con che scadenza?",
        "Quali punti sono rimasti aperti?",
        "Scrivi una mail ai colleghi con gli esiti",
        "Scrivi un comunicato breve per i lavoratori",
        "Ci sono numeri, date o riferimenti normativi citati?"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if messages.isEmpty {
                                Text("Fai una domanda su \"\(recording.title)\". Claude risponde in base alla trascrizione.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                ForEach(suggestions, id: \.self) { s in
                                    Button {
                                        input = s
                                        send()
                                    } label: {
                                        Text(s)
                                            .font(.callout)
                                            .multilineTextAlignment(.leading)
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            ForEach(messages) { message in
                                bubble(message).id(message.id)
                            }
                            if isLoading {
                                HStack { ProgressView(); Text("Claude sta scrivendo…").font(.callout) }
                                    .id("loading")
                            }
                            if let errorText {
                                Text(errorText).font(.callout).foregroundStyle(.red)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) {
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .top) }
                        }
                    }
                }

                Divider()
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Chiedi a Claude…", text: $input, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .focused($inputFocused)
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }
                .padding()
            }
            .navigationTitle("Chiedi a Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if sessionCost > 0 {
                        Text(formatUSD(sessionCost))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .overlay(alignment: .top) {
                if let savedNotice {
                    Text(savedNotice)
                        .font(.footnote)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: ClaudeMessage) -> some View {
        let isUser = message.role == "user"
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            Text(message.content)
                .textSelection(.enabled)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isUser ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
                )
            if !isUser {
                HStack(spacing: 16) {
                    Button {
                        UIPasteboard.general.string = message.content
                        flash("Copiato")
                    } label: { Label("Copia", systemImage: "doc.on.doc") }
                    Button {
                        saveAsSummary(message)
                    } label: { Label("Salva nei riassunti", systemImage: "tray.and.arrow.down") }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }
        input = ""
        errorText = nil
        messages.append(ClaudeMessage(role: "user", content: text))
        isLoading = true
        let title = recording.title
        let transcript = recording.compactTranscript
        let notes = recording.notes
        let history = messages
        Task {
            do {
                let reply = try await ClaudeService.ask(title: title, transcript: transcript, notes: notes, history: history)
                messages.append(ClaudeMessage(role: "assistant", content: reply.text))
                sessionCost += reply.costUSD
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func saveAsSummary(_ message: ClaudeMessage) {
        let index = messages.firstIndex(of: message) ?? messages.count
        let question = messages[..<index].last(where: { $0.role == "user" })?.content ?? "Domanda"
        let summary = Summary(templateID: "domanda", templateName: "Claude: \(question.prefix(60))", text: message.content)
        summary.recording = recording
        context.insert(summary)
        try? context.save()
        flash("Salvato nei riassunti")
    }

    private func flash(_ text: String) {
        withAnimation { savedNotice = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { savedNotice = nil }
        }
    }
}
