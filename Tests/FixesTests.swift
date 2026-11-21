import Foundation
import Testing
@testable import Balance

struct FixesTests {
    let october = BankRead.date("04.10.2026")!

    @Test func amountsFromSpreadsheetsAndJSON() throws {
        #expect(BankRead.cents("1,234.56") == 123456)
        #expect(BankRead.cents("-12,345,678.90") == 1234567890)
        #expect(BankRead.cents("1,23.45") == nil)
        #expect(WorkbookText.money("1234.5599999999999") == "1234.56")
        #expect(WorkbookText.money("-0.30000000000000004") == "-0.30")
        #expect(WorkbookText.money("1.5E1") == "15.00")
        #expect(WorkbookText.money("1.005") == nil)
        #expect(WorkbookText.money("1234.5") == nil)
        #expect(BankRead.date("2026-10-04T00:00:00") == october)
        let json = """
        {"rows":[{"date":"2026-10-04T12:30:00","amount":"100.00","direction":"expense","category":"","note":"аптека","currency":"RUR"},
                 {"date":"2026-10-04","amount":"5.00","direction":"expense","category":"Кафе","currency":null}]}
        """
        let rows = try BankJSON.read(json, source: "json")
        #expect(rows[0].cents == 10000 && rows[0].date != nil && rows[0].category == "Здоровье")
        #expect(rows[1].cents == nil)
    }

    @Test func purchasePostedNextDayIsSimilar() {
        let manual = Entry(cents: 50000, flow: .expense, category: "Продукты", note: "", date: october.addingTimeInterval(-600))
        manual.accountKey = "card"
        let bank = ImportLine(source: "s", ordinal: 0, original: "", date: october.addingTimeInterval(36_000), amount: "500,00",
                              flow: .expense, category: "Продукты", note: "", account: "card")
        let plan = ImportLedger.plan([bank], entries: [manual])
        #expect(plan.similar.contains(bank.id) && plan.additions.isEmpty)
    }

    @Test func reconciliationKeepsUntouchedAccounts() {
        let start = Date(timeIntervalSince1970: 0)
        let a = AccountBalance(id: "a", position: .init(title: "Карта", amount: 100, debt: false), cutoff: start)
        let b = AccountBalance(id: "b", position: .init(title: "Наличные", amount: 50, debt: false), cutoff: start)
        var changed = a; changed.position.amount = 90
        let added = AccountBalance(id: "new", position: .init(title: "Вклад", amount: 10, debt: false), cutoff: start)
        let rows = Reconciliation.changedRows([changed, b, added], from: [a, b])
        #expect(rows.map(\.id) == ["a", "new"])
    }

    @Test func lotMovementsCanBeChangedInOrder() {
        let lot = UUID(), first = UUID(), second = UUID()
        func movement(_ id: UUID, _ units: Int64, _ day: Double) -> LotMovement {
            LotMovement(id: id, lot: lot, date: Date(timeIntervalSince1970: day * 86_400), name: "Тест", goods: true, unit: "шт.",
                        asset: "asset", cash: "cash", units: units, gross: 100, fee: 0, cost: 100)
        }
        let buy = movement(lot, 3, 1)
        #expect(LotMovement.changeable(buy, in: [buy]))
        let saleOne = movement(first, -1, 2), saleTwo = movement(second, -1, 3)
        let all = [buy, saleOne, saleTwo]
        #expect(!LotMovement.changeable(buy, in: all))
        #expect(!LotMovement.changeable(saleOne, in: all))
        #expect(LotMovement.changeable(saleTwo, in: all))
    }

    @Test func closingMatchesByMonth() throws {
        let end = Charity.start(202611)
        let old = Closing(end: end, saved: .now, positions: [:], titles: [:], capital: 1, values: nil)
        #expect(old.monthKey == 202610)
        let stored = Closing(end: end.addingTimeInterval(-5 * 3600), saved: .now, positions: [:], titles: [:], capital: 1, values: nil, month: 202610)
        let decoded = try JSONDecoder().decode(Closing.self, from: JSONEncoder().encode(stored))
        #expect(decoded.monthKey == 202610)
    }
}
