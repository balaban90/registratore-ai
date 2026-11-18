import XCTest
import AVFoundation
import SwiftUI
@testable import RegistratoreAI

/// Prove della 0.19.0: mappa dei concetti disegnata, buchi della trascrizione recuperati
/// senza ritrascrivere tutto, ripresa automatica dei passaggi non riusciti.
@MainActor
final class FasterAutomaticTests: XCTestCase {

    // MARK: - Mappa dei concetti

    private let sampleMap = """
    # Il gusto dei mitocondri
    ## Energia della cellula
    - I mitocondri producono **ATP**
    - Consumano ossigeno
    ## Gusto
    - Cellule del gusto ricche di mitocondri
    * Segnale al cervello
    ## Ricerca
    1. Studio su topi
    ## Collegamenti
    - Energia della cellula → Gusto: serve energia per sentire i sapori
    - Ricerca -> Gusto
    """

    func testConceptMapIsParsedIntoBranches() throws {
        let map = try XCTUnwrap(ConceptMap.parse(sampleMap))
        XCTAssertEqual(map.center, "Il gusto dei mitocondri")
        XCTAssertEqual(map.branches.map(\.title), ["Energia della cellula", "Gusto", "Ricerca"])
        XCTAssertEqual(map.branches[0].ideas, ["I mitocondri producono ATP", "Consumano ossigeno"])
        XCTAssertEqual(map.branches[1].ideas.count, 2)
        XCTAssertEqual(map.branches[2].ideas, ["Studio su topi"])
        XCTAssertEqual(map.links.count, 2)
        XCTAssertEqual(map.links[0].from, "Energia della cellula")
        XCTAssertEqual(map.links[0].to, "Gusto")
        XCTAssertEqual(map.links[0].why, "serve energia per sentire i sapori")
        XCTAssertEqual(map.links[1].why, "")
    }

    func testTextThatIsNotAMapShowsAsText() {
        XCTAssertNil(ConceptMap.parse("Solo un paragrafo senza rami."))
        XCTAssertNil(ConceptMap.parse("# Tema\n## Unico ramo\n- idea"))
    }

    func testMapWithoutMainTitleGetsOne() throws {
        let map = try XCTUnwrap(ConceptMap.parse("## Uno\n- a\n## Due\n- b"))
        XCTAssertEqual(map.center, "Mappa dei concetti")
        XCTAssertEqual(map.branches.count, 2)
    }

    func testConceptMapCanBeDrawnAsImage() {
        let map = ConceptMap.parse(sampleMap)!
        let renderer = ImageRenderer(content: ConceptMapCanvas(map: map, collapsed: .constant([])))
        let image = renderer.uiImage
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image?.size.width ?? 0, 300)
    }

    // MARK: - Trascrizione: solo i buchi

    private func silentFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silenzio-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    func testExcerptCopiesOnlyTheRequestedStretch() throws {
        let source = try silentFile(seconds: 30)
        let piece = try TranscriptionService.excerpt(of: source, from: 10, to: 16)
        let file = try AVAudioFile(forReading: piece.url)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(piece.offset, 10, accuracy: 0.01)
        XCTAssertEqual(seconds, 6, accuracy: 0.05)
    }

    func testRecoveredPhrasesAreMovedToTheirPlace() {
        let word = TranscriptWord(text: " ciao", start: 1, end: 1.5, confidence: 0.9)
        let piece = TranscriptSegment(start: 1, end: 1.5, text: "ciao", words: [word])
        let moved = TranscriptionService.shifted(piece, by: 100)
        XCTAssertEqual(moved.start, 101)
        XCTAssertEqual(moved.end, 101.5)
        XCTAssertEqual(moved.words?.first?.start, 101)

        let existing = [TranscriptSegment(start: 0, end: 90, text: "prima"),
                        TranscriptSegment(start: 120, end: 200, text: "dopo")]
        let filled = TranscriptionService.fillGaps(existing, with: [moved], duration: 200)
        XCTAssertEqual(filled.map(\.text), ["prima", "ciao", "dopo"])
    }

    // MARK: - Ripresa automatica

    func testTemporaryProblemsAreRetriedButNotMissingCredit() {
        XCTAssertTrue(Pipeline.worthRetrying(URLError(.notConnectedToInternet)))
        XCTAssertTrue(Pipeline.worthRetrying(CancellationErrorLike()))
        XCTAssertFalse(Pipeline.worthRetrying(TextError(text: "Your credit balance is too low")))
        XCTAssertFalse(Pipeline.worthRetrying(TextError(text: "invalid x-api-key")))
    }

    /// Rapporto del 18/11: "Risposta claude-haiku-5-5 vuota · stop max_tokens". Il ragionamento
    /// del modello consumava tutto il limite: per correggere e riassumere va spento.
    func testAIThinkingIsTurnedOffWhereAllowed() {
        XCTAssertEqual(ClaudeService.thinkingMode(for: .haiku), "disabled")
        XCTAssertEqual(ClaudeService.thinkingMode(for: .sonnet), "between_tools")
        XCTAssertNil(ClaudeService.thinkingMode(for: .opus))
    }

    // MARK: - Barra di avanzamento

    func testStatusMessagesMapToTheRightStep() {
        XCTAssertEqual(Pipeline.step(for: "Trascrivo…"), .preparing)
        XCTAssertEqual(Pipeline.step(for: "Preparo il motore Preciso…"), .preparing)
        XCTAssertEqual(Pipeline.step(for: "Trascrivo con il motore Preciso…"), .transcribing)
        XCTAssertEqual(Pipeline.step(for: "Controllo che non manchi nessuna parte…"), .transcribing)
        XCTAssertEqual(Pipeline.step(for: "Preparo il riconoscimento delle voci (la prima volta scarica i modelli)…"), .speakers)
        XCTAssertEqual(Pipeline.step(for: "L'AI migliora la trascrizione (2 di 5 parti)…"), .improving)
        XCTAssertEqual(Pipeline.step(for: "Preparo la sintesi…"), .summary)
        XCTAssertEqual(Pipeline.step(for: "Leggo la parte 3 di 7…"), .summary)
        XCTAssertEqual(Pipeline.step(for: "Scelgo il titolo…"), .title)
    }

    func testPartsAreReadFromTheMessage() {
        XCTAssertEqual(Pipeline.parts(in: "L'AI migliora la trascrizione (2 di 5 parti)…") ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(Pipeline.parts(in: "Leggo la parte 3 di 4…") ?? -1, 0.5, accuracy: 0.001)
        XCTAssertNil(Pipeline.parts(in: "Preparo la sintesi…"))
    }

    func testTimeProgressNeverStopsAndNeverReachesTheEnd() {
        XCTAssertEqual(Pipeline.timeCurve(0.5), 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(Pipeline.timeCurve(1.5), Pipeline.timeCurve(1.0))
        XCTAssertGreaterThan(Pipeline.timeCurve(3), Pipeline.timeCurve(2))
        XCTAssertLessThan(Pipeline.timeCurve(100), 0.98)
    }

    private struct CancellationErrorLike: Error {}
    private struct TextError: LocalizedError, CustomStringConvertible {
        let text: String
        var description: String { text }
        var errorDescription: String? { text }
    }
}
