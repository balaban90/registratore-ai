import XCTest

/// Prove dell'interfaccia con una registrazione di 2 ore (1.800 frasi, 4 parlanti)
/// e 40 registrazioni nell'elenco. Ogni passaggio ha un tempo massimo: se l'app
/// rallenta, la prova fallisce e la versione non viene pubblicata.
final class LongRecordingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITest", "-UITestSeed", "long"]
        app.launch()
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

    @discardableResult
    private func timed(_ label: String, limit: Double, _ block: () -> Void) -> Double {
        let started = Date()
        block()
        let elapsed = Date().timeIntervalSince(started)
        print("TEMPO \(label): \(String(format: "%.2f", elapsed)) s (massimo \(limit) s)")
        XCTAssertLessThan(elapsed, limit, "\(label): troppo lento (\(String(format: "%.1f", elapsed)) s)")
        return elapsed
    }

    private func openLongRecording() {
        let cell = app.staticTexts["Riunione di prova lunga"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 90), "La registrazione di prova non compare nell'elenco")
        timed("Apertura registrazione di 2 ore", limit: 4) {
            cell.tap()
            XCTAssertTrue(app.buttons["Trascrizione"].waitForExistence(timeout: 15))
        }
    }

    private func showTranscript() {
        app.buttons["Trascrizione"].tap()
        XCTAssertTrue(app.buttons["segment-0"].waitForExistence(timeout: 15))
    }

    // MARK: - Prove

    func testTabSwitchingIsFast() {
        openLongRecording()
        for round in 1...3 {
            timed("Scheda Trascrizione (\(round))", limit: 3) {
                app.buttons["Trascrizione"].tap()
                XCTAssertTrue(app.buttons["segment-0"].waitForExistence(timeout: 15))
            }
            timed("Scheda Note (\(round))", limit: 3) {
                app.buttons["Note"].tap()
                XCTAssertTrue(element("notes-field").waitForExistence(timeout: 15))
            }
            timed("Scheda Elaborazioni (\(round))", limit: 3) {
                app.buttons["Elaborazioni"].tap()
                XCTAssertTrue(element("summary-card").waitForExistence(timeout: 15))
            }
        }
    }

    func testScrollingLongTranscriptStaysSmooth() {
        openLongRecording()
        showTranscript()
        timed("Scorrimento di 20 schermate", limit: 45) {
            for _ in 0..<20 { app.swipeUp(velocity: .fast) }
        }
        timed("Cambio scheda dopo lo scorrimento", limit: 3) {
            app.buttons["Elaborazioni"].tap()
            XCTAssertTrue(element("summary-card").waitForExistence(timeout: 15))
        }
    }

    func testPlaybackFollowsTranscript() {
        openLongRecording()
        showTranscript()
        app.swipeUp()
        app.swipeUp()
        // Una frase visibile più in basso: toccandola l'audio parte da lì.
        var target: XCUIElement?
        for i in 5..<400 {
            let row = app.buttons["segment-\(i)"]
            if row.exists && row.isHittable { target = row; break }
        }
        guard let target else { return XCTFail("Nessuna frase visibile da toccare") }
        let tapped = index(of: target)
        timed("Avvio riproduzione da una frase", limit: 3) {
            target.tap()
            XCTAssertTrue(app.buttons["Pausa"].waitForExistence(timeout: 5))
        }
        XCTAssertTrue(selectedSegment.waitForExistence(timeout: 5), "La frase in riproduzione non è evidenziata")
        XCTAssertGreaterThanOrEqual(index(of: selectedSegment), tapped - 1)

        // 25 secondi di ascolto: la frase evidenziata deve avanzare e restare visibile.
        sleep(25)
        let current = selectedSegment
        XCTAssertTrue(current.exists, "Durante la riproduzione nessuna frase è evidenziata")
        let reached = index(of: current)
        print("Riproduzione: dalla frase \(tapped) alla \(reached)")
        XCTAssertGreaterThan(reached, tapped, "L'evidenziazione non segue l'audio")
        XCTAssertTrue(current.isHittable, "La trascrizione non scorre insieme all'audio")

        timed("Cambio scheda durante la riproduzione", limit: 3) {
            app.buttons["Note"].tap()
            XCTAssertTrue(element("notes-field").waitForExistence(timeout: 15))
        }
        timed("Ritorno alla trascrizione durante la riproduzione", limit: 3) {
            app.buttons["Trascrizione"].tap()
            XCTAssertTrue(app.buttons["Pausa"].waitForExistence(timeout: 5))
        }
        timed("Pausa", limit: 3) {
            app.buttons["Pausa"].tap()
            XCTAssertTrue(app.buttons["Riproduci"].waitForExistence(timeout: 5))
        }
    }

    func testListWithManyRecordings() {
        XCTAssertTrue(app.staticTexts["Riunione di prova lunga"].firstMatch.waitForExistence(timeout: 90))
        timed("Scorrimento elenco di 41 registrazioni", limit: 25) {
            for _ in 0..<6 { app.swipeUp(velocity: .fast) }
            for _ in 0..<6 { app.swipeDown(velocity: .fast) }
        }
        let cell = app.staticTexts["Riunione di prova lunga"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        for round in 1...3 {
            timed("Apri e chiudi la registrazione lunga (\(round))", limit: 6) {
                cell.tap()
                XCTAssertTrue(app.buttons["Trascrizione"].waitForExistence(timeout: 15))
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(cell.waitForExistence(timeout: 15))
            }
        }
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
