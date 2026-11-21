import XCTest
final class ImportRoundTrip: XCTestCase {
    @MainActor private func unlockTestDevice(_ app: XCUIApplication) {
        guard app.buttons["pinKey7"].waitForExistence(timeout: 3) else { return }
        func enter() { for n in [7, 5, 2, 8] { app.buttons["pinKey" + String(n)].tap() } }
        enter()
        if app.staticTexts["Повторите новый PIN"].exists { enter() }
    }
    @MainActor func testImportReviewSaveAndReplay() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Сценарий записывает тестовую операцию и запускается на симуляторе.")
        #else
        let app = XCUIApplication()
        app.launch()
        unlockTestDevice(app)
        XCTAssertTrue(app.buttons["Операции"].firstMatch.waitForExistence(timeout: 8))
        // Leaving the app and coming back keeps it open, on the same screen.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["Операции"].firstMatch.waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["pinKey7"].exists)
        let operations = app.buttons["Операции"].firstMatch
        guard operations.waitForExistence(timeout: 15) else { XCTFail(app.debugDescription); return }
        operations.tap()
        let token = UUID().uuidString
        let text = "Date;Description;Amount;transaction_id\n2026-10-04;UI test;+138.53;" + token
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Банк-" + String(token) + ".csv")
        try String(text).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        for attempt in 0..<2 {
            app.open(url)
            unlockTestDevice(app)
            let picker = app.buttons["importAccount"]
            XCTAssertTrue(picker.waitForExistence(timeout: 8))
            picker.tap()
            let account = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Расчётный счёт")).firstMatch
            if !account.waitForExistence(timeout: 4) { picker.tap() }
            XCTAssertTrue(account.waitForExistence(timeout: 4))
            account.tap()
            let save = app.buttons["Сохранить"].firstMatch
            XCTAssertTrue(save.waitForExistence(timeout: 5))
            if attempt == 0 {
                XCTAssertTrue(save.isEnabled)
                save.tap()
                XCTAssertTrue(app.staticTexts["Сохранено операций: 1"].waitForExistence(timeout: 6))
            } else {
                XCTAssertTrue(app.staticTexts["Уже загружена"].waitForExistence(timeout: 6))
                XCTAssertFalse(save.isEnabled)
                app.buttons["Закрыть"].firstMatch.tap()
            }
        }
        #endif
    }
}
