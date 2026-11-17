import Foundation
import AVFoundation

@MainActor
final class AudioPlayer: ObservableObject {
    @Published var isPlaying = false {
        didSet { AudioActivity.playing = isPlaying }
    }
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var error: String?
    /// Velocità di ascolto, ricordata tra una registrazione e l'altra.
    @Published private(set) var rate: Float = AudioPlayer.savedRate

    static let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]
    static let rateKey = "playbackRate"
    static var savedRate: Float {
        let value = UserDefaults.standard.float(forKey: rateKey)
        return rates.contains(value) ? value : 1
    }

    static func label(for rate: Float) -> String {
        let text = rate == rate.rounded() ? String(Int(rate)) : String(rate).replacingOccurrences(of: ".", with: ",")
        return text + "×"
    }

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) {
        guard player == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            let p = try AVAudioPlayer(contentsOf: url)
            p.enableRate = true
            p.rate = rate
            p.prepareToPlay()
            player = p
            duration = p.duration
        } catch {
            self.error = "Audio non leggibile: \(error.localizedDescription)"
        }
    }

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    /// Passa alla velocità successiva: 1× → 1,25× → 1,5× → 2× → 0,75× → 1×.
    func nextRate() {
        let index = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(index + 1) % Self.rates.count]
        player?.rate = rate
        UserDefaults.standard.set(rate, forKey: Self.rateKey)
    }

    func seek(to time: Double, play: Bool = true) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
        if play && !player.isPlaying { togglePlay() }
    }

    func skip(_ delta: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(player.currentTime + delta, player.duration))
        currentTime = player.currentTime
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        isPlaying = false
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            timer?.invalidate()
        }
    }
}
