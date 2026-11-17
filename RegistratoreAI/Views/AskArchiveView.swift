import SwiftUI
import SwiftData

/// "Chiedi all'archivio": domande su tutte le registrazioni, con le fonti
/// che portano al punto esatto dell'audio.
struct AskArchiveView: View {
    let recordings: [Recording]

    @Environment(\.dismiss) private var dismiss
    @State private var exchanges: [Exchange] = []
    @State private var input = ""
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var sessionCost: Double = 0

    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        let answer: String
        let sources: [ArchiveAsk.Source]
        let citations: [ArchiveAsk.Citation]
    }

    private let suggestions = [
        "Quali impegni ho preso nelle ultime registrazioni?",
        "Cosa si è deciso sull'argomento più discusso?",
        "Riassumi le registrazioni di questa settimana",
        "Chi ha parlato di scadenze e cosa ha detto?"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if exchanges.isEmpty {
                                Text("Fai una domanda su tutte le tue registrazioni. L'AI risponde indicando dove l'ha sentito: tocca una fonte per ascoltare quel punto.")
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
                            ForEach(exchanges) { exchange in
                                exchangeView(exchange).id(exchange.id)
                            }
                            if isLoading {
                                HStack { ProgressView(); Text("L'AI cerca nell'archivio…").font(.callout) }
                            }
                            if let errorText {
                                Text(errorText).font(.callout).foregroundStyle(.red)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: exchanges.count) {
                        if let last = exchanges.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .top) }
                        }
                    }
                }

                Divider()
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Chiedi all'archivio…", text: $input, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("archive-input")
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                    .accessibilityLabel("Invia")
                }
                .padding()
            }
            .tint(Theme.accent)
            .navigationTitle("Chiedi all'archivio")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: CitationTarget.self) { target in
                if let recording = recordings.first(where: { $0.id == target.recordingID }) {
                    RecordingDetailView(recording: recording, startAt: target.time)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if sessionCost > 0 {
                        Text(formatUSD(sessionCost)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func exchangeView(_ exchange: Exchange) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(exchange.question)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accentSoft))
                .frame(maxWidth: .infinity, alignment: .trailing)
            MarkdownText(text: exchange.answer)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
            let links = targets(for: exchange)
            if !links.isEmpty {
                Text("FONTI").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(links) { link in
                            NavigationLink(value: link) {
                                HStack(spacing: 6) {
                                    Text("R\(link.number)").font(.caption.weight(.bold))
                                    Text(link.title).lineLimit(1)
                                    if let time = link.time {
                                        Text(formatTime(time)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                }
                                .font(.footnote)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack(spacing: 16) {
                Button {
                    UIPasteboard.general.string = exchange.answer
                } label: { Label("Copia", systemImage: "doc.on.doc") }
            }
            .font(.caption)
        }
    }

    /// Collegamenti da mostrare: i punti citati; se l'AI non ha citato orari, le registrazioni usate.
    private func targets(for exchange: Exchange) -> [CitationTarget] {
        let byNumber = Dictionary(exchange.sources.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        let cited = exchange.citations.compactMap { c -> CitationTarget? in
            guard let source = byNumber[c.number] else { return nil }
            return CitationTarget(number: c.number, recordingID: source.id, title: source.title, time: c.time)
        }
        return Array(cited.prefix(12))
    }

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isLoading else { return }
        input = ""
        errorText = nil
        isLoading = true
        let items = recordings.filter { $0.transcript != nil }.map(\.archiveItem)
        Task {
            do {
                guard !items.isEmpty else {
                    errorText = "Nessuna registrazione trascritta nell'archivio."
                    isLoading = false
                    return
                }
                let result = try await ArchiveAsk.ask(question: question, items: items)
                let citations = ArchiveAsk.citations(in: result.answer.text, sources: result.sources)
                exchanges.append(Exchange(question: question, answer: result.answer.text,
                                          sources: result.sources, citations: citations))
                sessionCost += result.answer.costUSD
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }
}

/// Destinazione di una fonte: registrazione e (se c'è) il punto da ascoltare.
struct CitationTarget: Hashable, Identifiable {
    let number: Int
    let recordingID: UUID
    let title: String
    let time: Double?
    var id: String { "\(recordingID)-\(time ?? -1)" }
}
