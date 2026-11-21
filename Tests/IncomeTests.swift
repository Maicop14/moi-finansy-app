import XCTest
import SwiftData
@testable import Balance

final class IncomeTests: XCTestCase {
    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        IncomeMath.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
    func testBankExemptionWhenRateChanges() {
        XCTAssertEqual(IncomeMath.bankMode("lowRate", atRateBP: 100), "lowRate")
        XCTAssertEqual(IncomeMath.bankMode("lowRate", atRateBP: 101), "regular")
        XCTAssertEqual(IncomeMath.bankMode("legacyBank", atRateBP: 101), "regular")
        XCTAssertEqual(IncomeMath.bankMode("escrow", atRateBP: 101), "escrow")
    }

    @MainActor func testExistingIncomeDatabaseStillOpens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfiguration(url: directory.appendingPathComponent("audit.store"), cloudKitDatabase: .none)
        do {
            let prior = try ModelContainer(for: PriorIncomeSchema.IncomePlan.self, configurations: config)
            let deposit = PriorIncomeSchema.IncomePlan()
            deposit.title = "Тестовый вклад"
            deposit.type = IncomeKind.deposit.rawValue
            deposit.amount = 123_45
            deposit.rateBP = 100
            deposit.exempt = true
            prior.mainContext.insert(deposit)
            try prior.mainContext.save()
        }
        let next = try ModelContainer(for: IncomePlan.self, configurations: config)
        let records = try next.mainContext.fetch(FetchDescriptor<IncomePlan>())
        XCTAssertEqual(records.count, 1)
        let migrated = try XCTUnwrap(records.first)
        XCTAssertEqual(migrated.amount, 123_45)
        XCTAssertEqual(migrated.kind, .deposit)
        XCTAssertTrue(migrated.exempt)
        XCTAssertNil(migrated.bankExemptionReason)
    }

    func testBracketsAndRubleRounding() {
        for (rub, tax): (Int64, Int64) in [(2_400_000,312_000),(2_500_000,327_000),(5_000_000,702_000),(20_000_000,3_402_000),(50_000_000,9_402_000),(51_000_000,9_622_000)] {
            XCTAssertEqual(IncomeMath.tax(rub * 100), tax * 100)
        }
        XCTAssertEqual(IncomeMath.tax(499),100)
        XCTAssertEqual(IncomeMath.tax(384),0)
    }
    func testInterestAcrossLeapYearAndMonthlySalary() {
        XCTAssertEqual(IncomeMath.interest(10_000_000, 1200, date(2025,12,31), date(2026,12,31)),1_200_000)
        XCTAssertEqual(IncomeMath.interest(10_000_000, 1200, date(2023,12,30), date(2024,1,1)),6566)
        let salary = IncomePlan()
        salary.type = IncomeKind.salary.rawValue; salary.monthly = true; salary.amount = 10_000_000
        salary.payout = date(2026,11,15)
        XCTAssertEqual(salary.gross,20_000_000)
    }
    func testSharedAllowanceAndSeparateBases() {
        func deposit(_ bp: Int) -> IncomePlan {
            let plan = IncomePlan()
            plan.type = IncomeKind.deposit.rawValue; plan.amount = 100_000_000
            plan.rateBP = bp; plan.start = date(2025,12,31); plan.payout = date(2026,12,31)
            return plan
        }
        let low = deposit(100); low.exempt = true
        let escrow = deposit(1000); escrow.exempt = true
        let salary = IncomePlan(); salary.amount = 250_000_000; salary.type = IncomeKind.salary.rawValue
        let totals = IncomeMath.annual([salary,deposit(1200),deposit(1000),low,escrow], keyBP: 1600)
        XCTAssertEqual(totals.passiveTax,780_000)
        XCTAssertEqual(totals.regularTax,32_700_000)
        XCTAssertEqual(totals.gross,283_000_000)
    }
}

// Entity layout of the previously shipped IncomePlan. Keep this historical
// fixture stable so the test really opens an older on-disk store.
private enum PriorIncomeSchema {
    @Model final class IncomePlan {
        var title = ""
        var type = ""
        var amount: Int64 = 0
        var rateBP = 0
        var start = Date()
        var payout = Date()
        var monthly = false
        var exempt = false
        var passive = false
        init() {}
    }
}
