import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Scheda "Registra": schermata di apertura con il tasto grande.
/// Toccando il tasto la schermata si trasforma, con un unico passaggio fluido,
/// nella schermata di registrazione (sfondo scuro, timer, forma d'onda, comandi).
struct RecordView: View {
    /// Messo a true dal widget o dal Centro di Controllo: la registrazione parte subito.
    @Binding var autoStart: Bool
    /// Chiamato dopo il salvataggio: l'app passa all'elenco delle registrazioni.
    var onSaved: () -> Void

    @Environment(\.modelContext) private var context
    @StateObject private var recorder = AudioRecorder()
    @Namespace private var morph
    @State private var confirmDiscard = false
    @State private var showSettings = false
    @State private var showImporter = false
    @State private var importError: String?

    private var active: Bool { recorder.isRecording }

    private static let darkBackground = Color(red: 0.055, green: 0.055, blue: 0.067)

    private var stateLabel: String {
        recorder.isPaused ? "In pausa" : "Registrazione"
    }

    var body: some View {
        ZStack {
            (active ? Self.darkBackground : Color(.systemGroupedBackground))
                .ignoresSafeArea()

            Ellipse()
                .fill(RadialGradient(colors: [Theme.coral.opacity(0.24), Theme.magenta.opacity(0.08), .clear],
                                     center: .center, startRadius: 10, endRadius: 240))
                .frame(width: 520, height: 380)
                .offset(y: -20)
                .opacity(active ? 1 : 0)
                .allowsHitTesting(false)

            if active {
                recordingLayer
                    .transition(.opacity.combined(with: .offset(y: 24)))
            } else {
                idleLayer
                    .transition(.opacity.combined(with: .offset(y: -24)))
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.86), value: active)
        .preferredColorScheme(active ? .dark : nil)
        .toolbarVisibility(active ? .hidden : .visible, for: .tabBar)
        .confirmationDialog("Vuoi scartare questa registrazione?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Scarta", role: .destructive) { recorder.discard() }
            Button("Continua a registrare", role: .cancel) {}
        }
        .alert("Microfono non autorizzato", isPresented: $recorder.permissionDenied) {
            Button("Apri Impostazioni") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Consenti l'accesso al microfono in Impostazioni per registrare.")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            Task {
                do {
                    try await RecordingActions.importAudio(result, in: context)
                    onSaved()
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        .alert("Importazione non riuscita", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .onAppear {
            recorder.refreshInputs()
            startIfRequested()
        }
        .onChange(of: autoStart) { _, _ in startIfRequested() }
    }

    // MARK: - Apertura

    private var idleLayer: some View {
        VStack(spacing: 0) {
            HStack {
                circleButton("gearshape", label: "Impostazioni") { showSettings = true }
                Spacer()
                circleButton("square.and.arrow.down", label: "Importa audio") { showImporter = true }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            microphoneSelector(dark: false)
                .padding(.top, 28)

            Spacer()

            recordButton(size: 148, iconSize: 52)
                .accessibilityLabel("Avvia registrazione")

            VStack(spacing: 6) {
                Text("Tocca per registrare")
                    .font(.title3.weight(.semibold))
                Text("Appoggia il telefono vicino a chi parla")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 34)

            Spacer()
            Spacer()
        }
    }

    private func circleButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }

    // MARK: - Registrazione

    private var recordingLayer: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Chiudi") { confirmDiscard = true }
                    .font(.body)
                    .foregroundStyle(Color(red: 1, green: 0.71, blue: 0.68))
                    .frame(minWidth: 60, minHeight: 44, alignment: .leading)

                Spacer()

                HStack(spacing: 7) {
                    Circle()
                        .fill(recorder.isPaused ? Color.gray : Color.red)
                        .frame(width: 9, height: 9)
                    Text(stateLabel).font(.subheadline.weight(.semibold))
                }

                Spacer()
                Color.clear.frame(width: 60, height: 44)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            VStack(spacing: 8) {
                microphoneSelector(dark: true)
                Text(recorder.isUsingExternalInput ? "Microfono esterno collegato" : "Microfono dell'iPhone")
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.65))
            }
            .padding(.top, 22)

            Spacer()

            Text(formatTime(recorder.elapsed))
                .font(.system(size: 76, weight: .light))
                .monospacedDigit()
                .contentTransition(.numericText())

            Waveform(levels: recorder.levels, paused: recorder.isPaused)
                .frame(height: 120)
                .padding(.horizontal, 30)
                .padding(.top, 30)
                .accessibilityHidden(true)

            Group {
                if !recorder.highlights.isEmpty {
                    Label("\(recorder.highlights.count) \(recorder.highlights.count == 1 ? "momento segnato" : "momenti segnati")", systemImage: "flag.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 1, green: 0.70, blue: 0.25))
                } else if let message = recorder.statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Color(white: 0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                } else {
                    Text(" ").font(.footnote)
                }
            }
            .frame(height: 40)
            .padding(.top, 20)

            Spacer()

            HStack(alignment: .top, spacing: 40) {
                RoundControl(systemImage: recorder.isPaused ? "play.fill" : "pause.fill",
                             label: recorder.isPaused ? "Riprendi" : "Pausa",
                             tint: .white) {
                    recorder.togglePause()
                }

                VStack(spacing: 8) {
                    recordButton(size: 88, iconSize: 28)
                        .accessibilityLabel("Termina e salva")
                    Text("Termina").font(.footnote).foregroundStyle(Color(white: 0.78))
                }

                RoundControl(systemImage: "flag.fill", label: "Segna",
                             tint: Color(red: 1, green: 0.70, blue: 0.25)) {
                    recorder.addHighlight()
                }
            }
            .padding(.bottom, 40)
        }
        .foregroundStyle(.white)
    }

    // MARK: - Pezzi comuni

    /// Lo stesso tasto nelle due schermate: grazie a matchedGeometryEffect scivola e si rimpicciolisce
    /// dal centro fino in basso, mentre il microfono diventa il quadrato di "Termina".
    private func recordButton(size: CGFloat, iconSize: CGFloat) -> some View {
        Button {
            if active { finish() } else { Task { await recorder.start() } }
        } label: {
            ZStack {
                Circle().fill(Theme.recordGradient)
                if active {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white)
                        .frame(width: 28, height: 28)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .matchedGeometryEffect(id: "tastoRegistra", in: morph)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .stroke(Theme.coral.opacity(active ? 0.18 : 0.12), lineWidth: active ? 6 : 12)
                    .padding(active ? -6 : -12)
            }
            .shadow(color: Theme.magenta.opacity(0.4), radius: active ? 15 : 18, y: 8)
        }
        .buttonStyle(.plain)
    }

    private func microphoneSelector(dark: Bool) -> some View {
        Menu {
            Section("Microfono") {
                ForEach(recorder.inputs) { input in
                    Button {
                        recorder.selectInput(id: input.id)
                    } label: {
                        if input.id == recorder.currentInputID {
                            Label(input.name, systemImage: "checkmark")
                        } else {
                            Text(input.name)
                        }
                    }
                }
            }
            Toggle("Passa da solo al microfono esterno", isOn: $recorder.autoSwitchToExternal)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                Text(recorder.currentInputName).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .frame(height: 40)
            .foregroundStyle(dark ? Color.white : Color.primary)
            .background {
                if dark {
                    Capsule().fill(Color.white.opacity(0.1))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                }
            }
            .glassEffect(dark ? .identity : .regular, in: Capsule())
        }
    }

    // MARK: - Azioni

    private func startIfRequested() {
        guard autoStart else { return }
        autoStart = false
        if !recorder.isRecording {
            Task { await recorder.start() }
        }
    }

    private func finish() {
        if let finished = recorder.stop() {
            RecordingActions.save(finished, in: context)
            onSaved()
        }
    }
}

struct RoundControl: View {
    let systemImage: String
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 68, height: 68)
                    .background(Color.white.opacity(0.1), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            }
            .accessibilityLabel(label)
            Text(label).font(.footnote).foregroundStyle(Color(white: 0.78))
        }
        .padding(.top, 10)
    }
}

/// Forma d'onda: le barre più recenti a destra.
struct Waveform: View {
    let levels: [Float]
    let paused: Bool

    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 4
            let barWidth = max(2, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { item in
                    let value = CGFloat(item.element)
                    Capsule()
                        .fill(paused ? Color.white.opacity(0.25) : (value > 0.75 ? Theme.coral : Color(red: 1, green: 0.54, blue: 0.43)))
                        .frame(width: barWidth, height: max(6, value * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.linear(duration: 0.1), value: levels)
        }
    }
}
