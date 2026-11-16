import XCTest
@testable import RegistratoreAI

/// Prove con registrazioni lunghe: dati letti in fretta, parlanti assegnati in fretta,
/// riproduzione che trova subito la frase giusta.
@MainActor
final class LongRecordingTests: XCTestCase {

    private func longRecording(hours: Double = 2) -> Recording {
        let r = Recording(title: "Prova", audioFileName: "", duration: hours * 3600, inputName: "")
        r.segments = TestSupport.syntheticSegments(duration: hours * 3600, speakers: ["S1", "S2", "S3", "S4"], seed: 11)
        r.diarized = true
        r.speakerNames = ["S1": "Marco"]
        return r
    }

    func testSyntheticDataIsRealistic() {
        let segments = TestSupport.syntheticSegments(duration: 7200, speakers: ["S1", "S2"], seed: 1)
        XCTAssertGreaterThan(segments.count, 1000)
        XCTAssertEqual(segments, segments.sorted { $0.start < $1.start })
        XCTAssertLessThanOrEqual(segments.last?.end ?? 0, 7200)
    }

    /// Prima della correzione una schermata leggeva la trascrizione centinaia di volte:
    /// con 2 ore di audio servivano secondi per ogni aggiornamento.
    func testRepeatedReadsAreFast() {
        let r = longRecording()
        let started = Date.now
        for _ in 0..<2_000 {
            _ = r.segments
            _ = r.speakerOrder
            _ = r.speakerName("S2")
            _ = r.speakerNames
        }
        let elapsed = Date.now.timeIntervalSince(started)
        print("TEMPO letture ripetute (2.000 righe): \(String(format: "%.3f", elapsed)) s")
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testTextExportsAreFast() {
        let r = longRecording(hours: 3)
        let started = Date.now
        let plain = r.plainTranscript
        let compact = r.compactTranscript
        let timed = r.timedTranscript
        let elapsed = Date.now.timeIntervalSince(started)
        print("TEMPO testi di 3 ore: \(String(format: "%.3f", elapsed)) s")
        XCTAssertFalse(plain.isEmpty)
        XCTAssertTrue(plain.contains("Marco: "))
        XCTAssertTrue(compact.contains("Persona 2: ") || compact.contains("Persona 3: "))
        XCTAssertFalse(timed.isEmpty)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testCacheFollowsChanges() {
        let r = longRecording(hours: 0.1)
        let before = r.segments
        var changed = before
        changed[0].text = "Testo cambiato."
        changed[0].speaker = "S9"
        r.segments = changed
        XCTAssertEqual(r.segments[0].text, "Testo cambiato.")
        XCTAssertEqual(r.speakerOrder.first, "S9")
        // Modifica diretta dei byte salvati (come quando i dati arrivano dall'archivio).
        r.segmentsData = try? JSONEncoder().encode(before)
        XCTAssertEqual(r.segments, before)
        XCTAssertNotEqual(r.speakerOrder.first, "S9")
    }

    func testCacheKeepsRecordingsApart() {
        let a = Recording(title: "A", audioFileName: "", duration: 10, inputName: "")
        let b = Recording(title: "B", audioFileName: "", duration: 10, inputName: "")
        a.segments = [TranscriptSegment(start: 0, end: 1, text: "uno")]
        b.segments = [TranscriptSegment(start: 0, end: 1, text: "due")]
        XCTAssertEqual(a.segments.first?.text, "uno")
        XCTAssertEqual(b.segments.first?.text, "due")
    }

    func testCurrentSegmentLookupMatchesLinearSearch() {
        let segments = TestSupport.syntheticSegments(duration: 3600, speakers: ["S1", "S2"], seed: 5)
        var rng = SeededGenerator(seed: 9)
        for _ in 0..<500 {
            let t = Double.random(in: 0...3700, using: &rng)
            let expected = t > 0 ? segments.last(where: { $0.start <= t + 0.2 })?.id : nil
            XCTAssertEqual(PlaybackFollower.segmentID(at: t, in: segments), expected)
        }
        XCTAssertNil(PlaybackFollower.segmentID(at: 0, in: segments))
        XCTAssertNil(PlaybackFollower.segmentID(at: 10, in: []))
    }

    // MARK: - Parlanti

    private func turns(duration: Double, seed: UInt64) -> [SpeakerTurn] {
        var rng = SeededGenerator(seed: seed)
        var result: [SpeakerTurn] = []
        var t = 0.0
        while t < duration {
            let length = Double.random(in: 1...12, using: &rng)
            result.append(SpeakerTurn(speakerId: ["S1", "S2", "S3"].randomElement(using: &rng)!, start: t, end: t + length))
            t += length + Double.random(in: 0...0.8, using: &rng)
        }
        return result
    }

    /// Versione semplice e lenta, usata come riferimento.
    private func naiveSpeaker(_ start: Double, _ end: Double, _ turns: [SpeakerTurn]) -> String? {
        var best: (String, Double)?
        let e = max(end, start + 0.2)
        for t in turns {
            let overlap = min(e, t.end) - max(start, t.start)
            if overlap > 0, overlap > (best?.1 ?? 0) { best = (t.speakerId, overlap) }
        }
        return best?.0
    }

    func testTurnIndexMatchesNaiveSearch() {
        let list = turns(duration: 1800, seed: 3)
        let index = DiarizationService.TurnIndex(list)
        var rng = SeededGenerator(seed: 4)
        for _ in 0..<2_000 {
            let start = Double.random(in: 0...1800, using: &rng)
            let end = start + Double.random(in: 0...2, using: &rng)
            if let expected = naiveSpeaker(start, end, list) {
                XCTAssertEqual(index.speaker(for: start, end), expected)
            } else {
                XCTAssertNotNil(index.speaker(for: start, end))
            }
        }
    }

    func testAssignSpeakersOnTwoHoursIsFast() {
        let segments = TestSupport.syntheticSegments(duration: 7200, speakers: ["X"], seed: 8)
        let list = turns(duration: 7200, seed: 2)
        let started = Date.now
        let result = DiarizationService.assign(list, to: segments)
        let elapsed = Date.now.timeIntervalSince(started)
        print("TEMPO parlanti su 2 ore (\(segments.count) frasi, \(list.count) turni): \(String(format: "%.3f", elapsed)) s")
        XCTAssertGreaterThanOrEqual(result.count, segments.count)
        XCTAssertTrue(result.allSatisfy { $0.speaker != nil })
        XCTAssertLessThan(elapsed, 3.0)
    }

    func testAssignSplitsSentenceWhenSpeakerChanges() {
        let words = (0..<10).map { i in
            TranscriptWord(text: " parola\(i)", start: Double(i), end: Double(i) + 0.8, confidence: 0.9)
        }
        let segment = TranscriptSegment.make(from: words)!
        let list = [SpeakerTurn(speakerId: "A", start: 0, end: 5), SpeakerTurn(speakerId: "B", start: 5, end: 10)]
        let result = DiarizationService.assign(list, to: [segment])
        XCTAssertEqual(result.map(\.speaker), ["A", "B"])
        XCTAssertEqual(result.map { $0.words?.count ?? 0 }, [5, 5])
    }
}
