import XCTest
import AVFoundation
import SwiftData
@testable import RegistratoreAI

/// Prove sulla Sintesi (parti troppo lunghe, testi enormi), sui tentativi di rete
/// e sul silenzio che tiene viva l'app in background.
@MainActor
final class ServiceTests: XCTestCase {

    /// Finto modello sul dispositivo: rifiuta (come quello vero) i testi oltre il suo limite
    /// e restituisce appunti più corti del testo ricevuto.
    final class FakeModel {
        let limit: Int
        let shrink: Double
        private(set) var calls = 0
        private(set) var longest = 0
        init(limit: Int, shrink: Double = 0.15) { self.limit = limit; self.shrink = shrink }

        func answer(_ instructions: String, _ prompt: String) throws -> String {
            calls += 1
            let size = instructions.count + prompt.count
            longest = max(longest, size)
            guard size <= limit else { throw SummaryFailure.tooLong }
            let length = max(40, Int(Double(prompt.count) * shrink))
            return "- " + String(repeating: "a", count: length)
        }
    }

    private func longText(chars: Int) -> String {
        let segments = TestSupport.syntheticSegments(duration: Double(chars) / 12, speakers: ["S1", "S2"], seed: 21)
        return segments.map(\.text).joined(separator: "\n")
    }

    private let template = SummaryTemplate.byID("sintesi")

    func testSummaryOfThreeHoursFitsTheModel() async throws {
        let model = FakeModel(limit: 9_000)
        let text = longText(chars: 160_000)
        XCTAssertGreaterThan(text.count, 100_000)
        let result = try await SummaryService.summarize(transcript: text, template: template, chunkChars: SummaryService.chunkChars,
                                                        using: { try model.answer($0, $1) }, progress: { _ in })
        XCTAssertFalse(result.isEmpty)
        print("Sintesi di \(text.count) caratteri: \(model.calls) richieste")
        XCTAssertLessThan(model.calls, 80)
    }

    /// Il modello vero a volte accetta meno testo del previsto: le parti si dividono da sole.
    func testSummaryAdaptsWhenModelAcceptsLessText() async throws {
        let model = FakeModel(limit: 2_500)
        let text = longText(chars: 40_000)
        let result = try await SummaryService.summarize(transcript: text, template: template, chunkChars: SummaryService.chunkChars,
                                                        using: { try model.answer($0, $1) }, progress: { _ in })
        XCTAssertFalse(result.isEmpty)
    }

    func testSummaryStopsWhenNotesDoNotShrink() async {
        let model = FakeModel(limit: 5_000, shrink: 1.2)
        let text = longText(chars: 30_000)
        do {
            _ = try await SummaryService.summarize(transcript: text, template: template, chunkChars: SummaryService.chunkChars,
                                                   using: { try model.answer($0, $1) }, progress: { _ in })
        } catch {
            XCTAssertTrue(error is SummaryFailure)
        }
        XCTAssertLessThan(model.calls, 2_000, "La sintesi non deve girare all'infinito")
    }

    func testShortTranscriptIsOneRequest() async throws {
        let model = FakeModel(limit: 9_000)
        _ = try await SummaryService.summarize(transcript: "Breve appunto di prova.", template: template, chunkChars: SummaryService.chunkChars,
                                               using: { try model.answer($0, $1) }, progress: { _ in })
        XCTAssertEqual(model.calls, 1)
    }

    func testSplitKeepsAllTextWithinLimit() {
        let text = longText(chars: 50_000) + "\n" + String(repeating: "parola ", count: 3_000)
        let chunks = SummaryService.split(text, maxChars: 4_000)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 4_000 })
        let original = text.filter { !$0.isWhitespace && $0 != "." }
        let joined = chunks.joined().filter { !$0.isWhitespace && $0 != "." }
        XCTAssertEqual(original.count, joined.count)
    }

    // MARK: - Rete

    func testTransientNetworkErrorsAreRetried() {
        XCTAssertTrue(ClaudeService.isTransient(URLError(.timedOut)))
        XCTAssertTrue(ClaudeService.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(ClaudeService.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertFalse(ClaudeService.isTransient(URLError(.cancelled)))
        XCTAssertFalse(ClaudeService.isTransient(URLError(.badURL)))
        XCTAssertTrue(ClaudeService.isTransient(status: 529))
        XCTAssertTrue(ClaudeService.isTransient(status: 429))
        XCTAssertFalse(ClaudeService.isTransient(status: 401))
        XCTAssertFalse(ClaudeService.isTransient(status: 400))
        XCTAssertEqual(ClaudeService.maxAttempts, 3)
    }

    // MARK: - Background

    func testSilenceFileIsValidAudio() throws {
        let data = KeepAlive.silenceWAV(seconds: 1, sampleRate: 8_000)
        XCTAssertEqual(data.count, 44 + 16_000)
        let url = try KeepAlive.silenceURL()
        let player = try AVAudioPlayer(contentsOf: url)
        XCTAssertEqual(player.duration, 1, accuracy: 0.05)
    }

    func testKeepAliveStartsAndStops() {
        KeepAlive.shared.start()
        XCTAssertTrue(KeepAlive.shared.isRunning)
        KeepAlive.shared.stop()
        XCTAssertFalse(KeepAlive.shared.isRunning)
    }

    func testBackgroundIdentifierUsesPermittedPrefix() {
        // Con Sideloadly l'identificativo dell'app può cambiare: vale quello permesso in Info.plist.
        XCTAssertEqual(BackgroundWork.identifierPrefix(permitted: ["it.registratoreai.app.processing.*"],
                                                       bundle: "it.registratoreai.app.ABC123"),
                       "it.registratoreai.app.processing.")
        XCTAssertEqual(BackgroundWork.identifierPrefix(permitted: nil, bundle: "x.y"), "x.y.processing.")
    }

    /// Bug 0.17.0: eliminando una registrazione mentre era in lavorazione, la lavorazione
    /// continuava sul file ormai cancellato e finiva con un errore (e un rapporto di diagnostica).
    func testDeletingRecordingDuringProcessingStopsQuietly() async throws {
        let container = try ModelContainer(for: Recording.self, Summary.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let r = Recording(title: "x", audioFileName: "inesistente.m4a", duration: 4, inputName: "")
        context.insert(r)
        try context.save()
        let id = r.id
        let pipeline = Pipeline.shared
        pipeline.run(r, in: context) {
            try await Task.sleep(for: .seconds(30))
            throw URLError(.fileDoesNotExist)
        }
        XCTAssertTrue(pipeline.isRunning(r))
        RecordingActions.delete(r, in: context)
        let deadline = Date.now.addingTimeInterval(10)
        while pipeline.isRunning(id: id) && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(pipeline.isRunning(id: id))
        XCTAssertNil(pipeline.errors[id])
    }

    func testPreviewSkipsHeadings() throws {
        let container = try ModelContainer(for: Recording.self, Summary.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let r = Recording(title: "x", audioFileName: "", duration: 1, inputName: "")
        context.insert(r)
        let s = Summary(templateID: "sintesi", templateName: "Sintesi veloce",
                        text: "# Sintesi\n\n**Di cosa si parla:** organizzazione dei turni di marzo.\n- altro")
        s.recording = r
        context.insert(s)
        try context.save()
        XCTAssertEqual(r.preview, "organizzazione dei turni di marzo.")
    }
}
