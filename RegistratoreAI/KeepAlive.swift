import Foundation
import AVFoundation

/// Chi sta usando l'audio in questo momento, per non pestarsi i piedi.
@MainActor
enum AudioActivity {
    static var recording = false
    static var playing = false
}

/// Tiene l'app al lavoro a schermo bloccato finché c'è una lavorazione in corso.
///
/// iOS sospende un'app pochi secondi dopo che è andata in background, anche a metà di una
/// trascrizione o di una richiesta all'AI (era la causa delle lavorazioni ferme). Un'app che
/// usa l'audio invece resta attiva: durante la lavorazione si riproduce silenzio, mescolato
/// all'audio delle altre app (musica, podcast) senza disturbarle. Si ferma a lavoro finito.
@MainActor
final class KeepAlive {
    static let shared = KeepAlive()

    private(set) var isRunning = false
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installObservers()
        play()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        player?.stop()
        player = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if !AudioActivity.recording && !AudioActivity.playing {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        DiagnosticLog.info(.pipeline, "Lavoro in background: sessione audio chiusa")
    }

    /// Da chiamare quando un'altra parte dell'app ha cambiato la sessione audio
    /// (fine registrazione, app in background dopo aver ascoltato una registrazione).
    func reassert() {
        guard isRunning else { return }
        play()
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    private func play() {
        let session = AVAudioSession.sharedInstance()
        do {
            if !AudioActivity.recording && !AudioActivity.playing {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
        } catch {
            DiagnosticLog.warning(.pipeline, "Sessione audio per il lavoro in background non attivabile: \(DiagnosticLog.describe(error))")
        }
        if player == nil {
            do {
                let p = try AVAudioPlayer(contentsOf: Self.silenceURL())
                p.numberOfLoops = -1
                p.volume = 0
                p.prepareToPlay()
                player = p
            } catch {
                DiagnosticLog.warning(.pipeline, "Silenzio per il lavoro in background non disponibile: \(DiagnosticLog.describe(error))")
                return
            }
        }
        if player?.isPlaying == false {
            let started = player?.play() ?? false
            DiagnosticLog.info(.pipeline, started ? "Lavoro in background: sessione audio attiva" : "Lavoro in background: sessione audio non partita")
        }
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                // Fine della chiamata o dell'altra app: si riprende a lavorare.
                KeepAlive.shared.reassert()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                KeepAlive.shared.player = nil
                KeepAlive.shared.reassert()
            }
        })
    }

    /// Un secondo di silenzio (WAV), creato una volta.
    static func silenceURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "silenzio.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try silenceWAV(seconds: 1, sampleRate: 8_000).write(to: url, options: .atomic)
        return url
    }

    static func silenceWAV(seconds: Int, sampleRate: Int) -> Data {
        let samples = seconds * sampleRate
        let dataBytes = samples * 2
        var data = Data()
        func append(_ string: String) { data.append(string.data(using: .ascii)!) }
        func append32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func append16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        append("RIFF"); append32(UInt32(36 + dataBytes)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        append("data"); append32(UInt32(dataBytes))
        data.append(Data(count: dataBytes))
        return data
    }
}
