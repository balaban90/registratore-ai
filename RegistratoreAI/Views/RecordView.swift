import SwiftUI

struct RecordView: View {
    /// true se aperta dal widget o dal Centro di Controllo: la registrazione parte subito.
    var autoStart = false
    let onFinish: (FinishedRecording) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = AudioRecorder()
    @State private var confirmDiscard = false

    private var stateLabel: String {
        if !recorder.isRecording { return "Pronto" }
        return recorder.isPaused ? "In pausa" : "Registrazione"
    }

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.067).ignoresSafeArea()
            Ellipse()
                .fill(RadialGradient(colors: [Theme.coral.opacity(0.24), Theme.magenta.opacity(0.08), .clear],
                                     center: .center, startRadius: 10, endRadius: 240))
                .frame(width: 520, height: 380)
                .offset(y: -20)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                microphoneSelector
                    .padding(.top, 22)

                Spacer()

                Text(formatTime(recorder.elapsed))
                    .font(.system(size: 76, weight: .light))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Waveform(levels: recorder.levels, paused: recorder.isPaused || !recorder.isRecording)
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
                        Text(recorder.isRecording ? " " : "Appoggia il telefono vicino a chi parla")
                            .font(.footnote)
                            .foregroundStyle(Color(white: 0.65))
                    }
                }
                .frame(height: 40)
                .padding(.top, 20)

                Spacer()

                controls
                    .padding(.bottom, 40)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .confirmationDialog("Vuoi scartare questa registrazione?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Scarta", role: .destructive) {
                recorder.discard()
                dismiss()
            }
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
        .onAppear {
            recorder.refreshInputs()
            if autoStart && !recorder.isRecording {
                Task { await recorder.start() }
            }
        }
    }

    private var header: some View {
        HStack {
            Button("Chiudi") {
                if recorder.isRecording { confirmDiscard = true } else { dismiss() }
            }
            .font(.body)
            .foregroundStyle(Color(red: 1, green: 0.71, blue: 0.68))
            .frame(minWidth: 60, minHeight: 44, alignment: .leading)

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(recorder.isRecording && !recorder.isPaused ? Color.red : Color.gray)
                    .frame(width: 9, height: 9)
                Text(stateLabel).font(.subheadline.weight(.semibold))
            }

            Spacer()
            Color.clear.frame(width: 60, height: 44)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var microphoneSelector: some View {
        VStack(spacing: 8) {
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
                .background(Color.white.opacity(0.1), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .foregroundStyle(.white)
            }
            Text(recorder.isUsingExternalInput ? "Microfono esterno collegato" : "Microfono dell'iPhone")
                .font(.footnote)
                .foregroundStyle(Color(white: 0.65))
        }
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: 40) {
            if recorder.isRecording {
                RoundControl(systemImage: recorder.isPaused ? "play.fill" : "pause.fill",
                             label: recorder.isPaused ? "Riprendi" : "Pausa",
                             tint: .white) {
                    recorder.togglePause()
                }

                VStack(spacing: 8) {
                    Button {
                        if let finished = recorder.stop() {
                            onFinish(finished)
                        }
                        dismiss()
                    } label: {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white)
                            .frame(width: 28, height: 28)
                            .frame(width: 88, height: 88)
                            .background(Theme.recordGradient, in: Circle())
                            .overlay(Circle().stroke(Theme.coral.opacity(0.18), lineWidth: 6).padding(-6))
                            .shadow(color: Theme.magenta.opacity(0.45), radius: 15, y: 8)
                    }
                    .accessibilityLabel("Termina e salva")
                    Text("Termina").font(.footnote).foregroundStyle(Color(white: 0.78))
                }

                RoundControl(systemImage: "flag.fill", label: "Segna",
                             tint: Color(red: 1, green: 0.70, blue: 0.25)) {
                    recorder.addHighlight()
                }
            } else {
                VStack(spacing: 8) {
                    Button {
                        Task { await recorder.start() }
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 96, height: 96)
                            .background(Theme.recordGradient, in: Circle())
                            .shadow(color: Theme.magenta.opacity(0.45), radius: 15, y: 8)
                    }
                    .accessibilityLabel("Avvia registrazione")
                    Text("Avvia").font(.footnote).foregroundStyle(Color(white: 0.78))
                }
            }
        }
    }
}

private struct RoundControl: View {
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
