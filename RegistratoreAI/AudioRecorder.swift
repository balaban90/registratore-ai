import Foundation
import AVFoundation
import UIKit

struct AudioInput: Identifiable, Hashable {
    let id: String
    let name: String
    let isExternal: Bool
}

struct FinishedRecording {
    let fileName: String
    let duration: Double
    let highlights: [Double]
    let inputName: String
    let startedAt: Date
    /// Note scritte durante la registrazione, una per riga con l'orario ("[12:30] testo").
    var notes: String = ""
}

/// Nota scritta durante la registrazione, legata al momento in cui è stata presa.
struct TimedNote: Identifiable, Hashable {
    let id = UUID()
    let time: Double
    let text: String

    static func joined(_ notes: [TimedNote]) -> String {
        notes.map { "[\(formatTime($0.time))] \($0.text)" }.joined(separator: "\n")
    }
}

/// Registratore: AAC mono, funziona in background, sceglie il microfono e
/// sopravvive a chiamate e scollegamenti del microfono esterno.
@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false {
        didSet { AudioActivity.recording = isRecording }
    }
    @Published var isPaused = false
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0
    /// Ultimi livelli, per disegnare la forma d'onda.
    @Published var levels: [Float] = Array(repeating: 0, count: 44)
    @Published var highlights: [Double] = []
    @Published var timedNotes: [TimedNote] = []
    @Published var inputs: [AudioInput] = []
    @Published var currentInputID: String?
    @Published var currentInputName = "Microfono iPhone"
    @Published var autoSwitchToExternal = true
    @Published var statusMessage: String?
    @Published var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileName: String?
    private var startedAt = Date.now
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private let session = AVAudioSession.sharedInstance()

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor in self?.handleRouteChange(rawReason: raw) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            Task { @MainActor in self?.handleInterruption(rawType: raw) }
        })
        try? configureSession()
        refreshInputs()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Sessione audio e microfoni

    private func configureSession() throws {
        // .default (non .voiceChat) per non abbassare la qualità; niente Bluetooth HFP in ingresso.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
    }

    private func displayName(_ port: AVAudioSessionPortDescription) -> String {
        port.portType == .builtInMic ? "Microfono iPhone" : port.portName
    }

    private func isExternal(_ port: AVAudioSessionPortDescription) -> Bool {
        port.portType != .builtInMic
    }

    var isUsingExternalInput: Bool {
        inputs.first(where: { $0.id == currentInputID })?.isExternal ?? false
    }

    func refreshInputs() {
        let available = session.availableInputs ?? []
        inputs = available.map { AudioInput(id: $0.uid, name: displayName($0), isExternal: isExternal($0)) }
        if let current = session.currentRoute.inputs.first {
            currentInputID = current.uid
            currentInputName = displayName(current)
        }
    }

    func selectInput(id: String) {
        guard let port = session.availableInputs?.first(where: { $0.uid == id }) else { return }
        do {
            try session.setPreferredInput(port)
            statusMessage = nil
            DiagnosticLog.info(.recording, "Microfono scelto: \(port.portName) (\(port.portType.rawValue))")
        } catch {
            statusMessage = "Non riesco a usare \(port.portName): \(error.localizedDescription)"
            DiagnosticLog.error(.recording, "Impossibile usare \(port.portName)", error)
        }
        refreshInputs()
    }

    private func externalPort() -> AVAudioSessionPortDescription? {
        let preferred: [AVAudioSession.Port] = [.usbAudio, .headsetMic, .lineIn]
        let available = session.availableInputs ?? []
        for type in preferred {
            if let p = available.first(where: { $0.portType == type }) { return p }
        }
        return nil
    }

    private func handleRouteChange(rawReason: UInt) {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else {
            refreshInputs()
            return
        }
        let route = session.currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        DiagnosticLog.info(.recording, "Cambio percorso audio, motivo \(rawReason) · ingresso: \(route.isEmpty ? "nessuno" : route)\(isRecording ? " · durante la registrazione" : "")")
        switch reason {
        case .newDeviceAvailable:
            if autoSwitchToExternal, let ext = externalPort() {
                try? session.setPreferredInput(ext)
                statusMessage = "Uso il microfono esterno: \(ext.portName)"
            }
        case .oldDeviceUnavailable:
            try? session.setPreferredInput(nil)
            if isRecording {
                statusMessage = "Microfono esterno scollegato: continuo con quello dell'iPhone"
            }
        default:
            break
        }
        refreshInputs()
    }

    private func handleInterruption(rawType: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: rawType), isRecording else { return }
        switch type {
        case .began:
            // iOS mette in pausa il registratore (es. chiamata in arrivo).
            DiagnosticLog.warning(.recording, "Interruzione iniziata a \(formatTime(elapsed))")
            isPaused = true
            statusMessage = "In pausa per una chiamata o un'altra app"
            LiveActivityManager.shared.recordingPaused(elapsed: elapsed)
        case .ended:
            do {
                try session.setActive(true)
                recorder?.record()
                isPaused = false
                statusMessage = "Registrazione ripresa"
                DiagnosticLog.info(.recording, "Ripresa dopo l'interruzione")
                LiveActivityManager.shared.recordingResumed(elapsed: elapsed)
            } catch {
                statusMessage = "Tocca Riprendi per continuare"
                DiagnosticLog.error(.recording, "Ripresa automatica non riuscita", error)
            }
        @unknown default:
            break
        }
    }

    // MARK: - Registrazione

    func start() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            permissionDenied = true
            DiagnosticLog.warning(.recording, "Permesso microfono negato")
            return
        }
        do {
            try configureSession()
            if autoSwitchToExternal, let ext = externalPort() {
                try? session.setPreferredInput(ext)
            }
            refreshInputs()

            let name = Storage.newFileName()
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let rec = try AVAudioRecorder(url: Storage.url(for: name), settings: settings)
            rec.delegate = self
            rec.isMeteringEnabled = true
            guard rec.record() else {
                statusMessage = "Impossibile avviare la registrazione"
                DiagnosticLog.error(.recording, "record() ha restituito false")
                return
            }
            recorder = rec
            fileName = name
            startedAt = .now
            highlights = []
            timedNotes = []
            elapsed = 0
            isRecording = true
            isPaused = false
            statusMessage = nil
            startTimer()
            LiveActivityManager.shared.recordingStarted(title: "Nuova registrazione")
            TranscriptionService.prewarm()
            DiagnosticLog.info(.recording, "Avviata · ingresso \(currentInputName) · \(Int(session.sampleRate)) Hz · ingressi disponibili \(inputs.count)")
        } catch {
            statusMessage = "Errore: \(error.localizedDescription)"
            DiagnosticLog.error(.recording, "Avvio non riuscito", error)
        }
    }

    func togglePause() {
        guard let recorder, isRecording else { return }
        if isPaused {
            try? session.setActive(true)
            recorder.record()
            isPaused = false
            LiveActivityManager.shared.recordingResumed(elapsed: elapsed)
        } else {
            recorder.pause()
            isPaused = true
            LiveActivityManager.shared.recordingPaused(elapsed: elapsed)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func addHighlight() {
        guard isRecording else { return }
        highlights.append(elapsed)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Nota veloce durante la registrazione (come "scrivi un pensiero" di Plaud): l'AI la usa come contesto.
    func addNote(_ text: String, at time: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRecording, !clean.isEmpty else { return }
        timedNotes.append(TimedNote(time: time, text: clean))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func stop() -> FinishedRecording? {
        guard let recorder, let fileName else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        DiagnosticLog.info(.recording, "Fermata · durata \(formatTime(max(duration, elapsed))) · segnalibri \(highlights.count) · file \(DiagnosticLog.fileSize(Storage.url(for: fileName)))")
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        self.fileName = nil
        isRecording = false
        isPaused = false
        level = 0
        levels = Array(repeating: 0, count: 44)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if KeepAlive.shared.isRunning {
            // Un'altra registrazione è ancora in lavorazione: la sessione audio resta attiva.
            KeepAlive.shared.reassert()
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        return FinishedRecording(fileName: fileName, duration: max(duration, elapsed), highlights: highlights,
                                 inputName: currentInputName, startedAt: startedAt, notes: TimedNote.joined(timedNotes))
    }

    /// Annulla e cancella il file.
    func discard() {
        if let result = stop() {
            Storage.delete(fileName: result.fileName)
            DiagnosticLog.info(.recording, "Registrazione annullata dall'utente")
        }
        LiveActivityManager.shared.recordingDiscarded()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let recorder else { return }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        level = isPaused ? 0 : max(0, min(1, (db + 55) / 55))
        if !isPaused {
            levels.removeFirst()
            levels.append(level)
        }
        if recorder.isRecording {
            elapsed = recorder.currentTime
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "errore sconosciuto"
        DiagnosticLog.error(.recording, "Errore di codifica: \(message)")
        Task { @MainActor in self.statusMessage = "Errore di registrazione: \(message)" }
    }
}
