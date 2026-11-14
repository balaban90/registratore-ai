import Foundation

/// Dove vivono i file audio: Documenti/Registrazioni (visibili anche dall'app File).
enum Storage {
    static var recordingsDir: URL {
        let dir = URL.documentsDirectory.appending(path: "Registrazioni", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func url(for fileName: String) -> URL {
        recordingsDir.appending(path: fileName)
    }

    static func newFileName(ext: String = "m4a") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(f.string(from: .now))_\(UUID().uuidString.prefix(4)).\(ext)"
    }

    static func delete(fileName: String) {
        guard !fileName.isEmpty else { return }
        try? FileManager.default.removeItem(at: url(for: fileName))
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

func defaultTitle(for date: Date) -> String {
    "Registrazione del " + date.formatted(.dateTime.day().month(.wide).hour().minute().locale(Locale(identifier: "it_IT")))
}
