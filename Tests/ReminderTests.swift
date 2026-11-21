import Foundation
import Testing
@testable import Balance

struct ReminderTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private func dates(_ plan: [PlannedReminder]) -> [Date] {
        plan.compactMap { if case .date(let d) = $0.when { d } else { nil } }
    }

    @Test func signingBeforeAnEarlyMorningExpiry() {
        // Expires at 06:04, before the 10:00 reminder time: the last warning moves to 21:00 the evening before.
        let plan = ReminderPlan.signing(expiry: date(26, 6, 4), now: date(20, 12), minutes: 600, calendar: calendar)
        #expect(dates(plan) == [date(24, 10), date(25, 10), date(25, 21)])
        #expect(plan.map(\.id) == ["kd.signing.0", "kd.signing.1", "kd.signing.2"])
        #expect(plan.allSatisfy { $0.route == .signing && $0.body.contains("26 ноября 2026") && $0.body.contains("переустановите") })
    }

    @Test func signingOnTheDayAndPastDatesDropped() {
        let plan = ReminderPlan.signing(expiry: date(26, 18), now: date(25, 11), minutes: 600, calendar: calendar)
        #expect(dates(plan) == [date(26, 10)])
        #expect(ReminderPlan.signing(expiry: date(26, 18), now: date(27, 9), minutes: 600, calendar: calendar).isEmpty)
        #expect(ReminderPlan.signingSoon(expiry: date(26, 6), now: date(23, 7)))
        #expect(!ReminderPlan.signingSoon(expiry: date(26, 6), now: date(22, 7)))
        #expect(!ReminderPlan.signingSoon(expiry: nil, now: date(22, 7)))
    }

    @Test func backupOverdueAfterTwoWeeks() {
        let last = date(1, 15)
        #expect(!ReminderPlan.backupOverdue(last: last, now: date(15, 14), calendar: calendar))
        #expect(ReminderPlan.backupOverdue(last: last, now: date(15, 15), calendar: calendar))
        #expect(ReminderPlan.backupOverdue(last: nil, now: date(1, 0), calendar: calendar))
        #expect(ReminderPlan.backupMessage(last: last, at: date(19, 10), calendar: calendar) == "Резервной копии не было 18 дней. Сделайте копию, чтобы не потерять данные.")
        #expect(ReminderPlan.backupMessage(last: nil, at: date(19, 10), calendar: calendar).contains("ни разу"))
    }

    @Test func backupRemindersEveryTwoWeeksFromTheDueDay() {
        // Due 15 Nov 15:00; the chosen time 10:00 has passed that day, so the first one is 16 Nov, then every 14 days.
        let plan = ReminderPlan.backup(last: date(1, 15), now: date(5, 9), minutes: 600, calendar: calendar)
        #expect(dates(plan) == [date(16, 10), date(30, 10), date(14, 10, month: 12), date(28, 10, month: 12)])
        #expect(plan.map(\.id) == ["kd.backup.0", "kd.backup.1", "kd.backup.2", "kd.backup.3"])
        #expect(plan[0].body.hasPrefix("Резервной копии не было 15 дней"))
        #expect(plan[1].body.hasPrefix("Резервной копии не было 29 дней"))
    }

    @Test func overdueBackupStartsTodayOrTomorrow() {
        let today = ReminderPlan.backup(last: nil, now: date(20, 8), minutes: 600, calendar: calendar)
        #expect(dates(today).first == date(20, 10))
        let tomorrow = ReminderPlan.backup(last: nil, now: date(20, 11), minutes: 600, calendar: calendar)
        #expect(dates(tomorrow).first == date(21, 10))
        #expect(dates(tomorrow).allSatisfy { $0 > date(20, 11) })
    }

    @Test func fullPlanStaysUniqueAndSmall() {
        var settings = ReminderPlan.Settings()
        settings.charity = true
        let plan = ReminderPlan.all(settings, lastBackup: nil, expiry: date(26, 6, 4), now: date(20, 12), calendar: calendar)
        #expect(Set(plan.map(\.id)).count == plan.count)
        #expect(plan.count <= 64)
        #expect(plan.allSatisfy { $0.id.hasPrefix(ReminderPlan.prefix) })
        #expect(plan.filter { $0.route == .charity }.map(\.when) == [8, 12, 13].map { .monthly(day: $0, minutes: 720) })
        settings = ReminderPlan.Settings(backup: false, signing: false, charity: false)
        #expect(ReminderPlan.all(settings, lastBackup: nil, expiry: date(26, 6), now: date(20, 12), calendar: calendar).isEmpty)
    }

    @Test func russianDayWords() {
        #expect([1, 2, 5, 11, 21, 22, 25, 112].map(ReminderPlan.days) == ["1 день", "2 дня", "5 дней", "11 дней", "21 день", "22 дня", "25 дней", "112 дней"])
    }

    @Test func provisioningProfileExpiry() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>ExpirationDate</key><date>2026-11-26T12:04:05Z</date><key>Name</key><string>x</string></dict></plist>
        """
        // The real file wraps the plist in binary CMS data.
        let data = Data([0x30, 0x82, 0x00, 0xFF]) + Data(plist.utf8) + Data([0x00, 0xA0, 0x82])
        #expect(SigningProfile.parse(data) == ISO8601DateFormatter().date(from: "2026-11-26T12:04:05Z"))
        #expect(SigningProfile.parse(Data("garbage".utf8)) == nil)
    }
}
