import XCTest

/// Walks through every section in demo mode (fictional data, hidden amounts) for a narrated screen recording.
/// Scene lengths come from the narration clips (TEST_RUNNER_SCENES="8.0,8.1,…"); each scene logs its start time
/// so the voice-over can be placed exactly. Never touches real data: demo mode keeps its store in memory.
final class DemoWalkthrough: XCTestCase {
    @MainActor func testDemoWalkthrough() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Только для симулятора.")
        #else
        let lengths = (ProcessInfo.processInfo.environment["SCENES"] ?? "").split(separator: ",").compactMap { Double($0) }
        let app = XCUIApplication()
        app.launchArguments = ["-demoMode"]

        func button(_ prefix: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        }
        /// Taps the first on-screen match, scrolling gently until one is reachable (never taps off-screen).
        func tap(_ prefix: String, label exact: String? = nil) {
            let query = exact.map { app.buttons.matching(NSPredicate(format: "label == %@", $0)) }
                ?? app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            _ = query.firstMatch.waitForExistence(timeout: 5)
            for _ in 0..<6 {
                if let target = query.allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.maxY < app.frame.maxY - 150 && $0.frame.minY > 60 }) {
                    target.tap(); return
                }
                app.swipeUp(velocity: 400); Thread.sleep(forTimeInterval: 0.7)
            }
        }
        func reveal(_ text: String) {
            for _ in 0..<8 {
                let element = app.staticTexts[text].firstMatch
                if element.exists && element.isHittable && element.frame.minY < app.frame.maxY * 0.45 { return }
                app.swipeUp(velocity: 450); Thread.sleep(forTimeInterval: 0.8)
            }
        }
        func scroll(_ times: Int) { for _ in 0..<times { app.swipeUp(velocity: 500); Thread.sleep(forTimeInterval: 1.0) } }
        func scrollTop() { for _ in 0..<4 { app.swipeDown(velocity: 2500) } }
        /// Tab bar buttons sit at the very bottom: pick the lowest on-screen match.
        func tab(_ name: String) {
            let matches = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).allElementsBoundByIndex.filter(\.isHittable)
            matches.max(by: { $0.frame.minY < $1.frame.minY })?.tap()
        }
        func home() { tab("Главная"); Thread.sleep(forTimeInterval: 0.5) }

        var index = 0
        func scene(_ action: () -> Void) {
            let start = Date()
            print("SCENE \(index + 1) \(start.timeIntervalSince1970)")
            action()
            let length = index < lengths.count ? lengths[index] : 4
            // Always leave most of the narration on the finished screen, even when the action itself was slow.
            Thread.sleep(forTimeInterval: max(length * 0.85, length + 0.5 - Date().timeIntervalSince(start)))
            index += 1
        }

        scene { app.launch() }                                                   // 1 splash
        scene { _ = button("Главная").waitForExistence(timeout: 10) }            // 2 home cards
        scene {                                                                  // 3 currency switch
            app.buttons["$"].firstMatch.tap(); Thread.sleep(forTimeInterval: 1.6)
            app.buttons["€"].firstMatch.tap(); Thread.sleep(forTimeInterval: 1.4)
            app.buttons["₽"].firstMatch.tap()
        }
        scene { scroll(2); Thread.sleep(forTimeInterval: 0.8); scrollTop() }   // 4 actions and sections
        scene { tab("Операции") }                                                // 5 donut
        scene { tap("Кафе") }                                                    // 6 subcategories
        scene { tap("", label: "Выделить отдельно") }                            // 7 pin
        scene {                                                                  // 8 merchants and operations
            app.swipeUp(velocity: 350); Thread.sleep(forTimeInterval: 0.6)
            let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Кофейни")).allElementsBoundByIndex.filter(\.isHittable)
            rows.last?.tap()
            Thread.sleep(forTimeInterval: 0.8); scrollTop()
        }
        scene { scrollTop(); tap("Все расходы"); Thread.sleep(forTimeInterval: 0.6); scroll(2) } // 9 history
        scene { scrollTop(); home(); tap("Регулярные платежи"); Thread.sleep(forTimeInterval: 3); scroll(1) } // 10
        scene { scrollTop(); home(); tap("Бюджет"); Thread.sleep(forTimeInterval: 3); scroll(2) }             // 11
        scene { scrollTop(); home(); tap("Кредиты"); Thread.sleep(forTimeInterval: 2.5); tap("График на") }   // 12
        scene { scrollTop(); tab("Капитал"); Thread.sleep(forTimeInterval: 1.5); scroll(2) }                  // 13
        scene { reveal("Уведомления") }                                                                       // 14 notifications, backup
        scene { scrollTop(); home(); tap("Благотворительность") }                                            // 15
        scene { scrollTop(); home(); tap("Доходы") }                                                                      // 16
        scene { home() }                                                                                     // 17
        #endif
    }
}
