import XCTest

/// Le impostazioni tecniche restano nascoste finché non si tocca 7 volte "Versione".
final class SettingsUITests: XCTestCase {
    func testDeveloperModeIsHiddenUntilUnlocked() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UITest"]
        app.launch()

        let settings = app.buttons["Impostazioni"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Impostazioni"].waitForExistence(timeout: 10))

        // Schermata semplice: niente opzioni tecniche.
        for technical in ["Modello AI", "Motore di trascrizione", "Diagnostica", "Token GitHub", "Consumo del mese"] {
            XCTAssertFalse(app.staticTexts[technical].exists, "\"\(technical)\" non deve comparire nelle Impostazioni normali")
        }
        XCTAssertFalse(app.buttons["Modalità sviluppatore"].exists)

        let version = app.descendants(matching: .any).matching(identifier: "version-row").firstMatch
        for _ in 0..<12 where !version.isHittable { app.swipeUp() }
        XCTAssertTrue(version.isHittable)
        for _ in 0..<7 { version.tap() }

        let developer = app.buttons["Modalità sviluppatore"]
        XCTAssertTrue(developer.waitForExistence(timeout: 5), "La modalità sviluppatore non si attiva")
        developer.tap()
        XCTAssertTrue(app.navigationBars["Modalità sviluppatore"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Modello AI"].exists || app.staticTexts["MODELLO AI"].exists)

        // Disattivandola, sparisce di nuovo.
        let off = app.buttons["Disattiva modalità sviluppatore"]
        for _ in 0..<12 where !off.isHittable { app.swipeUp() }
        off.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Impostazioni"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Modalità sviluppatore"].waitForExistence(timeout: 2))
    }
}
