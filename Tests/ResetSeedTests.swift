import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import Balance

/// Fictional fresh-start data with the same shape as the owner's local file.
enum Fixture {
    static var start: FreshStart {
        FreshStart.load(Bundle.module.url(forResource: "fresh-start", withExtension: "json", subdirectory: "Fixtures"))!
    }
}

@MainActor struct ResetSeedTests {
    private let prices = MarketPrices(gold: 5600, silver: 100, usd: Decimal(string: "80")!,
                                      metalsChecked: .now, currencyDate: "20.11.2026")
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Moscow")!; return c }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 9))! }

    private func seeded(at moment: Date? = nil) throws -> (ModelContext, UserDefaults) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Entry.self, Checkpoint.self, StatementSource.self, IncomePlan.self, BackupInstall.self, FinanceRecord.self,
                                           configurations: config)
        let context = ModelContext(container)
        let defaults = UserDefaults(suiteName: "reset-seed-" + UUID().uuidString)!
        defaults.set(try JSONEncoder().encode(prices), forKey: "markets.prices")
        // Leftovers that the fresh start must remove.
        context.insert(Entry(cents: 100, flow: .expense, category: "Кафе", note: "", date: now.addingTimeInterval(-86_400)))
        context.insert(Checkpoint(position: .init(title: "Старое", amount: 1, debt: false), key: "excel-20260901-7", date: now.addingTimeInterval(-86_400)))
        try context.save()
        try ResetSeed.applyIfNeeded(context, defaults: defaults, now: moment ?? now, start: Fixture.start)
        return (context, defaults)
    }
    /// Net worth; `only` limits it to the accounts the fixture sets (others come from the bundled archive).
    private func net(_ context: ModelContext, only: Set<String>? = nil) throws -> Int64 {
        let list = balances(archive: try #require(Archive.bundled), checkpoints: try context.fetch(FetchDescriptor<Checkpoint>()),
                            entries: try context.fetch(FetchDescriptor<Entry>())).filter { only?.contains($0.id) ?? true }
        return list.reduce(0) { $0 + ($1.position.debt ? -$1.position.amount : $1.position.amount) }
    }

    @Test func balancesComeFromTheFile() throws {
        let (context, _) = try seeded()
        let gold = try #require(prices.valuation(of: .gold, quantity: "10"))     // 10 г × (5 600 + 150)
        let silver = try #require(prices.valuation(of: .silver, quantity: "20")) // 20 г × 100 × 0,9
        #expect(gold == 5_750_000 && silver == 180_000)
        // 10 000 + 2 500,50 + $50 × 80 + metals + 12 000 + 5 000 + 1 500 − 30 000 − 4 000,25
        let seededKeys = Set(Fixture.start.accounts.map(\.key))
        let fromFile = try net(context, only: seededKeys)
        #expect(fromFile == 1_000_000 + 250_050 + 400_000 + gold + silver + 1_200_000 + 500_000 + 150_000 - 3_000_000 - 400_025)
        let marks = try context.fetch(FetchDescriptor<Checkpoint>())
        #expect(marks.allSatisfy { $0.title != "Старое" && $0.date == now })
        #expect(marks.first { $0.key == ResetSeed.coffeeKey }?.amount == 1_200_000)
        #expect(AssetClass.of(AccountBalance(id: ResetSeed.coffeeKey, position: .init(title: "", amount: 1, debt: false), cutoff: now)) == .money)
    }

    @Test func historyIsWipedAndSettingsSet() throws {
        let (context, defaults) = try seeded()
        let entries = try context.fetch(FetchDescriptor<Entry>())
        #expect(entries.count == 1 && entries[0].category == Charity.category && entries[0].cents == 100_000 && entries[0].charityMonth == 202610)
        #expect(entries[0].date < now)
        let plans = try context.fetch(FetchDescriptor<IncomePlan>())
        #expect(plans.count == 3 && plans.first { $0.kind == .salary }?.monthly == true)
        #expect(plans.first { $0.kind == .other }?.gross == 15_040)
        #expect(plans.first { $0.kind == .savings }?.rateBP == 1050)
        let records = try context.fetch(FetchDescriptor<FinanceRecord>())
        #expect(ProjectStore.projects(records).first?.total == 1_200_000)
        #expect(defaults.string(forKey: "quantity." + Holding.gold.id) == "10")
        #expect(try JSONDecoder().decode([String].self, from: defaults.data(forKey: "accounts.hidden")!) == Fixture.start.hidden)
        #expect(try JSONDecoder().decode([PaymentDue].self, from: defaults.data(forKey: PaymentDue.storageKey)!).count == 2)
        #expect(LiveCapital.foreign(defaults)[ResetSeed.key(4)] == ForeignHolding(currency: "USD", units: 5_000, rate: 80))
        // Runs only once: a second call keeps what the owner entered afterwards.
        context.insert(Entry(cents: 500, flow: .expense, category: "Кафе", note: "", date: now))
        try context.save()
        try ResetSeed.applyIfNeeded(context, defaults: defaults, now: now, start: Fixture.start)
        #expect(try context.fetch(FetchDescriptor<Entry>()).count == 2)
        for row in records { try RecordCopy(id: row.id, kind: row.kind, payload: row.payload).validate() }
    }

    @Test func neverAppliedAfterItsDate() throws {
        let late = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 9))!
        let (context, defaults) = try seeded(at: late)
        #expect(!defaults.bool(forKey: ResetSeed.flag))
        #expect(try context.fetch(FetchDescriptor<Checkpoint>()).map(\.title) == ["Старое"])
        // Without the local file nothing happens either.
        try ResetSeed.applyIfNeeded(context, defaults: defaults, now: now, start: nil)
        #expect(!defaults.bool(forKey: ResetSeed.flag))
    }

    @Test func monthHistoryKeepsBalances() throws {
        let (context, defaults) = try seeded()
        let before = try net(context)
        try NovemberSeed.applyIfNeeded(context, defaults: defaults, start: Fixture.start)
        #expect(try net(context) == before)
        let entries = try context.fetch(FetchDescriptor<Entry>())
        #expect(entries.allSatisfy { $0.date < now })
        let expenses = entries.filter { $0.kind == Flow.expense.rawValue }
        // 300 + 900 + 450 + 1 200,50 + 700 + 250 + 120 + $10 × 80 + the 1 000 donation
        #expect(expenses.reduce(Int64(0)) { $0 + $1.cents } == 30_000 + 90_000 + 45_000 + 120_050 + 70_000 + 25_000 + 12_000 + 80_000 + 100_000)
        let cash = try #require(entries.first { $0.transfer })
        #expect(cash.cents == 500_000 && cash.destinationKey == ResetSeed.key(0))
        let count = entries.count
        try NovemberSeed.applyIfNeeded(context, defaults: defaults, start: Fixture.start)
        #expect(try context.fetch(FetchDescriptor<Entry>()).count == count)
    }

    @Test func monthBreakdownBySubcategory() throws {
        let (context, defaults) = try seeded()
        try NovemberSeed.applyIfNeeded(context, defaults: defaults, start: Fixture.start)
        let november = SpendPeriod.month.interval(offset: 0, now: now, calendar: calendar)
        let rows = SpendingBreakdown.rows(try context.fetch(FetchDescriptor<Entry>()), in: november)
        let total = rows.reduce(Int64(0)) { $0 + $1.cents }
        let categories = SpendingBreakdown.slices(rows, category: nil, subcategory: nil)
        #expect(categories.reduce(Int64(0)) { $0 + $1.cents } == total)
        for category in categories {
            let subs = SpendingBreakdown.slices(rows, category: category.name, subcategory: nil)
            #expect(subs.reduce(Int64(0)) { $0 + $1.cents } == category.cents)
        }
        let cafe = Dictionary(uniqueKeysWithValues: SpendingBreakdown.slices(rows, category: "Кафе", subcategory: nil).map { ($0.name, $0.cents) })
        #expect(cafe == ["Кофейни": 30_000, "Фастфуд": 90_000, "Рестораны": 45_000])
        let food = Dictionary(uniqueKeysWithValues: SpendingBreakdown.slices(rows, category: "Продукты", subcategory: nil).map { ($0.name, $0.cents) })
        #expect(food == ["Супермаркеты": 120_050, "Доставка продуктов": 70_000])
        let transport = Dictionary(uniqueKeysWithValues: SpendingBreakdown.slices(rows, category: "Транспорт", subcategory: nil).map { ($0.name, $0.cents) })
        #expect(transport == ["Такси": 25_000, "Самокаты": 12_000])
        #expect(SpendingBreakdown.top(categories).reduce(Int64(0)) { $0 + $1.cents } == total)
        #expect(Subcategories.merchant("Супермаркет · итого") == "Супермаркет")
        #expect(Subcategories.infer(category: "Красота", note: "Салон") == Subcategories.none)
    }

    @Test func projectScheduleAndProgress() throws {
        let project = try #require(ResetSeed.project(Fixture.start))
        #expect(project.schedule.map(\.month) == [202612, 202701, 202702, 202703])
        #expect(project.schedule.allSatisfy { $0.planned == 300_000 })
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { Charity.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
        let paid = [ProjectContribution(id: UUID(), project: project.id, date: day(2026, 12, 20), cents: 100_000, note: ""),
                    ProjectContribution(id: UUID(), project: project.id, date: day(2027, 1, 10), cents: 600_000, note: ""),
                    ProjectContribution(id: UUID(), project: UUID(), date: day(2027, 1, 10), cents: 999, note: "")]
        let january = ProjectProgress(project, contributions: paid, today: day(2027, 1, 15))
        #expect(january.saved == 700_000 && january.remaining == 500_000)
        #expect(january.expected == 600_000 && january.lead == 100_000)
        #expect(january.monthsLeft == 3 && january.paidByMonth[202612] == 100_000)
        #expect(ReminderPlan.months(10) == "10 месяцев" && ReminderPlan.months(1) == "1 месяц" && ReminderPlan.months(3) == "3 месяца")
    }

    @Test func paymentAndProjectReminders() {
        let payments = ResetSeed.payments(Fixture.start)
        let at = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12))!
        let plan = ReminderPlan.payments(payments, now: at, minutes: 600, calendar: calendar)
        let first = plan.filter { $0.id.contains("card1") }
        #expect(first.map(\.id) == ["kd.pay.card1-2026-11.3", "kd.pay.card1-2026-11.1"])
        #expect(first.map(\.when) == [.date(calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 10))!),
                                      .date(calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 10))!)])
        #expect(first.allSatisfy { $0.route == .payment })
        #expect(plan.count == 4 && Set(plan.map(\.id)).count == 4)
        let project = ReminderPlan.projects(["Проект"], minutes: 600)
        #expect(project.map(\.when) == [.monthly(day: 1, minutes: 600)])
        #expect(ReminderPlan.projects([], minutes: 600).isEmpty)
    }
}

@MainActor struct QuickBackupTests {
    /// One tap: the copy is made, encrypted, offered for saving and opens again with the same data.
    @Test func oneTapCopyOpensWithTheSameData() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Entry.self, Checkpoint.self, StatementSource.self, IncomePlan.self, BackupInstall.self, FinanceRecord.self,
                                           configurations: config)
        let context = ModelContext(container)
        context.insert(Entry(cents: 12_345, flow: .expense, category: "Кафе", note: "Кофе", date: .now))
        context.insert(Checkpoint(position: .init(title: "Карта", amount: 100_000, debt: false), key: "card", date: .now))
        try context.save()
        let backup = QuickBackup()
        backup.start(context: context, password: "пароль-для-теста-1")
        for _ in 0..<200 where !backup.exporting { try await Task.sleep(for: .milliseconds(50)) }
        #expect(backup.phase == .ready, "\(backup.phase)")
        #expect(backup.progress == 1 && backup.exporting)
        #expect(backup.filename.hasSuffix(".kdfin"))
        let bytes = try #require(backup.document?.bytes)
        let copy = try BackupCipher.open(bytes, password: "пароль-для-теста-1")
        #expect(copy.entries.map(\.cents) == [12_345] && copy.accounts.map(\.amount) == [100_000])
        #expect(throws: (any Error).self) { try BackupCipher.open(bytes, password: "неверный-пароль-123") }
        // Closing the save sheet without saving clears the bar and records nothing.
        backup.cancelled()
        #expect(backup.phase == .idle && backup.document == nil)
    }
}

@MainActor struct RestoreFromScratchTests {
    /// A copy made on one device restores everything into an empty app on another.
    @Test func emptyAppComesBackFromACopy() throws {
        func container() throws -> ModelContext {
            ModelContext(try ModelContainer(for: Entry.self, Checkpoint.self, StatementSource.self, IncomePlan.self, BackupInstall.self, FinanceRecord.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        }
        let phone = try container()
        phone.insert(Entry(cents: 45_000, flow: .expense, category: "Кафе", note: "Кофейня", date: .now))
        phone.insert(Checkpoint(position: .init(title: "Карта A", amount: 250_000, debt: false), key: "excel-20260901-3", date: .now))
        let plan = IncomePlan(); plan.title = "Зарплата"; plan.type = IncomeKind.salary.rawValue; plan.amount = 9_000_000
        phone.insert(plan)
        phone.insert(try FinanceRecord(RecurringPayment.kind, RecurringPayment(title: "Связь", cents: 80_000), id: UUID()))
        try phone.save()
        let file = try BackupCipher.seal(try LedgerCopy(phone), password: "пароль-копии-12345")

        // A fresh install: nothing inside, then the copy is opened and restored.
        let fresh = try container()
        #expect(try fresh.fetch(FetchDescriptor<Entry>()).isEmpty)
        let copy = try BackupCipher.open(file, password: "пароль-копии-12345")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try copy.restore(fresh, defaults: UserDefaults(suiteName: "restore-" + UUID().uuidString)!, archiveRoot: root)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try fresh.fetch(FetchDescriptor<Entry>()).map(\.cents) == [45_000])
        #expect(try fresh.fetch(FetchDescriptor<Checkpoint>()).map(\.amount) == [250_000])
        #expect(try fresh.fetch(FetchDescriptor<IncomePlan>()).map(\.amount) == [9_000_000])
        #expect(RecurringStore.payments(try fresh.fetch(FetchDescriptor<FinanceRecord>())).map(\.title) == ["Связь"])
        #expect(UTType.kdfin.preferredFilenameExtension == nil || UTType.kdfin.conforms(to: .data))
    }
}

struct ProfileNameTests {
    @Test func chosenNameOrPlainGreeting() {
        let d = UserDefaults(suiteName: "name-" + UUID().uuidString)!
        ProfileName.set("  Анна  ", defaults: d)
        #expect(d.string(forKey: ProfileName.key) == "Анна" && d.bool(forKey: ProfileName.askedKey))
        ProfileName.set("", defaults: d)
        #expect(d.string(forKey: ProfileName.key) == nil && d.bool(forKey: ProfileName.askedKey))
        #expect(WelcomeScene.title(hour: 9, name: nil) == "Доброе утро")
        #expect(WelcomeScene.title(hour: 9, name: "Анна") == "Доброе утро, Анна")
        // The bundled profile carries only initials: no name by default.
        #expect(LocalProfile.current.name == nil && LocalProfile.current.initials == "KD")
    }
}
