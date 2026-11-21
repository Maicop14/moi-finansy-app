import XCTest
@testable import Balance

final class AppLockTests: XCTestCase {
    func testPINAndPersistentDelay() throws {
        for pin in ["", "12345", "123456", "1234567", "12 456", "абвгде", "１２３４５６"] { XCTAssertFalse(PINRecord.valid(pin)) }
        var record = try PINRecord.create("0123", domain: nil)
        XCTAssertNotEqual(record.salt, try PINRecord.create("0123", domain: nil).salt)
        let now = Date()
        for _ in 1...5 { XCTAssertFalse(try record.verify("0124", at: now)) }
        var restored = try JSONDecoder().decode(PINRecord.self, from: JSONEncoder().encode(record))
        XCTAssertThrowsError(try restored.verify("0123", at: now.addingTimeInterval(29)))
        XCTAssertTrue(try restored.verify("0123", at: now.addingTimeInterval(30)))
        XCTAssertEqual(restored.failures, 0)
        XCTAssertEqual(restored.retryAfter, .distantPast)
    }

    func testWelcomeGreetingsCoverTheLocalDay() {
        for (hour, expected) in [(0,"Доброй ночи"), (5,"Доброй ночи"), (6,"Доброе утро"),
                                 (11,"Добрый день"), (15,"Добрый день"), (18,"Добрый вечер"), (22,"Доброй ночи")] {
            XCTAssertEqual(WelcomeScene.at(hour: hour).greeting, expected)
        }
    }

    func testBackdropPartFollowsTheGreeting() {
        for hour in 0..<24 {
            let expected: DayPart = hour < 6 || hour >= 18 ? .night : (hour < 11 ? .morning : .day)
            XCTAssertEqual(DayPart.at(hour: hour), expected, "hour \(hour)")
            let greeting = WelcomeScene.at(hour: hour).greeting
            switch DayPart.at(hour: hour) {
            case .morning: XCTAssertEqual(greeting, "Доброе утро")
            case .day: XCTAssertEqual(greeting, "Добрый день")
            case .night: XCTAssertTrue(["Добрый вечер", "Доброй ночи"].contains(greeting))
            }
        }
    }

    /// Photos live in App/ArchiveResources/Splash. When installed, every part of the day has at
    /// least one and every name loads; without them the backdrop falls back to a gradient.
    func testSplashPhotosWhenInstalled() throws {
        let names = SplashPhotos.names(SplashPhotos.available)
        try XCTSkipIf(names.isEmpty, "Личные фото не установлены — используется нейтральный фон.")
        for part in DayPart.allCases {
            XCTAssertFalse(part.photos.isEmpty, "\(part)")
            for name in part.photos { XCTAssertNotNil(SplashPhotos.image(name), name) }
        }
        XCTAssertEqual(Set(DayPart.allCases.flatMap(\.photos)), Set(names), "every photo is reachable from some part of the day")
    }

    func testSplashNamesSortAndFilter() {
        XCTAssertEqual(SplashPhotos.names(["splash-night-02", "x", "splash-day-01", "splash-night-01"]),
                       ["splash-day-01", "splash-night-01", "splash-night-02"])
    }

    @MainActor func testBackdropIsStableUntilReshuffled() {
        let backdrop = Backdrop.shared
        let morning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now)!
        let first = backdrop.photo(at: morning)
        XCTAssertEqual(backdrop.photo(at: morning.addingTimeInterval(600)), first)
        if let first { XCTAssertTrue(DayPart.morning.photos.contains(first)) } else { XCTAssertTrue(DayPart.morning.photos.isEmpty) }
        for _ in 0..<10 {
            backdrop.reshuffle()
            if let pick = backdrop.photo(at: morning) { XCTAssertTrue(DayPart.morning.photos.contains(pick)) }
        }
    }

    func testPreviousSixDigitRecord() throws {
        let json = #"{"salt":"AAECAwQFBgcICQoLDA0ODw==","verifier":"AgBFmg80/TCQe0j8lVKfvwk8kK01abBcEwWa8fH/3BM=","failures":0,"retryAfter":-100000}"#
        var record = try JSONDecoder().decode(PINRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.length)
        XCTAssertFalse(try record.verify("0456", at: .now))
        XCTAssertTrue(try record.verify("045678", at: .now))
        XCTAssertThrowsError(try PINRecord.create("045678", domain: nil))
    }
}
