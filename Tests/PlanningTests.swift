import Foundation
import Testing
@testable import Balance

struct PlanningTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
    private let prices = MarketPrices(gold: 5600, silver: 100, usd: Decimal(string: "80")!, metalsChecked: .now, currencyDate: "20.11.2026",
                                      eur: Decimal(string: "90"))

    @Test func monthlyScheduleKeepsTheDayOfMonth() {
        var rent = RecurringPayment(title: "Аренда", cents: 3_000_000, anchorDay: 31, next: day(2027, 1, 31))
        let feb = RecurringMath.advance(rent, from: rent.next, calendar: calendar)
        #expect(feb == day(2027, 2, 28))
        #expect(RecurringMath.advance(rent, from: feb, calendar: calendar) == day(2027, 3, 31))
        rent.every = 3
        #expect(RecurringMath.advance(rent, from: rent.next, calendar: calendar) == day(2027, 4, 30))
        var yearly = RecurringPayment(title: "Домен", unit: .year, anchorDay: 29, next: day(2028, 2, 29))
        #expect(RecurringMath.advance(yearly, from: yearly.next, calendar: calendar) == day(2029, 2, 28))
        yearly.unit = .week
        #expect(RecurringMath.advance(yearly, from: day(2026, 12, 1), calendar: calendar) == day(2026, 12, 8))
    }

    @Test func occurrencesRespectEndPauseAndInterval() {
        let december = RecurringMath.month(202612, calendar: calendar)
        var weekly = RecurringPayment(title: "Спортзал", cents: 50_000, unit: .week, next: day(2026, 12, 2))
        #expect(RecurringMath.occurrences(weekly, in: december, calendar: calendar).count == 5)
        weekly.end = day(2026, 12, 16)
        #expect(RecurringMath.occurrences(weekly, in: december, calendar: calendar).count == 3)
        weekly.active = false
        #expect(RecurringMath.occurrences(weekly, in: december, calendar: calendar).isEmpty)
        let quarterly = RecurringPayment(title: "Страховка", cents: 100, every: 3, anchorDay: 10, next: day(2026, 11, 10))
        #expect(RecurringMath.occurrences(quarterly, in: december, calendar: calendar).isEmpty)
        #expect(RecurringMath.occurrences(quarterly, in: RecurringMath.month(202702, calendar: calendar), calendar: calendar) == [day(2027, 2, 10)])
    }

    @Test func monthlyTotalsConvertCurrencies() {
        let list = [RecurringPayment(title: "Связь", cents: 105_000, anchorDay: 5, next: day(2026, 12, 5)),
                    RecurringPayment(title: "ChatGPT", cents: 2_000, currency: "USD", anchorDay: 20, next: day(2026, 11, 20)),
                    RecurringPayment(title: "Spotify", cents: 999, currency: "EUR", anchorDay: 1, next: day(2026, 12, 1))]
        #expect(RecurringMath.rub(list[1], prices: prices) == 160_000)
        #expect(RecurringMath.rub(list[2], prices: prices) == 89_910)
        let december = RecurringMath.total(list, in: RecurringMath.month(202612, calendar: calendar), prices: prices, calendar: calendar)
        #expect(december == 105_000 + 160_000 + 89_910)
        // On 19 November only the dollar payment on the 20th is still due this month.
        #expect(RecurringMath.remainingThisMonth(list, now: day(2026, 11, 19), prices: prices, calendar: calendar) == 160_000)
        let due = [RecurringDue(id: "x", title: "Связь", amount: "1 050 ₽", due: day(2026, 12, 5))]
        let plan = ReminderPlan.recurring(due, now: day(2026, 12, 1), minutes: 600, calendar: calendar)
        #expect(plan.map(\.id) == ["kd.reg.x.1", "kd.reg.x.0"] && plan.allSatisfy { $0.route == .recurring })
        #expect(plan.map(\.when) == [.date(calendar.date(from: DateComponents(year: 2026, month: 12, day: 4, hour: 10))!),
                                     .date(calendar.date(from: DateComponents(year: 2026, month: 12, day: 5, hour: 10))!)])
    }

    @Test @MainActor func budgetPlanAgainstActual() {
        func spend(_ rub: Int64, _ category: String, _ date: Date, token: String? = nil) -> Entry {
            let e = Entry(cents: rub * 100, flow: .expense, category: category, note: "", date: date); e.importToken = token; return e
        }
        let entries = [spend(10_000, "Кафе", day(2026, 11, 3)), spend(2_345, "Кафе", day(2026, 11, 9)), spend(500, "Транспорт", day(2026, 11, 4)),
                       spend(8_000, Charity.category, day(2026, 11, 5)), spend(1_050, "Связь", day(2026, 11, 5), token: "recurring:abc"),
                       spend(4_000, "Кафе", day(2026, 12, 2))]
        #expect(BudgetMath.actual(entries, month: 202611) == ["Кафе": 1_234_500, "Транспорт": 50_000])
        #expect(BudgetMath.suggestion(entries, from: 202611) == ["Кафе": 1_240_000, "Транспорт": 50_000])
        #expect(BudgetMath.level(limit: 1_000_000, actual: 790_000) == .ok)
        #expect(BudgetMath.level(limit: 1_000_000, actual: 800_000) == .warning)
        #expect(BudgetMath.level(limit: 1_000_000, actual: 1_000_001) == .over)
        #expect(BudgetMath.perDay(remaining: 3_100_000, month: 202612, now: day(2026, 11, 20), calendar: calendar) == 100_000)
        #expect(BudgetMath.perDay(remaining: 1_000_000, month: 202612, now: day(2026, 12, 22), calendar: calendar) == 100_000)
        #expect(BudgetMath.perDay(remaining: 1, month: 202610, now: day(2026, 12, 22), calendar: calendar) == nil)
        #expect(BudgetMath.next(202612) == 202701 && BudgetMath.next(202601, by: -1) == 202512)

        let salary = IncomePlan(); salary.type = IncomeKind.salary.rawValue; salary.amount = 0; salary.monthly = true; salary.payout = day(2026, 11, 28)
        let budget = MonthBudget(month: 202612, limits: ["Кафе": 1_500_000, "Транспорт": 500_000])
        let plan = BudgetMath.plan(month: 202612, budget: budget, entries: entries, plans: [salary],
                                   recurring: [RecurringPayment(title: "Связь", cents: 105_000, anchorDay: 5, next: day(2026, 12, 5))],
                                   payments: ResetSeed.payments(Fixture.start), projects: [ResetSeed.project(Fixture.start)!], prices: prices, calendar: calendar)
        #expect(plan.incomeMissing && plan.income == 0)
        #expect(plan.regular == 105_000)
        #expect(plan.cards.map(\.1) == [400_025]) // only the card payment due in December
        #expect(plan.coffee == 300_000 && plan.limits == 2_000_000)
        #expect(plan.spendingPlan == 105_000 + 400_025 + 300_000 + plan.charity + 2_000_000)
        #expect(plan.balance == -plan.spendingPlan)
    }
}

struct AccountKindTests {
    @Test func onlyCardsForRegularPayments() {
        func account(_ id: String, _ title: String, debt: Bool = false) -> AccountBalance {
            AccountBalance(id: id, position: .init(title: title, amount: 1, debt: debt), cutoff: .now)
        }
        let cards = [account("excel-20260901-1", "Банк A, дебетовая"), account("excel-20260901-6", "Карта B · $50"),
                     account("excel-20260901-4", "Биржа (карта, USD)"), account("excel-20260901-15", "Банк C Platinum ••0000", debt: true),
                     account("excel-20260901-16", "Банк D кредитка", debt: true)]
        let others = [account("excel-20260901-0", "Наличные (рубли)"), account("excel-20260901-5", "Накопительный счёт 10%"),
                      account(ResetSeed.coffeeKey, "Проект"), account(Holding.gold.id, "Золото"), account("excel-20260901-12", "Друг 1"),
                      account("receivable-x", "Друг 2"), account("loan-x", "Кредит на машину", debt: true), account("excel-20260901-10", "Часы")]
        #expect(cards.allSatisfy(AccountKind.isCard))
        #expect(!others.contains(where: AccountKind.isCard))
    }
}
