import XCTest

/// Prove dell'interfaccia con una registrazione di 2 ore (1.800 frasi, 4 parlanti)
/// e 40 registrazioni nell'elenco. Ogni passaggio ha un tempo massimo: se l'app
/// rallenta, la prova fallisce e la versione non viene pubblicata.
final class LongRecordingUITests: XCTestCase {
    private var app: XCUIApplication!
    private let longTitle = "Riunione di prova lunga"
    private let shortTitle = "Appunto di prova 1"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-UITest", "-UITestSeed", "long"]
        app.launch()
        XCTAssertTrue(app.staticTexts[longTitle].firstMatch.waitForExistence(timeout: 90),
                      "La registrazione di prova non compare nell'elenco")
    }

    // MARK: - Aiuti

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var selectedSegment: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'segment-' AND isSelected == true")).firstMatch
    }

    private func index(of segment: XCUIElement) -> Int {
        Int(segment.identifier.dropFirst("segment-".count)) ?? -1
    }

    private func time(_ label: String, _ block: () -> Void) -> Double {
        let started = Date()
        block()
        let elapsed = Date().timeIntervalSince(started)
        print("TEMPO \(label): \(String(format: "%.2f", elapsed)) s")
        return elapsed
    }

    /// Il simulatore di GitHub è lento in assoluto: si confronta la registrazione di 2 ore
    /// con quella di 20 secondi sullo stesso simulatore. Deve comportarsi allo stesso modo.
    private func assertComparable(_ label: String, long: Double, short: Double, margin: Double = 1.2) {
        let limit = short * 1.5 + margin
        print("CONFRONTO \(label): 2 ore \(String(format: "%.2f", long)) s · 20 secondi \(String(format: "%.2f", short)) s · limite \(String(format: "%.2f", limit)) s")
        XCTAssertLessThan(long, limit, "\(label): la registrazione lunga è più lenta di quella breve (\(String(format: "%.1f", long)) s contro \(String(format: "%.1f", short)) s)")
    }

    private func open(_ title: String) -> Double {
        let cell = app.staticTexts[title].firstMatch
        if !cell.isHittable {
            for _ in 0..<8 where !cell.isHittable { app.swipeUp() }
        }
        return time("Apertura «\(title)»") {
            cell.tap()
            XCTAssertTrue(app.buttons["Trascrizione"].waitForExistence(timeout: 20))
        }
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts[longTitle].firstMatch.waitForExistence(timeout: 20))
    }

    /// Tempo medio per passare da una scheda all'altra (Trascrizione → Note → Elaborazioni, 2 giri).
    private func tabCycle(_ title: String) -> Double {
        var total = 0.0
        for round in 1...2 {
            total += time("\(title) · Trascrizione (\(round))") {
                app.buttons["Trascrizione"].tap()
                XCTAssertTrue(app.buttons["segment-0"].waitForExistence(timeout: 20))
            }
            total += time("\(title) · Note (\(round))") {
                app.buttons["Note"].tap()
                XCTAssertTrue(element("notes-field").waitForExistence(timeout: 20))
            }
            total += time("\(title) · Elaborazioni (\(round))") {
                app.buttons["Elaborazioni"].tap()
                XCTAssertTrue(element("summary-card").waitForExistence(timeout: 20))
            }
        }
        return total / 6
    }

    /// Trascinamento di una distanza fissa, senza lancio (così si misura il disegno, non l'inerzia).
    private func drag(times: Int) -> Double {
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        let started = Date()
        for _ in 0..<times {
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.1)
        }
        return Date().timeIntervalSince(started) / Double(times)
    }

    // MARK: - Prove

    func testOpeningAndTabsLikeShortRecording() {
        let shortOpen = open(shortTitle)
        let shortTabs = tabCycle("20 secondi")
        back()
        let longOpen = open(longTitle)
        let longTabs = tabCycle("2 ore")
        assertComparable("Apertura", long: longOpen, short: shortOpen)
        assertComparable("Cambio scheda", long: longTabs, short: shortTabs, margin: 0.8)
        // Una seconda apertura (dati già pronti) non deve essere più lenta della prima.
        back()
        let again = open(longTitle)
        assertComparable("Seconda apertura", long: again, short: shortOpen)
    }

    func testScrollingLongTranscriptLikeShortList() {
        let list = drag(times: 6)
        print("TEMPO trascinamento elenco: \(String(format: "%.2f", list)) s")
        _ = open(longTitle)
        app.buttons["Trascrizione"].tap()
        XCTAssertTrue(app.buttons["segment-0"].waitForExistence(timeout: 20))
        let transcript = drag(times: 20)
        print("TEMPO trascinamento trascrizione: \(String(format: "%.2f", transcript)) s")
        assertComparable("Scorrimento", long: transcript, short: list, margin: 0.6)
        let after = time("Cambio scheda dopo lo scorrimento") {
            app.buttons["Elaborazioni"].tap()
            XCTAssertTrue(element("summary-card").waitForExistence(timeout: 20))
        }
        XCTAssertLessThan(after, 8)
    }

    func testPlaybackFollowsTranscript() {
        _ = open(longTitle)
        app.buttons["Trascrizione"].tap()
        XCTAssertTrue(app.buttons["segment-0"].waitForExistence(timeout: 20))
        _ = drag(times: 2)
        // Una frase visibile più in basso: toccandola l'audio parte da lì.
        var target: XCUIElement?
        for i in 3..<300 {
            let row = app.buttons["segment-\(i)"]
            if row.exists && row.isHittable { target = row; break }
        }
        guard let target else { return XCTFail("Nessuna frase visibile da toccare") }
        let tapped = index(of: target)
        target.tap()
        XCTAssertTrue(app.buttons["Pausa"].waitForExistence(timeout: 10), "La riproduzione non parte")
        XCTAssertTrue(selectedSegment.waitForExistence(timeout: 10), "La frase in riproduzione non è evidenziata")
        let first = index(of: selectedSegment)
        XCTAssertGreaterThanOrEqual(first, tapped - 1)

        // 30 secondi di ascolto: la frase evidenziata deve avanzare e restare visibile.
        sleep(30)
        let current = selectedSegment
        XCTAssertTrue(current.exists, "Durante la riproduzione nessuna frase è evidenziata")
        let reached = index(of: current)
        print("Riproduzione: dalla frase \(tapped) alla \(reached)")
        XCTAssertGreaterThan(reached, first, "L'evidenziazione non segue l'audio")
        XCTAssertTrue(current.isHittable, "La trascrizione non scorre insieme all'audio")

        let during = time("Cambio scheda durante la riproduzione") {
            app.buttons["Note"].tap()
            XCTAssertTrue(element("notes-field").waitForExistence(timeout: 20))
        }
        XCTAssertLessThan(during, 8)
        app.buttons["Trascrizione"].tap()
        XCTAssertTrue(app.buttons["Pausa"].waitForExistence(timeout: 10))
        app.buttons["Pausa"].tap()
        XCTAssertTrue(app.buttons["Riproduci"].waitForExistence(timeout: 10))
    }
}

/// La lavorazione deve continuare con l'app in background (era il problema principale).
final class BackgroundProcessingUITests: XCTestCase {
    func testProcessingContinuesInBackground() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // 45 passi da un secondo: senza lavoro in background iOS sospende l'app dopo circa 30 s.
        app.launchArguments = ["-UITest", "-UITestSeed", "pending", "-UITestFakeProcessing", "45"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Registrazione da lavorare"].firstMatch.waitForExistence(timeout: 60))
        let running = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Prova: passo'")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 20), "La lavorazione non è partita")

        XCUIDevice.shared.press(.home)
        sleep(70)
        app.activate()

        let done = app.staticTexts["Sintesi di prova completata in background."].firstMatch
        let finished = done.waitForExistence(timeout: 8)
        if !finished, running.exists { print("Lavorazione ancora in corso al rientro: \(running.label)") }
        XCTAssertTrue(finished, "La lavorazione si è fermata mentre l'app era in background")
    }
}
