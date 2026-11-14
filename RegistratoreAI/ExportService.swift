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
