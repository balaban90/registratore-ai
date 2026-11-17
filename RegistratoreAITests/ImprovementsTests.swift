import XCTest
import SwiftData
@testable import RegistratoreAI

/// Prove delle novità 0.18.0, prese dai migliori progetti simili:
/// domande su tutto l'archivio con le fonti, cose da fare verso Promemoria,
/// note e momenti segnati usati dall'AI, velocità di ascolto, esportazione Markdown.
@MainActor
final class ImprovementsTests: XCTestCase {

    // MARK: - Chiedi all'archivio

    private func item(_ title: String, days: Double, summary: String = "", lines: [String]) -> ArchiveAsk.Item {
        ArchiveAsk.Item(id: UUID(), title: title, date: Date.now.addingTimeInterval(-days * 86_400), duration: 600,
                        summary: summary, notes: "", names: [],
                        lines: lines.enumerated().map { (Double($0.offset * 30), "[\(formatTime(Double($0.offset * 30)))] \($0.element)") })
    }

    func testKeywordsDropCommonWordsAndMatchPlurals() {
        let keys = ArchiveAsk.keywords(in: "Cosa abbiamo deciso sui contratti della mensa?")
        XCTAssertTrue(keys.contains("contr"))
        XCTAssertTrue(keys.contains("mensa"))
        XCTAssertFalse(keys.contains("cosa"))
        XCTAssertFalse(keys.contains("della"))
    }

    func testArchivePicksRelevantRecordings() {
        let items = [
            item("Riunione di reparto", days: 1, lines: ["Parliamo dei turni di Natale.", "Le ferie sono confermate."]),
            item("Trattativa", days: 5, summary: "Discusso il rinnovo del contratto integrativo.",
                 lines: ["Il contratto scade a marzo.", "Serve una nuova proposta sul contratto."]),
            item("Lezione di inglese", days: 2, lines: ["Past simple and present perfect."])
        ]
        let chosen = ArchiveAsk.select(items, for: "Quando scade il contratto?")
        XCTAssertEqual(chosen.first?.title, "Trattativa")
        XCTAssertFalse(chosen.contains { $0.title == "Lezione di inglese" })
    }

    func testArchiveFallsBackToRecentWhenNothingMatches() {
        let items = (0..<10).map { item("Registrazione \($0)", days: Double($0), lines: ["testo qualsiasi"]) }
        let chosen = ArchiveAsk.select(items, for: "zzzz")
        XCTAssertEqual(chosen.count, ArchiveAsk.maxRecordings)
        XCTAssertEqual(chosen.first?.title, "Registrazione 0")
    }

    func testArchiveMaterialStaysWithinBudget() {
        let long = TestSupport.syntheticSegments(duration: 3 * 3600, speakers: ["A", "B"], seed: 5).map(\.text)
        let items = (0..<20).map { item("Riunione \($0)", days: Double($0), lines: long) }
        let material = ArchiveAsk.material(for: "riunione budget", from: items)
        XCTAssertLessThanOrEqual(material.text.count, ArchiveAsk.totalChars + 2_000)
        XCTAssertLessThanOrEqual(material.sources.count, ArchiveAsk.maxRecordings)
        XCTAssertTrue(material.text.contains("[R1]"))
    }

    func testExcerptsKeepOnlyMatchingPassages() {
        let lines = (0..<200).map { $0 == 120 ? "Il preventivo arriva lunedì." : "Frase numero \($0) senza importanza." }
        let excerpt = ArchiveAsk.excerpts(item("x", days: 0, lines: lines), keywords: ArchiveAsk.keywords(in: "preventivo"), limit: 2_000)
        XCTAssertTrue(excerpt.contains("preventivo"))
        XCTAssertTrue(excerpt.contains("Frase numero 119"))
        XCTAssertFalse(excerpt.contains("Frase numero 10 "))
    }

    func testCitationsBecomeLinksToTheAudio() {
        let sources = [ArchiveAsk.Source(number: 1, id: UUID(), title: "A"), ArchiveAsk.Source(number: 2, id: UUID(), title: "B")]
        let answer = "Il contratto scade a marzo [R2 12:30]. Lo ha confermato Marco [R2 12:30] e poi [R1] e [R1 1:02:03]. Ignora [R9 00:10]."
        let citations = ArchiveAsk.citations(in: answer, sources: sources)
        XCTAssertEqual(citations.count, 3)
        XCTAssertEqual(citations[0].number, 2)
        XCTAssertEqual(citations[0].time, 750)
        XCTAssertNil(citations[1].time)
        XCTAssertEqual(citations[2].time, 3723)
    }

    // MARK: - Promemoria

    func testTasksFromMeetingSummary() {
        let text = """
        ## In sintesi
        Riunione sui turni di dicembre.
        ## Decisioni prese
        - Confermati i turni di Natale
        ## Azioni da fare
        - **Marco**: mandare il prospetto entro venerdì.
        - Chiamare l'ufficio personale
        - Non specificato
        ## Questioni aperte
        - Ferie di gennaio
        """
        XCTAssertEqual(RemindersService.tasks(in: text), ["Marco: mandare il prospetto entro venerdì", "Chiamare l'ufficio personale"])
    }

    func testTasksFromNumberedHeadingsAndCheckboxes() {
        let text = """
        1. Di cosa si parla: organizzazione del convegno
        2. Punti importanti
        - Sala prenotata
        3. Cose da fare o da ricordare
        - Stampare i badge
        - [x] Prenotare il catering
        - [ ] Inviare gli inviti
        """
        XCTAssertEqual(RemindersService.tasks(in: text), ["Stampare i badge", "Inviare gli inviti"])
    }

    func testNoTasksWhenSectionMissing() {
        XCTAssertTrue(RemindersService.tasks(in: "## Sintesi\n- Un punto\n- Un altro punto").isEmpty)
    }

    // MARK: - Note e momenti segnati

    func testUserContextIncludesNotesAndHighlights() {
        let text = Recording.userContext(notes: "[00:30] Parla la direttrice", highlights: [75, 3_700])
        XCTAssertTrue(text.contains("Parla la direttrice"))
        XCTAssertTrue(text.contains("[01:15]"))
        XCTAssertTrue(text.contains("[1:01:40]"))
        XCTAssertEqual(Recording.userContext(notes: "  ", highlights: []), "")
    }

    func testTimedNotesAreJoinedWithTime() {
        let joined = TimedNote.joined([TimedNote(time: 65, text: "Idea per il progetto"), TimedNote(time: 130, text: "Chiedere il budget")])
        XCTAssertEqual(joined, "[01:05] Idea per il progetto\n[02:10] Chiedere il budget")
    }

    func testDeviceSummaryReceivesUserContext() async throws {
        var received = ""
        _ = try await SummaryService.summarize(transcript: "Breve appunto.", template: SummaryTemplate.byID("sintesi"),
                                               chunkChars: SummaryService.chunkChars,
                                               userContext: "Note dell'utente:\nRiunione con il fornitore",
                                               using: { instructions, _ in received = instructions; return "ok" },
                                               progress: { _ in })
        XCTAssertTrue(received.contains("Riunione con il fornitore"))
        XCTAssertTrue(received.contains("CONTESTO DELL'UTENTE"))
    }

    // MARK: - Ascolto ed esportazione

    func testPlaybackRateCyclesAndIsRemembered() {
        UserDefaults.standard.removeObject(forKey: AudioPlayer.rateKey)
        let player = AudioPlayer()
        XCTAssertEqual(player.rate, 1)
        player.nextRate()
        XCTAssertEqual(player.rate, 1.25)
        XCTAssertEqual(AudioPlayer.savedRate, 1.25)
        for _ in 0..<4 { player.nextRate() }
        XCTAssertEqual(player.rate, 1)
        XCTAssertEqual(AudioPlayer.label(for: 1.5), "1,5×")
        XCTAssertEqual(AudioPlayer.label(for: 2), "2×")
        UserDefaults.standard.removeObject(forKey: AudioPlayer.rateKey)
    }

    func testMarkdownExportContainsEverything() throws {
        let container = try ModelContainer(for: Recording.self, Summary.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let r = Recording(title: "Incontro", audioFileName: "", duration: 90, inputName: "", highlights: [42])
        r.segments = [TranscriptSegment(start: 3, end: 6, text: "Buongiorno a tutti.")]
        r.transcript = r.plainTranscript
        r.notes = "Portare i documenti"
        context.insert(r)
        let s = Summary(templateID: "riunione", templateName: "Riunione · AI", text: "## Decisioni\n- Si parte a gennaio")
        s.recording = r
        context.insert(s)
        try context.save()
        let md = ExportService.markdownText(r)
        XCTAssertTrue(md.hasPrefix("# Incontro"))
        XCTAssertTrue(md.contains("## Riunione · AI"))
        XCTAssertTrue(md.contains("Si parte a gennaio"))
        XCTAssertTrue(md.contains("Portare i documenti"))
        XCTAssertTrue(md.contains("- 00:42"))
        XCTAssertTrue(md.contains("[00:03] Buongiorno a tutti."))
    }

    func testConceptMapTemplateExists() {
        XCTAssertEqual(SummaryTemplate.byID("mappa").name, "Mappa dei concetti")
    }
}
