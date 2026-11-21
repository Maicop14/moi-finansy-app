import XCTest
@testable import Balance

final class CharityTests: XCTestCase {
    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Charity.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
    func entry(_ month: Int, _ flow: Flow, _ category: String, _ rub: Int64) -> Entry {
        Entry(cents: rub * 100, flow: flow, category: category, note: "", date: date(2026, month, 10))
    }
    func testSalaryProfitAndDecemberPayment() {
        var rows = [entry(11,.income,"Зарплата",100000),entry(11,.income,"Чистая прибыль от торговли",30000),entry(11,.expense,"Продукты",40000),entry(11,.income,"Рост золота",10000),entry(11,.transfer,"Перевод",60000)]
        XCTAssertEqual(Charity.report(rows, at: date(2026,12,15)).upcoming.assessment,900000)
        let paid = entry(12,.expense,Charity.category,9000)
        paid.charityMonth = 202611
        rows += [entry(12,.income,"Зарплата",50000),paid]
        let jan = Charity.report(rows, at: date(2027,1,15))
        XCTAssertEqual(jan.upcoming.assessment,410000)
        XCTAssertEqual(jan.history.first?.remaining,0)
        XCTAssertEqual(jan.upcoming.due,date(2027,1,15))
    }
    func testDeficitPartialAndArrears() {
        let partial = entry(3,.expense,Charity.category,3000)
        partial.charityMonth = 202602
        let rows = [entry(1,.expense,"Кафе",20000),entry(2,.income,"Зарплата",50000),partial]
        let due = Charity.report(rows, at: date(2026,3,15))
        XCTAssertEqual(due.upcoming.remaining,200000)
        XCTAssertEqual(due.history.first?.assessment,0)
        let after = Charity.report(rows, at: date(2026,3,16))
        XCTAssertEqual(after.upcoming.id,202603)
        XCTAssertEqual(after.history.first?.remaining,200000)
    }
    func testRoundingAndImportedUnallocated() {
        let wage = entry(3,.income,"Подарки",50)
        wage.charityIncluded = true; wage.cents = 125
        let paid = entry(4,.expense,Charity.category,1)
        let rows = [wage,paid]
        XCTAssertEqual(Charity.report(rows, at: date(2026,4,15)).upcoming.remaining,13)
        paid.charityMonth = 202603
        XCTAssertEqual(Charity.report(rows, at: date(2026,4,15)).upcoming.remaining,0)
        XCTAssertEqual(Charity.report(rows, at: date(2026,5,15)).upcoming.expenses,100)
    }
}
