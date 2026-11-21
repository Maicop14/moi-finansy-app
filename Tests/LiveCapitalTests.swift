import Foundation
import SwiftData
import Testing
@testable import Balance

struct LiveCapitalTests {
    private func prices(gold: Decimal, usd: String) -> MarketPrices {
        MarketPrices(gold: gold, silver: 100, usd: Decimal(string: usd)!, metalsChecked: .now, currencyDate: "21.11.2026", eur: 90)
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "live-" + UUID().uuidString)! }

    @Test func metalsAndDollarCardsFollowQuotes() throws {
        let d = defaults()
        d.set("10", forKey: "quantity." + Holding.gold.id)
        d.set("20", forKey: "quantity." + Holding.silver.id)
        d.set(try JSONEncoder().encode([ResetSeed.key(4): ForeignHolding(currency: "USD", units: 5_000, rate: 80)]),
              forKey: LiveCapital.foreignKey)
        let start = Date(timeIntervalSince1970: 0)
        let list = [AccountBalance(id: Holding.gold.id, position: .init(title: "Золото", amount: 1, debt: false), cutoff: start),
                    AccountBalance(id: Holding.silver.id, position: .init(title: "Серебро", amount: 1, debt: false), cutoff: start),
                    AccountBalance(id: ResetSeed.key(4), position: .init(title: "Валютная карта", amount: 400_000 - 10_000, debt: false), cutoff: start),
                    AccountBalance(id: ResetSeed.key(0), position: .init(title: "Наличные", amount: 550_000, debt: false), cutoff: start)]
        let before = LiveCapital.apply(list, prices: prices(gold: 5_500, usd: "80"), defaults: d)
        #expect(before[0].position.amount == 5_650_000) // 10 г × (5 500 + 150)
        #expect(before[1].position.amount == 180_000)  // 20 г × 100 × 0,9
        #expect(before[2].position.amount == 390_000)    // same rate: the balance (after a 100 ₽ purchase) stays as entered
        #expect(before[3].position.amount == 550_000)
        let after = LiveCapital.apply(list, prices: prices(gold: 5_600, usd: "83"), defaults: d)
        #expect(after[0].position.amount == 5_750_000)  // gold up: net worth up by the gram difference
        #expect(after[2].position.amount == 404_625)     // 3 900 ₽ = $48,75 at 80 → $48,75 × 83
        // Lots bought later add to the grams.
        let lot = LotMovement(id: UUID(), lot: UUID(), date: .now, name: "Слиток", goods: false, unit: "г", asset: Holding.gold.id, cash: "", units: 1_000_000,
                              gross: 0, fee: 0, cost: 0)
        #expect(LiveCapital.apply(list, prices: prices(gold: 5_600, usd: "83"), defaults: d, lots: [lot])[0].position.amount == 6_325_000)
    }

    @Test func dailyAndBaselineChanges() {
        let d = defaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        func at(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))! }
        NetWorthHistory.record(1_000_000, at: at(21, 9), defaults: d, calendar: calendar)
        NetWorthHistory.record(1_050_000, at: at(21, 18), defaults: d, calendar: calendar)
        // First day: compared with the morning value.
        #expect(NetWorthHistory.daily(1_050_000, now: at(21, 18), defaults: d, calendar: calendar)?.cents == 50_000)
        NetWorthHistory.record(1_038_333, at: at(22, 10), defaults: d, calendar: calendar)
        let day = NetWorthHistory.daily(1_038_333, now: at(22, 10), defaults: d, calendar: calendar)
        #expect(day?.cents == -11_667) // against the last value of the 21st
        #expect(abs((day?.share ?? 0) + 0.011_111) < 0.000_01)
        let since = NetWorthHistory.sinceBaseline(1_038_333, defaults: d)
        #expect(since?.cents == 38_333) // against the first value of 21 November
        #expect(NetWorthHistory.days(d).count == 2)
    }

    @Test func importCountsOnlyNewOperations() {
        let cutoff = Date.now.addingTimeInterval(-6 * 86_400) // opening balances, a few days ago
        func row(_ n: Int, _ amount: String, _ date: Date, source: String = "tbank-1.csv", note: String = "Пятёрочка") -> ImportLine {
            ImportLine(source: source, ordinal: n, original: note, date: date, amount: amount, flow: .expense, category: "Продукты", note: note, account: "card")
        }
        let oldRow = row(0, "500,00", cutoff.addingTimeInterval(-3 * 86_400))
        let newRow = row(1, "360,00", cutoff.addingTimeInterval(86_400))
        let first = ImportLedger.plan([oldRow, newRow], entries: [], cutoffs: ["card": cutoff])
        #expect(first.additions.map(\.0.id) == [newRow.id])
        #expect(first.beforeCutoff == [oldRow.id])
        // Saved, then the same file again: nothing new.
        let saved = Entry(cents: 36_000, flow: .expense, category: "Продукты", note: "Пятёрочка", date: newRow.date!)
        saved.accountKey = "card"; saved.importAccount = "card"; saved.importToken = newRow.token
        let again = ImportLedger.plan([row(0, "500,00", oldRow.date!), row(1, "360,00", newRow.date!)], entries: [saved], cutoffs: ["card": cutoff])
        #expect(again.additions.isEmpty && again.skipped.count == 2)
        // An overlapping later file: the known purchase is skipped, only the new one is added.
        let next = [row(0, "360,00", newRow.date!, source: "tbank-2.csv"), row(1, "1 200,00", cutoff.addingTimeInterval(2 * 86_400), source: "tbank-2.csv", note: "ВкусВилл")]
        let overlap = ImportLedger.plan(next, entries: [saved], cutoffs: ["card": cutoff])
        #expect(overlap.additions.map(\.1) == [120_000])
        // A purchase entered by hand, then the bank row the next day: skipped as the same operation.
        let manual = Entry(cents: 57_000, flow: .expense, category: "Кафе", note: "кофе", date: cutoff.addingTimeInterval(3 * 86_400))
        manual.accountKey = "card"
        let bank = row(5, "570,00", cutoff.addingTimeInterval(3 * 86_400 + 40_000), source: "tbank-3.csv", note: "Факультет кофе")
        #expect(ImportLedger.plan([bank], entries: [manual], cutoffs: ["card": cutoff]).additions.isEmpty)
        // Old rows can still be added on purpose, for reports only.
        var forced = oldRow; forced.includeBeforeCutoff = true
        #expect(ImportLedger.plan([forced], entries: [], cutoffs: ["card": cutoff]).additions.count == 1)
    }
}

struct QuoteScheduleTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "quotes-" + UUID().uuidString)! }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Moscow")!; return c }
    private func at(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))! }

    @Test func onceADay() {
        let d = defaults()
        #expect(QuoteSchedule.due(now: at(21, 9), defaults: d, calendar: calendar))
        QuoteSchedule.done(now: at(21, 9), defaults: d, calendar: calendar)
        #expect(!QuoteSchedule.due(now: at(21, 23), defaults: d, calendar: calendar))
        #expect(QuoteSchedule.due(now: at(22, 0), defaults: d, calendar: calendar))
    }

    @Test func notesSaySourceByName() {
        let prices = MarketPrices(gold: 5600, silver: 100, usd: 82, metalsChecked: at(20, 21), currencyDate: "21.11.2026")
        #expect(QuoteSchedule.note(prices, failed: [], at: at(21, 15)).hasPrefix("Котировки обновлены сегодня"))
        let metals = QuoteSchedule.note(prices, failed: [.init(source: "Регион Золото", offline: false)], at: at(21, 15))
        #expect(metals.contains("Курс ЦБ обновлён") && metals.contains("Регион Золото не ответил") && !metals.contains("Нет интернета"))
        #expect(QuoteSchedule.note(prices, failed: [.init(source: "ЦБ РФ", offline: false)], at: at(21, 15)).contains("ЦБ не ответил"))
        #expect(QuoteSchedule.note(prices, failed: [.init(source: "Регион Золото", offline: true), .init(source: "ЦБ РФ", offline: true)], at: at(21, 15)).hasPrefix("Нет интернета"))
        #expect(QuoteSchedule.note(prices, failed: [.init(source: "Регион Золото", offline: false), .init(source: "ЦБ РФ", offline: false)], at: at(21, 15)).hasPrefix("Источники котировок не ответили"))
    }
}

struct QuoteFallbackTests {
    @Test func mirrorAndWorldParsing() throws {
        let mirror = #"{"Date":"2026-11-21T11:30:00+03:00","Valute":{"USD":{"Nominal":1,"Value":82.1911},"EUR":{"Nominal":1,"Value":90.3445},"CNY":{"Nominal":10,"Value":113.5}}}"#
        let feed = try QuoteFallback.mirrorRates(Data(mirror.utf8))
        #expect(feed.usd == Decimal(string: "82.1911") && feed.eur == Decimal(string: "90.3445") && feed.date == "21.11.2026")
        #expect(throws: (any Error).self) { try QuoteFallback.mirrorRates(Data("<html>blocked</html>".utf8)) }
        let gold = try QuoteFallback.worldPrice(Data(#"{"currency":"USD","name":"Gold","price":3539.0,"symbol":"XAU"}"#.utf8))
        #expect(gold == 3539)
        #expect(throws: (any Error).self) { try QuoteFallback.worldPrice(Data(#"{"currency":"EUR","price":1}"#.utf8)) }
    }

    @Test func worldPriceMatchesRegionZoloto() {
        // 21.11.2026: Регион Золото 5 314 ₽/г (585 опт) and 92 ₽/г (999); world $3 539 and $41,08 per ounce, $ = 82,1911.
        let usd = Decimal(string: "82.1911")!, gold = Decimal(3539), silver = Decimal(string: "41.080002")!
        let (g, s) = QuoteFallback.regional(gold: gold, silver: silver, usd: usd, calibration: .init())
        #expect(abs(NSDecimalNumber(decimal: g - 5314).doubleValue) <= 2)
        #expect(abs(NSDecimalNumber(decimal: s - 92).doubleValue) <= 1)
        let learned = QuoteFallback.learn(regionGold: 5314, regionSilver: 92, gold: gold, silver: silver, usd: usd)
        #expect(abs(learned.gold - 0.9713) < 0.001 && abs(learned.silver - 0.8475) < 0.001)
        // A broken page cannot teach a wild ratio.
        #expect(QuoteFallback.learn(regionGold: 50, regionSilver: 92, gold: gold, silver: silver, usd: usd).gold == QuoteFallback.Calibration().gold)
    }

    @Test func worldSourceIsNamedInTheNote() {
        var prices = MarketPrices(gold: 5314, silver: 92, usd: 82, metalsChecked: .now, currencyDate: "21.11.2026")
        prices.metalsSource = "мировая цена"
        #expect(QuoteSchedule.note(prices, failed: [], at: .now).contains("по мировой цене"))
        // Older caches without the field still decode.
        let old = #"{"gold":5484,"silver":97,"usd":81.9,"metalsChecked":0,"currencyDate":"20.11.2026"}"#
        #expect((try? JSONDecoder().decode(MarketPrices.self, from: Data(old.utf8)))?.metalsSource == nil)
    }
}

struct NetWorthFreshnessTests {
    @Test func staleMorningValueIsReplaced() throws {
        let d = UserDefaults(suiteName: "fresh-" + UUID().uuidString)!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 9))!
        NetWorthHistory.record(1_014_500, at: morning, fresh: false, defaults: d, calendar: calendar)   // old gold price
        NetWorthHistory.record(1_000_000, at: morning.addingTimeInterval(600), fresh: true, defaults: d, calendar: calendar)
        NetWorthHistory.record(1_002_000, at: morning.addingTimeInterval(3600), fresh: true, defaults: d, calendar: calendar)
        let day = try #require(NetWorthHistory.days(d)["2026-11-21"])
        #expect(day.first == 1_000_000 && day.last == 1_002_000 && day.fresh == true)
        #expect(NetWorthHistory.sinceBaseline(1_002_000, defaults: d)?.cents == 2_000)
        // Entries saved by the previous version (no flag) are fixed the same way.
        d.set(Data(#"{"2026-11-21":{"first":1014500,"last":1000000}}"#.utf8), forKey: NetWorthHistory.storageKey)
        NetWorthHistory.record(1_000_000, at: morning.addingTimeInterval(7200), fresh: true, defaults: d, calendar: calendar)
        #expect(NetWorthHistory.days(d)["2026-11-21"]?.first == 1_000_000)
    }
}

struct ImportSaveCutoffTests {
    /// The preview and the save must agree: old rows are skipped on save too, and saving succeeds.
    @Test @MainActor func saveSkipsRowsBeforeTheBalances() throws {
        let db = try ModelContainer(for: Entry.self, Checkpoint.self, StatementSource.self,
                                    configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let cutoff = Date.now.addingTimeInterval(-5 * 86_400)
        let doc = BankDocument(name: "Выписка.csv", bytes: Data("выписка".utf8))
        func row(_ n: Int, _ amount: String, _ date: Date) -> ImportLine {
            ImportLine(source: doc.digest, ordinal: n, original: "", date: date, amount: amount, flow: .expense, category: "Продукты", note: "Магазин", account: "card")
        }
        let rows = [row(0, "100,00", cutoff.addingTimeInterval(-86_400)), row(1, "250,00", cutoff.addingTimeInterval(86_400))]
        let preview = ImportLedger.plan(rows, entries: [], cutoffs: ["card": cutoff])
        #expect(try ImportLedger.save(rows: rows, documents: [doc], container: db, expected: preview, cutoffs: ["card": cutoff]) == 1)
        let saved = try ModelContext(db).fetch(FetchDescriptor<Entry>())
        #expect(saved.map(\.cents) == [25_000])
        // Same file again: nothing new.
        #expect(try ImportLedger.save(rows: rows, documents: [doc], container: db, cutoffs: ["card": cutoff]) == 0)
    }
}

struct NotificationPrivacyTests {
    /// Nothing on the locked screen reveals an amount.
    @Test func noAmountsInReminderTexts() {
        let due = Date.now.addingTimeInterval(10 * 86_400)
        let payments = ReminderPlan.payments([PaymentDue(id: "a", title: "Карта", amount: 25_939_700, minimum: 267_649, due: due)],
                                             now: .now, minutes: 600, calendar: .current)
        let regular = ReminderPlan.recurring([RecurringDue(id: "r", title: "Связь", amount: "1 050 ₽", due: due)], now: .now, minutes: 600, calendar: .current)
        for item in payments + regular {
            #expect(!(item.title + item.body).contains(where: \.isNumber) || !(item.title + item.body).contains("₽"), "\(item.body)")
            #expect(!item.body.contains("₽") && !item.body.contains("259") && !item.body.contains("1 050"))
        }
        #expect(payments.first?.body.contains("минимальный платёж") == true)
    }
}

struct BackupSettingsTests {
    @Test func copyCarriesServiceData() {
        let source = UserDefaults(suiteName: "copy-src-" + UUID().uuidString)!
        for key in CopySettings.dataExtra { source.set(Data(key.utf8), forKey: key) }
        source.set(Data("p".utf8), forKey: "markets.prices")
        let copy = CopySettings(source)
        let target = UserDefaults(suiteName: "copy-dst-" + UUID().uuidString)!
        copy.apply(target)
        for key in CopySettings.dataExtra { #expect(target.data(forKey: key) == Data(key.utf8), "\(key)") }
        // An older copy without these keys leaves what the device already has.
        let older = CopySettings(UserDefaults(suiteName: "copy-old-" + UUID().uuidString)!)
        older.apply(target)
        #expect(target.data(forKey: NetWorthHistory.storageKey) == Data(NetWorthHistory.storageKey.utf8))
    }
}

struct NetWorthMonthEndsTests {
    @Test func lastValueOfEachCompletedMonth() {
        let d = UserDefaults(suiteName: "ends-" + UUID().uuidString)!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        func at(_ m: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: m, day: day, hour: 12))! }
        NetWorthHistory.record(100, at: at(11, 21), defaults: d, calendar: calendar)
        NetWorthHistory.record(120, at: at(11, 29), defaults: d, calendar: calendar)
        NetWorthHistory.record(130, at: at(12, 3), defaults: d, calendar: calendar)
        let ends = NetWorthHistory.monthEnds(now: at(12, 5), defaults: d, calendar: calendar)
        #expect(ends.map(\.cents) == [120]) // November closes at its last value; December is still "now"
        #expect(ends.first?.month == calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
    }
}

struct ForeignSyncTests {
    @Test func reconciliationReanchorsTheRate() throws {
        let d = UserDefaults(suiteName: "fx-" + UUID().uuidString)!
        let first = Date(timeIntervalSince1970: 1_000), later = Date(timeIntervalSince1970: 9_000)
        d.set(try JSONEncoder().encode(["card": ForeignHolding(currency: "USD", units: 5_000, rate: 80)]), forKey: LiveCapital.foreignKey)
        let prices = MarketPrices(gold: 1, silver: 1, usd: 90, metalsChecked: .now, currencyDate: "")
        let account = AccountBalance(id: "card", position: .init(title: "Карта", amount: 400_000, debt: false), cutoff: first)
        LiveCapital.sync([account], prices: prices, defaults: d)
        #expect(LiveCapital.foreign(d)["card"]?.since == first && LiveCapital.foreign(d)["card"]?.rate == 80)
        #expect(LiveCapital.apply([account], prices: prices, defaults: d)[0].position.amount == 450_000) // $50 × 90
        // A new reconciliation in rubles at today's rate: no second revaluation.
        let reconciled = AccountBalance(id: "card", position: .init(title: "Карта", amount: 540_000, debt: false), cutoff: later)
        LiveCapital.sync([reconciled], prices: prices, defaults: d)
        #expect(LiveCapital.foreign(d)["card"]?.rate == 90)
        #expect(LiveCapital.apply([reconciled], prices: prices, defaults: d)[0].position.amount == 540_000)
    }
}

struct DailyTitleTests {
    @Test func titleSaysSinceWhenDaysWereSkipped() {
        let d = UserDefaults(suiteName: "title-" + UUID().uuidString)!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        func at(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))! }
        NetWorthHistory.record(100, at: at(18), defaults: d, calendar: calendar)
        let afterGap = NetWorthHistory.daily(110, now: at(21), defaults: d, calendar: calendar)
        #expect(NetWorthHistory.dailyTitle(afterGap, now: at(21), calendar: calendar) == "с 18 ноября")
        NetWorthHistory.record(110, at: at(21), defaults: d, calendar: calendar)
        let nextDay = NetWorthHistory.daily(115, now: at(22), defaults: d, calendar: calendar)
        #expect(NetWorthHistory.dailyTitle(nextDay, now: at(22), calendar: calendar) == "за день")
    }
}

struct BudgetNextYearTests {
    @Test @MainActor func monthlySalaryContinuesIntoJanuary() {
        let salary = IncomePlan(); salary.type = IncomeKind.salary.rawValue; salary.amount = 10_000_000; salary.monthly = true
        salary.payout = Charity.calendar.date(from: DateComponents(year: 2026, month: 11, day: 28))!
        #expect(BudgetMath.income([salary], month: 202701).0 == 10_000_000)
        #expect(BudgetMath.income([salary], month: 202610).0 == 0)
    }
}
