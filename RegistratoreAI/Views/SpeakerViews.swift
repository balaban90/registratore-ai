import SwiftUI
import SwiftData
import AVFoundation

enum SpeakerColors {
    static let palette: [Color] = [
        Color(red: 0.85, green: 0.23, blue: 0.28),
        Color(red: 0.04, green: 0.45, blue: 0.85),
        Color(red: 0.08, green: 0.52, blue: 0.29),
        Color(red: 0.55, green: 0.25, blue: 0.80),
        Color(red: 0.80, green: 0.45, blue: 0.0),
        Color(red: 0.0, green: 0.55, blue: 0.60),
        Color(red: 0.75, green: 0.20, blue: 0.55),
        Color(red: 0.40, green: 0.40, blue: 0.45)
    ]

    static func color(for id: String?, in order: [String]) -> Color {
        guard let id, let index = order.firstIndex(of: id) else { return .secondary }
        return palette[index % palette.count]
    }
}

/// Rinomina un parlante, solo un intervento o tutta la registrazione,
/// e facoltativamente salva la sua voce per riconoscerla in futuro.
struct SpeakerEditSheet: View {
    @Bindable var recording: Recording
    let speakerId: String
    /// Frase da cui è partita la modifica (per "solo questo intervento").
    let segmentId: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var profiles: [VoiceProfile]

    enum Scope: String, CaseIterable, Identifiable {
        case all = "Tutta la registrazione"
        case turn = "Solo questo intervento"
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var scope: Scope = .all
    @State private var rememberVoice = false
    @State private var isMe = false
    @State private var working = false
    @State private var errorText: String?

    private var otherSpeakers: [String] {
        recording.speakerOrder.filter { $0 != speakerId }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") {
                    TextField("Es. Marco, Dott.ssa Ferri, Io", text: $name)
                        .textInputAutocapitalization(.words)
                    if !recording.speakerNames.isEmpty || !profiles.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(suggestions, id: \.self) { s in
                                    Button(s) { name = s }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                if segmentId != nil {
                    Section {
                        Picker("Applica a", selection: $scope) {
                            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Applica a")
                    } footer: {
                        Text("\"Solo questo intervento\" serve quando il riconoscimento ha attribuito alcune frasi alla persona sbagliata.")
                    }
                }

                Section {
                    Toggle("Riconosci questa voce nelle prossime registrazioni", isOn: $rememberVoice)
                    if rememberVoice {
                        Toggle("È la mia voce", isOn: $isMe)
                    }
                } footer: {
                    Text("L'impronta della voce resta solo su questo iPhone. Funziona meglio se la persona ha parlato almeno 10–20 secondi in questa registrazione.")
                }

                if !otherSpeakers.isEmpty {
                    Section {
                        Menu {
                            ForEach(otherSpeakers, id: \.self) { other in
                                Button(recording.speakerName(other)) { merge(into: other) }
                            }
                        } label: {
                            Label("Unisci a un'altra persona…", systemImage: "arrow.triangle.merge")
                        }
                    } footer: {
                        Text("Se il riconoscimento ha diviso la stessa persona in due, uniscile.")
                    }
                }

                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle(recording.speakerName(speakerId))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Salva") { save() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                name = recording.speakerNames[speakerId] ?? ""
            }
        }
        .tint(Theme.accent)
    }

    private var suggestions: [String] {
        var all = Array(Set(recording.speakerNames.values).union(profiles.map(\.name)))
        all.removeAll { $0.isEmpty }
        return all.sorted()
    }

    private func touch() {
        recording.speakerNamesUpdatedAt = .now
        recording.transcript = recording.plainTranscript
        try? context.save()
    }

    private func merge(into other: String) {
        recording.segments = recording.segments.map { seg in
            var s = seg
            if s.speaker == speakerId { s.speaker = other }
            return s
        }
        touch()
        dismiss()
    }

    private func save() {
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var targetId = speakerId

        if scope == .turn, let segmentId {
            // Le frasi consecutive dello stesso parlante, a partire da quella scelta.
            var segments = recording.segments
            if let startIndex = segments.firstIndex(where: { $0.id == segmentId }) {
                // Se esiste già un parlante con quel nome, usa lui.
                let existing = recording.speakerOrder.first { recording.speakerName($0) == newName }
                targetId = existing ?? "manual-\(UUID().uuidString.prefix(8))"
                var i = startIndex
                while i < segments.count, segments[i].speaker == speakerId {
                    segments[i].speaker = targetId
                    i += 1
                }
                var j = startIndex - 1
                while j >= 0, segments[j].speaker == speakerId {
                    segments[j].speaker = targetId
                    j -= 1
                }
                recording.segments = segments
            }
        }

        var names = recording.speakerNames
        names[targetId] = newName
        recording.speakerNames = names
        touch()

        guard rememberVoice else {
            dismiss()
            return
        }

        working = true
        errorText = nil
        let ranges = recording.segments.filter { $0.speaker == targetId }.map { ($0.start, $0.end) }
        let url = recording.audioURL
        let me = isMe
        Task {
            do {
                let embedding = try await DiarizationService.embedding(url: url, ranges: ranges)
                if me {
                    for p in profiles where p.isMe { p.isMe = false }
                }
                context.insert(VoiceProfile(name: newName, isMe: me, embedding: embedding))
                try? context.save()
                working = false
                dismiss()
            } catch {
                working = false
                errorText = "Nome salvato, ma non sono riuscito a salvare la voce: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Profili vocali (Impostazioni)

struct VoiceProfilesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \VoiceProfile.createdAt) private var profiles: [VoiceProfile]
    @AppStorage(DiarizationService.enabledKey) private var diarizationEnabled = true
    @State private var enrolling: Bool?

    var body: some View {
        List {
            Section {
                Toggle("Separa i parlanti in automatico", isOn: $diarizationEnabled)
            } footer: {
                Text("Dopo ogni trascrizione l'app distingue le voci (Persona 1, Persona 2…). Avviene sul telefono: l'audio non esce dall'iPhone. La prima volta scarica i modelli necessari.")
            }

            Section {
                ForEach(profiles) { profile in
                    HStack {
                        Image(systemName: profile.isMe ? "person.crop.circle.fill" : "person.crop.circle")
                            .foregroundStyle(profile.isMe ? Theme.accent : .secondary)
                            .font(.title3)
                        Text(profile.name)
                        Spacer()
                        if profile.isMe {
                            Text("Io").font(.caption.weight(.semibold)).foregroundStyle(Theme.accentText)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(profiles[i]) }
                    try? context.save()
                }
                if !profiles.contains(where: \.isMe) {
                    Button {
                        enrolling = true
                    } label: {
                        Label("Crea il mio profilo vocale", systemImage: "person.wave.2")
                    }
                }
                Button {
                    enrolling = false
                } label: {
                    Label("Aggiungi un'altra persona", systemImage: "person.badge.plus")
                }
            } header: {
                Text("Voci riconosciute")
            } footer: {
                Text("Le persone salvate vengono riconosciute e chiamate per nome nelle nuove registrazioni. Puoi salvare una voce anche da una registrazione: tocca il nome del parlante e attiva \"Riconosci questa voce\".")
            }
        }
        .navigationTitle("Voci")
        .sheet(item: Binding(get: { enrolling.map(EnrollMode.init) }, set: { enrolling = $0?.isMe })) { mode in
            VoiceEnrollView(isMe: mode.isMe)
        }
    }

    struct EnrollMode: Identifiable {
        let isMe: Bool
        var id: Bool { isMe }
    }
}

/// Registra 30 secondi di voce e salva l'impronta vocale.
struct VoiceEnrollView: View {
    let isMe: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var profiles: [VoiceProfile]
    @State private var name = ""
    @State private var recorder: AVAudioRecorder?
    @State private var seconds = 0
    @State private var timer: Timer?
    @State private var recordedURL: URL?
    @State private var working = false
    @State private var errorText: String?

    private let sampleText = """
    Leggi ad alta voce, con calma e con il tuo tono normale:

    "Oggi è una giornata come tante. Ho controllato la posta, ho preso qualche appunto e ho preparato le cose da fare per domani. Mi piace avere le idee chiare prima di iniziare, così posso concentrarmi su quello che conta davvero. Ora sto registrando la mia voce, così l'app potrà riconoscermi nelle prossime registrazioni."
    """

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") {
                    TextField(isMe ? "Il tuo nome" : "Nome della persona", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section {
                    Text(sampleText).font(.callout)
                } header: {
                    Text(isMe ? "La tua voce" : "La sua voce")
                } footer: {
                    Text("Bastano circa 30 secondi in un ambiente silenzioso. L'impronta resta solo su questo iPhone.")
                }
                Section {
                    HStack {
                        Text(formatTime(Double(seconds))).monospacedDigit().font(.title2)
                        Spacer()
                        if recorder != nil {
                            Button("Ferma") { stop() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(recordedURL == nil ? "Registra" : "Registra di nuovo") { start() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    if recordedURL != nil && seconds < 15 {
                        Text("Un po' corta: meglio almeno 20 secondi.").font(.footnote).foregroundStyle(.orange)
                    }
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle(isMe ? "Il mio profilo vocale" : "Nuova persona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Salva") { save() }
                            .disabled(recordedURL == nil || recorder != nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .tint(Theme.accent)
    }

    private func start() {
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                errorText = "Consenti l'accesso al microfono in Impostazioni."
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try session.setActive(true)
                let url = FileManager.default.temporaryDirectory.appending(path: "profilo-voce.m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 96_000
                ]
                let rec = try AVAudioRecorder(url: url, settings: settings)
                rec.record()
                recorder = rec
                recordedURL = nil
                seconds = 0
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        seconds += 1
                        if seconds >= 45 { stop() }
                    }
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        guard let recorder else { return }
        recorder.stop()
        recordedURL = recorder.url
        self.recorder = nil
    }

    private func save() {
        guard let url = recordedURL else { return }
        working = true
        errorText = nil
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let embedding = try await DiarizationService.embedding(url: url)
                if isMe {
                    for p in profiles where p.isMe { p.isMe = false }
                }
                context.insert(VoiceProfile(name: n, isMe: isMe, embedding: embedding))
                try? context.save()
                working = false
                dismiss()
            } catch {
                working = false
                errorText = error.localizedDescription
            }
        }
    }
}
