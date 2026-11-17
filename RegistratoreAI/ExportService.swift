import UIKit

enum ExportService {
    private static func safeName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.components(separatedBy: bad).joined(separator: "-")
        return cleaned.isEmpty ? "Registrazione" : String(cleaned.prefix(80))
    }

    private static func tempURL(_ title: String, ext: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(safeName(title)).\(ext)")
    }

    static func text(title: String, body: String) -> URL? {
        let url = tempURL(title, ext: "txt")
        do {
            try "\(title)\n\n\(body)".write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { return nil }
    }

    /// Markdown con tutto: dati, elaborazioni, note, momenti segnati e trascrizione.
    /// Si importa in Notion, Obsidian, Bear, Craft o nell'app Note.
    static func markdown(_ recording: Recording) -> URL? {
        let url = tempURL(recording.title, ext: "md")
        do {
            try markdownText(recording).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { return nil }
    }

    static func markdownText(_ recording: Recording) -> String {
        let date = recording.createdAt.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Locale(identifier: "it_IT")))
        var md = "# \(recording.title)\n\n"
        md += "- Data: \(date)\n- Durata: \(formatTime(recording.duration))\n"
        let people = recording.speakerOrder.map { recording.speakerName($0) }
        if recording.diarized && !people.isEmpty { md += "- Persone: \(people.joined(separator: ", "))\n" }
        for summary in recording.sortedSummaries {
            md += "\n## \(summary.displayName)\n\n\(summary.text)\n"
        }
        if !recording.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md += "\n## Note\n\n\(recording.notes)\n"
        }
        if !recording.highlights.isEmpty {
            md += "\n## Momenti segnati\n\n" + recording.highlights.map { "- \(formatTime($0))" }.joined(separator: "\n") + "\n"
        }
        if recording.transcript != nil {
            md += "\n## Trascrizione\n\n" + recording.timedTranscript.components(separatedBy: "\n").joined(separator: "  \n") + "\n"
        }
        return md
    }

    /// RTF: si apre con Word, Pages e Google Documenti.
    static func rtf(title: String, body: String) -> URL? {
        let doc = NSMutableAttributedString(
            string: title + "\n\n",
            attributes: [.font: UIFont.boldSystemFont(ofSize: 16)]
        )
        doc.append(NSAttributedString(string: body, attributes: [.font: UIFont.systemFont(ofSize: 12)]))
        let url = tempURL(title, ext: "rtf")
        do {
            let data = try doc.data(
                from: NSRange(location: 0, length: doc.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            try data.write(to: url)
            return url
        } catch { return nil }
    }

    static func pdf(title: String, body: String) -> URL? {
        let formatter = UISimpleTextPrintFormatter(text: "\(title)\n\n\(body)")
        formatter.font = UIFont.systemFont(ofSize: 11)

        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4
        let printable = page.insetBy(dx: 48, dy: 56)
        renderer.setValue(NSValue(cgRect: page), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()

        let url = tempURL(title, ext: "pdf")
        do {
            try data.write(to: url)
            return url
        } catch { return nil }
    }
}
