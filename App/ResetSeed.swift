import Foundation
import SwiftData

/// The owner's fresh-start data, kept outside Git in `App/ArchiveResources/Local/fresh-start.json`.
/// The code holds no personal values; without the file nothing is seeded.
/// An exact amount written in JSON as text ("1234.50") or as a number.
struct Amount: Decodable, Equatable {
    let value: Decimal
    init(_ value: Decimal) { self.value = value }
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if let text = try? box.decode(String.self) {
            guard let value = Decimal(string: text.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")) else {
                throw DecodingError.dataCorruptedError(in: box, debugDescription: "Неверная сумма: " + text)
            }
            self.value = value
        } else { value = Decimal(string: String(try box.decode(Double.self)))! }
    }
}

struct FreshStart: Decodable {
    struct Account: Decodable {
        let key: String
        let title: String
        var rub: Amount?
        var usd: Amount?
        /// Grams (or dollars for crypto) of a priced holding; the app values it at today's quote.
        var grams: String?
        var debt: Bool?
    }
    struct Payment: Decodable { let id: String; let title: String; let amount: Amount; var minimum: Amount?; let due: String }
    struct Project: Decodable { let title: String; let total: Amount; let months: Int; let firstMonth: Int; let accountKey: String }
    struct Plan: Decodable {
        let title: String
        let kind: String
        let amount: Amount
        let payout: String
        var start: String?
        var rate: Amount?
        var monthly: Bool?
        var exempt: Bool?
    }
    struct Spend: Decodable { let day: Int; var rub: Amount?; var usd: Amount?; let category: String; let note: String; let account: String }
    struct Transfer: Decodable { let day: Int; let rub: Amount; let from: String; let to: String; let note: String }
    struct Donation: Decodable { let rub: Amount; let day: Int; let forMonth: Int; let note: String; let account: String }

    let validUntil: String
    let accounts: [Account]
    var hidden: [String] = []
    var payments: [Payment] = []
    var project: Project?
    var plans: [Plan] = []
    var donation: Donation?
    /// yyyymm of the month the spending history belongs to.
    var spendingMonth: Int?
    var spending: [Spend] = []
    var transfers: [Transfer] = []

    static let fileName = "fresh-start"
    static func load(_ url: URL?) -> FreshStart? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FreshStart.self, from: data)
    }
    static var bundled: FreshStart? {
        load(Archive.resources.resourceURL?.appendingPathComponent("ArchiveResources/Local/" + fileName + ".json"))
    }

    /// "2026-11-29" at noon, local time.
    static func day(_ text: String, calendar: Calendar = Charity.calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
    func valid(at now: Date, calendar: Calendar = Charity.calendar) -> Bool {
        guard let last = Self.day(validUntil, calendar: calendar) else { return false }
        return now < calendar.startOfDay(for: last).addingTimeInterval(86_400)
    }
}

enum Money {
    static func cents(_ rubles: Decimal) -> Int64 { rounded(rubles * 100) }
    static func rounded(_ value: Decimal) -> Int64 {
        var raw = value, result = Decimal()
        NSDecimalRound(&result, &raw, 0, .plain)
        return NSDecimalNumber(decimal: result).int64Value
    }
}

/// One-time fresh start on a device: wipes operations, reconciliations, lots, statements and income plans,
/// then sets the balances from `FreshStart`. Runs once per device, and only until `validUntil`,
/// so a later reinstall never brings back old balances.
enum ResetSeed {
    static let flag = "seed.reset-2026-11-20"
    static func key(_ index: Int) -> String { "excel-20260901-" + String(index) }
    /// The project account; its balance counts as money.
    static let coffeeKey = "account-project-coffee"
    static let projectID = UUID(uuidString: "C0FFEE00-2026-4B20-9000-000000000001")!

    static func positions(_ start: FreshStart, prices: MarketPrices) -> [(key: String, position: Archive.Position)] {
        start.accounts.map { account in
            var cents: Int64 = 0
            if let rub = account.rub { cents = Money.cents(rub.value) }
            else if let usd = account.usd { cents = Money.rounded(usd.value * prices.usd * 100) }
            else if let grams = account.grams, let holding = Holding(rawValue: account.key) { cents = prices.valuation(of: holding, quantity: grams) ?? 0 }
            return (account.key, Archive.Position(title: account.title, amount: cents, debt: account.debt ?? false))
        }
    }
    static func payments(_ start: FreshStart) -> [PaymentDue] {
        start.payments.compactMap { item in
            FreshStart.day(item.due).map { PaymentDue(id: item.id, title: item.title, amount: Money.cents(item.amount.value), minimum: item.minimum.map { Money.cents($0.value) }, due: $0) }
        }
    }
    static func project(_ start: FreshStart) -> SavingsProject? {
        start.project.map { SavingsProject(id: projectID, title: $0.title, total: Money.cents($0.total.value), months: $0.months, firstMonth: $0.firstMonth, accountKey: $0.accountKey) }
    }
    static func incomePlans(_ start: FreshStart) -> [IncomePlan] {
        start.plans.compactMap { item in
            guard let kind = IncomeKind(rawValue: item.kind), let payout = FreshStart.day(item.payout) else { return nil }
            let plan = IncomePlan()
            plan.title = item.title; plan.type = kind.rawValue; plan.amount = Money.cents(item.amount.value)
            plan.rateBP = item.rate.map { Int(Money.rounded($0.value * 100)) } ?? 0
            plan.payout = IncomeMath.calendar.startOfDay(for: payout)
            plan.start = item.start.flatMap { FreshStart.day($0) }.map { IncomeMath.calendar.startOfDay(for: $0) } ?? plan.payout
            plan.monthly = item.monthly ?? false
            plan.exempt = item.exempt ?? false
            if plan.exempt && kind.bank { plan.bankExemptionReason = "regular" }
            return plan
        }
    }

    @MainActor static func applyIfNeeded(_ context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now,
                                         start: FreshStart? = FreshStart.bundled) throws {
        guard !defaults.bool(forKey: flag), let start, start.valid(at: now) else { return }
        let prices = defaults.data(forKey: "markets.prices").flatMap { try? JSONDecoder().decode(MarketPrices.self, from: $0) } ?? .initial
        for value in try context.fetch(FetchDescriptor<Entry>()) { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<Checkpoint>()) { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<IncomePlan>()) { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<StatementSource>()) { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FinanceRecord>()) { context.delete(value) }

        for (key, position) in positions(start, prices: prices) {
            let mark = Checkpoint(position: position, key: key, date: now)
            if Holding(rawValue: key) != nil { mark.valuationSource = try? JSONEncoder().encode(prices) }
            context.insert(mark)
        }
        for plan in incomePlans(start) { context.insert(plan) }
        if let donation = start.donation, let month = start.spendingMonth {
            let date = min(now.addingTimeInterval(-60), Charity.calendar.date(from: DateComponents(year: month / 100, month: month % 100, day: donation.day, hour: 12))!)
            let entry = Entry(cents: Money.cents(donation.rub.value), flow: .expense, category: Charity.category, note: donation.note, date: date)
            entry.accountKey = donation.account
            entry.charityMonth = donation.forMonth
            context.insert(entry)
        }
        if let project = project(start) { context.insert(try FinanceRecord(SavingsProject.kind, project, id: project.id)) }
        try context.save()

        defaults.set(try JSONEncoder().encode(start.hidden), forKey: "accounts.hidden")
        for account in start.accounts {
            if let grams = account.grams, Holding(rawValue: account.key) != nil { defaults.set(grams, forKey: "quantity." + account.key) }
        }
        let foreign = Dictionary(uniqueKeysWithValues: start.accounts.compactMap { account in
            account.usd.map { (account.key, ForeignHolding(currency: "USD", units: Money.cents($0.value), rate: prices.usd)) }
        })
        defaults.set(try JSONEncoder().encode(foreign), forKey: LiveCapital.foreignKey)
        defaults.set(try JSONEncoder().encode(payments(start)), forKey: PaymentDue.storageKey)
        defaults.set(true, forKey: ReminderKeys.charity)
        defaults.set(project(start).map { [$0.title] } ?? [], forKey: SavingsProject.activeKey)
        defaults.removeObject(forKey: "portfolio.reconciliation")
        defaults.set(FreshStart.day(start.validUntil).map { NetWorthHistory.key($0, calendar: Charity.calendar) } ?? "fresh", forKey: FreshStartMark.key)
        defaults.set(true, forKey: flag)
    }
}

/// The month's spending history from `FreshStart`. The balances above already include it, so every
/// operation is dated before them and changes only reports and the charity base. Runs once, after `ResetSeed`.
enum NovemberSeed {
    static let flag = "seed.november-2026-expenses"

    @MainActor static func applyIfNeeded(_ context: ModelContext, defaults: UserDefaults = .standard, start: FreshStart? = FreshStart.bundled) throws {
        guard !defaults.bool(forKey: flag), defaults.bool(forKey: ResetSeed.flag) else { return }
        guard let start, let month = start.spendingMonth else { defaults.set(true, forKey: flag); return }
        let prices = defaults.data(forKey: "markets.prices").flatMap { try? JSONDecoder().decode(MarketPrices.self, from: $0) } ?? .initial
        // Every operation stays strictly before the balances, so no account changes.
        let cutoff = try context.fetch(FetchDescriptor<Checkpoint>()).map(\.date).min() ?? .now
        var moscow = Calendar(identifier: .gregorian)
        moscow.timeZone = TimeZone(identifier: "Europe/Moscow")!
        func date(_ day: Int) -> Date {
            min(moscow.date(from: DateComponents(year: month / 100, month: month % 100, day: day, hour: 12))!, cutoff.addingTimeInterval(-120))
        }
        for item in start.spending {
            let cents = item.rub.map { Money.cents($0.value) } ?? item.usd.map { Money.rounded($0.value * prices.usd * 100) } ?? 0
            guard cents > 0 else { continue }
            let entry = Entry(cents: cents, flow: .expense, category: item.category, note: item.note, date: date(item.day))
            entry.accountKey = item.account
            context.insert(entry)
        }
        for item in start.transfers {
            let entry = Entry(cents: Money.cents(item.rub.value), flow: .transfer, category: Flow.transfer.rawValue, note: item.note, date: date(item.day))
            entry.accountKey = item.from
            entry.destinationKey = item.to
            context.insert(entry)
        }
        for donation in try context.fetch(FetchDescriptor<Entry>()) where Charity.isDonation(donation.category) {
            donation.date = min(donation.date, cutoff.addingTimeInterval(-120))
        }
        try context.save()
        defaults.set(true, forKey: flag)
    }
}
