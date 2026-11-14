import SwiftUI

struct RecordView: View {
    let onFinish: (FinishedRecording) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = AudioRecorder()
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                microphoneSection

                Spacer()

                Text(formatTime(recorder.elapsed))
                    .font(.system(size: 64, weight: .light, design: .rounded))
                    .monospacedDigit()

                LevelMeter(level: recorder.level)
                    .frame(height: 12)
                    .padding(.horizontal, 40)

                if !recorder.highlights.isEmpty {
                    Label("\(recorder.highlights.count) momenti segnati", systemImage: "flag.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }

                if let message = recorder.statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                controls
            }
            .padding()
            .navigationTitle(recorder.isRecording ? (recorder.isPaused ? "In pausa" : "Registrazione") : "Pronto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chiudi") {
                        if recorder.isRecording { confirmDiscard = true } else { dismiss() }
                    }
                }
            }
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
            .onAppear { recorder.refreshInputs() }
        }
    }

    private var microphoneSection: some View {
        VStack(spacing: 8) {
            Menu {
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
            } label: {
                Label(recorder.currentInputName, systemImage: "mic")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
            }
            Toggle("Usa il microfono esterno appena lo collego", isOn: $recorder.autoSwitchToExternal)
                .font(.footnote)
                .padding(.horizontal, 24)
        }
    }

    private var controls: some View {
        HStack(spacing: 36) {
            if recorder.isRecording {
                Button {
                    recorder.togglePause()
                } label: {
                    Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                        .font(.title2)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Color(.secondarySystemBackground)))
                }
                .accessibilityLabel(recorder.isPaused ? "Riprendi" : "Pausa")

                Button {
                    if let finished = recorder.stop() {
                        onFinish(finished)
                    }
                    dismiss()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                        .background(Circle().fill(.red))
                }
                .accessibilityLabel("Termina e salva")

                Button {
                    recorder.addHighlight()
                } label: {
                    Image(systemName: "flag.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Color(.secondarySystemBackground)))
                }
                .accessibilityLabel("Segna questo momento")
            } else {
                Button {
                    Task { await recorder.start() }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                        .frame(width: 96, height: 96)
                        .background(Circle().fill(.red))
                }
                .accessibilityLabel("Avvia registrazione")
            }
        }
        .padding(.bottom, 24)
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(level > 0.9 ? Color.red : Color.green)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }
}
