import Foundation
import Testing
@testable import Balance

struct CapitalTests {
    @Test func euroRateFromCentralBankFeed() throws {
        let xml = """
        <ValCurs Date="19.11.2026"><Valute><CharCode>EUR</CharCode><Nominal>1</Nominal><Value>95,1234</Value></Valute>
        <Valute><Value>821,5</Value><CharCode>USD</CharCode><Nominal>10</Nominal></Valute></ValCurs>
        """
        let feed = try MarketPrices.rates(xml)
        #expect(feed.usd == Decimal(string: "82.15"))
        #expect(feed.eur == Decimal(string: "95.1234"))
        #expect(feed.date == "19.11.2026")
        // A broken euro entry must not block the dollar rate.
        let noEuro = try MarketPrices.rates(xml.replacingOccurrences(of: "95,1234", with: "abc"))
        #expect(noEuro.eur == nil && noEuro.usd == Decimal(string: "82.15"))
    }

    @Test func oldPriceCacheStillDecodes() throws {
        var prices = MarketPrices.initial
        prices.eur = nil
        let decoded = try JSONDecoder().decode(MarketPrices.self, from: JSONEncoder().encode(prices))
        #expect(decoded.eur == nil)
        #expect(decoded.needsCurrencyRefresh(at: .now))
    }

    @Test func conversionUsesCentralBankRate() {
        var prices = MarketPrices.initial
        prices.usd = 80
        prices.eur = 100
        #expect(DisplayCurrency.rub.amount(12_345, prices: prices) == Decimal(string: "123.45"))
        #expect(DisplayCurrency.usd.amount(800_000, prices: prices) == 100)
        #expect(DisplayCurrency.eur.amount(800_000, prices: prices) == 80)
        #expect(DisplayCurrency.usd.plotted(800_000, prices: prices) == 100)
        #expect(DisplayCurrency.selected("EUR", prices: prices) == .eur)
        prices.eur = nil
        #expect(DisplayCurrency.eur.amount(800_000, prices: prices) == nil)
        #expect(DisplayCurrency.eur.format(800_000, prices: prices) == "курс недоступен")
        // Without a euro rate the screen falls back to rubles.
        #expect(DisplayCurrency.selected("EUR", prices: prices) == .rub)
        #expect(DisplayCurrency.selected("XYZ", prices: prices) == .rub)
    }

    @Test func summaryGroupsAssetsAndRatios() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12)))
        func account(_ id: String, _ amount: Int64, debt: Bool = false) -> AccountBalance {
            AccountBalance(id: id, position: .init(title: id, amount: amount, debt: debt), cutoff: now)
        }
        func day(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))! }
        let accounts = [account("excel-20260901-0", 60_000), account(Holding.gold.id, 30_000),
                        account("receivable-x", 10_000), account("excel-20260901-10", 5_000),
                        account("excel-20260901-9", -5_000), account("loan-1", 20_000, debt: true)]
        let flows = [CashFlowRow(date: day(7, 10), cents: 999_999, income: false), // before the Aug–Oct window
                     CashFlowRow(date: day(9, 10), cents: 30_000, income: false),
                     CashFlowRow(date: day(10, 10), cents: 30_000, income: false),
                     CashFlowRow(date: day(11, 2), cents: 100_000, income: true),
                     CashFlowRow(date: day(11, 5), cents: 25_000, income: false)]
        let summary = CapitalSummary(accounts: accounts, months: [], monthEnds: [(day(9, 1), 50_000), (day(10, 1), 60_000)], flows: flows, now: now)
        #expect(summary.assets == 100_000)
        #expect(summary.debts == 20_000)
        #expect(summary.net == 80_000)
        #expect(summary.cash == 60_000)
        #expect(summary.slices.map(\.kind) == [.money, .investments, .loans, .property])
        #expect(summary.debtRatio == 0.2)
        #expect(summary.averageExpenses == 20_000) // 60 000 over three months
        #expect(summary.runway == 3)
        #expect(summary.savingsRate == 0.75)
        #expect(summary.history.map(\.title) == ["Сентябрь 2026", "Октябрь 2026", "Сейчас"])
        #expect(summary.change == 20_000)
        #expect(summary.growth?.since.title == "Сентябрь 2026")
        #expect(summary.liabilities.map(\.cents) == [20_000])
        #expect(CapitalSummary.shortMonth("Декабрь 2025") == "дек 25")
        #expect(CapitalSummary.monthStart("Декабрь 2025") != nil)
    }

    @Test func bridgeAddsUpToClosingCapital() throws {
        let values = PeriodValues(opening: 1_000_000, closing: 1_234_500, income: 500_000, expenses: 320_000, realized: -15_000, quotes: 42_000)
        let bridge = try #require(CapitalBridge(values))
        #expect(bridge.steps.map(\.title) == ["Капитал на начало", "Доходы", "Расходы", "Результат по партиям", "Переоценка", "Прочее и сверки", "Капитал на конец"])
        #expect(bridge.balanced)
        let items = bridge.steps.filter { !$0.total }.reduce(Int64(0)) { $0 + $1.delta }
        #expect(1_000_000 + items == 1_234_500)
        #expect(bridge.steps[2].delta == -320_000)
        #expect(bridge.steps[5].delta == 27_500) // balancing item
        // Archive periods without turnover have no bridge.
        #expect(CapitalBridge(PeriodValues(opening: 1, closing: 2, income: 0, expenses: 0, realized: 0, quotes: 0, incomplete: true)) == nil)
    }
}

struct GreetingTests {
    @Test func greetingByHour() {
        #expect(WelcomeScene.title(hour: 7, name: "Анна") == "Доброе утро, Анна")
        #expect(WelcomeScene.title(hour: 13, name: "Анна") == "Добрый день, Анна")
        #expect(WelcomeScene.title(hour: 19, name: "Анна") == "Добрый вечер, Анна")
        #expect(WelcomeScene.title(hour: 2, name: nil) == "Доброй ночи")
        #expect(WelcomeScene.title(hour: 2, name: "") == "Доброй ночи")
        #expect(WelcomeScene.at(hour: 9).title == WelcomeScene.title(hour: 9))
    }
}
