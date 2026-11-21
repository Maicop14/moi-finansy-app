import SwiftUI
import SwiftData

// MARK: - Regular payments

/// Which accounts are cards. Accounts have no explicit type yet, so this goes by kind and name:
/// credit cards are liabilities other than loans; debit and currency cards say «карта», «дебетовая» or «card».
enum AccountKind {
    static func isCard(_ account: AccountBalance) -> Bool {
        let id = account.id
        if id.hasPrefix("loan-") || id.hasPrefix("receivable-") || id == ResetSeed.coffeeKey || Holding(rawValue: id) != nil { return false }
        if account.position.debt { return true }
        let title = account.position.title.lowercased()
        return ["карт", "дебет", "кредитк", "card"].contains { title.contains($0) }
    }
}

struct RecurringPayment: Codable, Identifiable, Equatable {
    static let kind = "recurring"
    enum Unit: String, Codable, CaseIterable { case week, month, year }
    var id = UUID()
    var title = ""
    /// Amount in `currency`, in hundredths.
    var cents: Int64 = 0
    var currency = "RUB"
    var accountKey = ""
    var category = "Подписки"
    var subcategory: String?
    var unit = Unit.month
    var every = 1
    /// Day of month the payment is due, kept even when a shorter month moves it earlier.
    var anchorDay = 1
    var next = Date()
    var end: Date?
    var active = true
    var note = ""

    var frequencyText: String {
        switch unit {
        case .week: every == 1 ? "еженедельно" : "раз в " + String(every) + " нед."
        case .month: every == 1 ? "ежемесячно" : "раз в " + ReminderPlan.months(every)
        case .year: every == 1 ? "ежегодно" : "раз в " + String(every) + " г."
        }
    }
    var currencySign: String { DisplayCurrency(rawValue: currency)?.symbol ?? "₽" }
    var amountText: String {
        if DemoMode.isOn { return DemoMode.masked(currencySign) }
        return currency == "RUB" ? money(cents) : (Decimal(cents) / 100).formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "ru_RU"))) + " " + currencySign
    }
}

enum RecurringMath {
    static func advance(_ payment: RecurringPayment, from date: Date, calendar: Calendar) -> Date {
        let every = max(payment.every, 1)
        switch payment.unit {
        case .week: return calendar.date(byAdding: .day, value: 7 * every, to: date) ?? date
        case .month, .year:
            let step = payment.unit == .month ? DateComponents(month: every) : DateComponents(year: every)
            let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
            let target = calendar.date(byAdding: step, to: month) ?? date
            let days = calendar.range(of: .day, in: .month, for: target)?.count ?? 28
            var parts = calendar.dateComponents([.year, .month], from: target)
            parts.day = min(max(payment.anchorDay, 1), days)
            let time = calendar.dateComponents([.hour, .minute], from: date)
            parts.hour = time.hour; parts.minute = time.minute
            return calendar.date(from: parts) ?? target
        }
    }
    static func occurrences(_ payment: RecurringPayment, in interval: DateInterval, calendar: Calendar) -> [Date] {
        guard payment.active else { return [] }
        var result = [Date](), date = payment.next, guardCount = 0
        while date < interval.end, guardCount < 600 {
            if let end = payment.end, date > end { break }
            if date >= interval.start { result.append(date) }
            date = advance(payment, from: date, calendar: calendar)
            guardCount += 1
        }
        return result
    }
    /// Rubles by the latest Central Bank rate the app has.
    static func rub(_ payment: RecurringPayment, prices: MarketPrices) -> Int64 {
        let rate: Decimal = switch payment.currency { case "USD": prices.usd; case "EUR": prices.eur ?? prices.usd; default: 1 }
        var raw = Decimal(payment.cents) * rate, rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
    static func total(_ list: [RecurringPayment], in interval: DateInterval, prices: MarketPrices, calendar: Calendar) -> Int64 {
        list.reduce(0) { $0 + rub($1, prices: prices) * Int64(occurrences($1, in: interval, calendar: calendar).count) }
    }
    static func month(_ key: Int, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .month, for: calendar.date(from: DateComponents(year: key / 100, month: key % 100, day: 15))!)!
    }
    /// What is still due from the start of today to the end of this month.
    static func remainingThisMonth(_ list: [RecurringPayment], now: Date, prices: MarketPrices, calendar: Calendar) -> Int64 {
        let month = calendar.dateInterval(of: .month, for: now)!
        return total(list, in: DateInterval(start: calendar.startOfDay(for: now), end: month.end), prices: prices, calendar: calendar)
    }
    static let tokenPrefix = "recurring:"
}

struct RecurringDue: Codable, Equatable {
    static let storageKey = "notify.recurring.list"
    let id: String
    let title: String
    let amount: String
    let due: Date
}

enum RecurringStore {
    static func payments(_ records: [FinanceRecord]) -> [RecurringPayment] {
        records.filter { $0.kind == RecurringPayment.kind }.compactMap { try? JSONDecoder().decode(RecurringPayment.self, from: $0.payload) }
    }
    static func save(_ payment: RecurringPayment, records: [FinanceRecord], context: ModelContext) throws {
        if let row = records.first(where: { $0.kind == RecurringPayment.kind && $0.id == payment.id }) {
            row.payload = try JSONEncoder().encode(payment)
        } else {
            context.insert(try FinanceRecord(RecurringPayment.kind, payment, id: payment.id))
        }
        try context.save()
    }
    /// Mirrors the next due date of each active payment for the notification scheduler.
    static func syncReminders(_ list: [RecurringPayment]) {
        let due = list.filter(\.active).map { RecurringDue(id: $0.id.uuidString, title: $0.title, amount: $0.amountText, due: $0.next) }
        let data = try? JSONEncoder().encode(due)
        if UserDefaults.standard.data(forKey: RecurringDue.storageKey) != data {
            UserDefaults.standard.set(data, forKey: RecurringDue.storageKey)
            Task { @MainActor in await Reminders.reschedule() }
        }
    }
}

struct RecurringScreen: View {
    static func detailLine(_ item: RecurringPayment, accounts: [AccountBalance]) -> String {
        let sub: String = item.subcategory.map { " › " + $0 } ?? ""
        let card: String = accounts.first { $0.id == item.accountKey }?.position.title ?? "счёт не выбран"
        return "\(item.frequencyText) · \(item.category)\(sub) · \(card)"
    }
    let accounts: [AccountBalance]
    @Query private var records: [FinanceRecord]
    @Environment(\.modelContext) private var context
    @AppStorage("markets.prices") private var priceCache = Data()
    @State private var editing: RecurringPayment?
    @State private var paying: RecurringPayment?
    @State private var message = ""
    private var prices: MarketPrices { (try? JSONDecoder().decode(MarketPrices.self, from: priceCache)) ?? .initial }

    var body: some View {
        let calendar = Calendar.autoupdatingCurrent
        let list = RecurringStore.payments(records).sorted { ($0.active ? 0 : 1, $0.next) < ($1.active ? 0 : 1, $1.next) }
        let month = calendar.dateInterval(of: .month, for: .now)!
        VStack(alignment: .leading, spacing: 10) {
            Text("В этом месяце").font(.subheadline)
            Text(money(RecurringMath.total(list, in: month, prices: prices, calendar: calendar))).font(.largeTitle.bold()).monospacedDigit()
            Text("Осталось оплатить: " + money(RecurringMath.remainingThisMonth(list, now: .now, prices: prices, calendar: calendar)))
                .font(.headline).foregroundStyle(Palette.accent)
            Text("Суммы в $ и € пересчитаны по курсу ЦБ на " + prices.currencyDate + ".").font(.caption).foregroundStyle(Palette.secondary)
            HStack {
                Button("Добавить платёж") { editing = RecurringPayment(accountKey: accounts.first(where: AccountKind.isCard)?.id ?? "") }.buttonStyle(.borderedProminent)
                Menu("Шаблоны") {
                    ForEach([("Мобильная связь", "Связь", "Мобильная связь"), ("Интернет", "Связь", "Интернет и ТВ"),
                             ("Подписка", "Подписки", "Сервисы"), ("Аренда", "Дом", nil as String?)], id: \.0) { item in
                        Button(item.0) { editing = RecurringPayment(title: item.0, accountKey: accounts.first(where: AccountKind.isCard)?.id ?? "", category: item.1, subcategory: item.2) }
                    }
                }
            }
            if !message.isEmpty { Text(message).font(.caption) }
        }.bankTile()
        .sheet(item: $editing) { RecurringForm(payment: $0, accounts: accounts) }
        .alert("Записать оплату?", isPresented: Binding(get: { paying != nil }, set: { if !$0 { paying = nil } }), presenting: paying) { item in
            Button("Записать расход") { markPaid(item) }
            Button("Отмена", role: .cancel) {}
        } message: { item in
            let sum: String = money(RecurringMath.rub(item, prices: prices))
            let card: String = accounts.first { $0.id == item.accountKey }?.position.title ?? "—"
            Text("\(item.title): \(sum) со счёта «\(card)». Остаток счёта уменьшится, следующий платёж сдвинется.")
        }
        .onAppear { RecurringStore.syncReminders(list) }
        .onChange(of: records.count) { _, _ in RecurringStore.syncReminders(RecurringStore.payments(records)) }
        if list.isEmpty {
            ContentUnavailableView("Пока нет регулярных платежей", systemImage: "repeat.circle",
                                   description: Text("Добавь подписки, связь, интернет, аренду. Приложение напомнит за день до оплаты и в день оплаты, а отметка «Оплачено» запишет расход."))
                .bankTile()
        }
        ForEach(list) { item in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.headline)
                    if !item.active { Text("пауза").font(.caption).padding(.horizontal, 6).background(.quaternary, in: Capsule()) }
                    Spacer()
                    Text(item.amountText).monospacedDigit().bold()
                }
                Text(Self.detailLine(item, accounts: accounts))
                    .font(.caption).foregroundStyle(Palette.secondary)
                if item.active {
                    let overdue = item.next < calendar.startOfDay(for: .now)
                    Text((overdue ? "Просрочен с " : "Следующий платёж ") + item.next.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month(.wide)))
                        .font(.subheadline).foregroundStyle(overdue ? Palette.negative : Palette.text)
                }
                HStack {
                    if item.active { Button("Отметить оплаченным") { paying = item }.buttonStyle(.bordered) }
                    Spacer()
                    Button("Изменить") { editing = item }
                }
            }.bankTile()
        }
    }

    private func markPaid(_ item: RecurringPayment) {
        let entry = Entry(cents: RecurringMath.rub(item, prices: prices), flow: .expense, category: item.category,
                          note: item.title + (item.currency == "RUB" ? "" : " · " + item.amountText), date: .now)
        entry.accountKey = item.accountKey
        entry.subcategory = item.subcategory
        entry.importToken = RecurringMath.tokenPrefix + item.id.uuidString
        context.insert(entry)
        var next = item
        next.next = RecurringMath.advance(item, from: item.next, calendar: .autoupdatingCurrent)
        if let end = item.end, next.next > end { next.active = false }
        do { try RecurringStore.save(next, records: records, context: context); message = "Оплата записана: " + item.title }
        catch { context.rollback(); message = "Не удалось записать оплату." }
    }
}

private struct RecurringForm: View {
    @State var payment: RecurringPayment
    let accounts: [AccountBalance]
    @Query private var records: [FinanceRecord]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var hasEnd = false
    @State private var confirmDelete = false
    @State private var failed = false
    private var isNew: Bool { !records.contains { $0.id == payment.id } }

    init(payment: RecurringPayment, accounts: [AccountBalance]) {
        _payment = State(initialValue: payment)
        self.accounts = accounts
        _amount = State(initialValue: payment.cents > 0 ? NSDecimalNumber(decimal: Decimal(payment.cents) / 100).stringValue : "")
        _hasEnd = State(initialValue: payment.end != nil)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Название, например «Яндекс Плюс»", text: $payment.title)
                HStack {
                    TextField("Сумма", text: $amount)
                    #if os(iOS)
                        .keyboardType(.decimalPad)
                    #endif
                    Picker("", selection: $payment.currency) { Text("₽").tag("RUB"); Text("$").tag("USD"); Text("€").tag("EUR") }
                        .pickerStyle(.segmented).frame(width: 130)
                }
                Picker("Карта", selection: $payment.accountKey) {
                    Text("Выберите карту").tag("")
                    // Only debit and credit cards; a payment saved earlier on another account stays selectable.
                    ForEach(accounts.filter { AccountKind.isCard($0) || $0.id == payment.accountKey }) { Text($0.position.title).tag($0.id) }
                }
                Picker("Категория", selection: $payment.category) {
                    ForEach(Flow.expense.categories.filter { !Charity.isDonation($0) }, id: \.self) { Text($0) }
                }.onChange(of: payment.category) { _, _ in payment.subcategory = nil }
                Picker("Подкатегория", selection: Binding(get: { payment.subcategory ?? "" }, set: { payment.subcategory = $0.isEmpty ? nil : $0 })) {
                    Text(Subcategories.none).tag("")
                    ForEach(Subcategories.list(for: payment.category), id: \.self) { Text($0).tag($0) }
                }
                Picker("Как часто", selection: Binding(get: { payment.unit == .month && payment.every > 1 ? "months" : payment.unit.rawValue },
                                                       set: { value in
                    switch value {
                    case "week": payment.unit = .week; payment.every = 1
                    case "year": payment.unit = .year; payment.every = 1
                    case "months": payment.unit = .month; payment.every = max(payment.every, 2)
                    default: payment.unit = .month; payment.every = 1
                    }
                })) {
                    Text("Ежемесячно").tag("month"); Text("Раз в N месяцев").tag("months"); Text("Ежегодно").tag("year"); Text("Еженедельно").tag("week")
                }
                if payment.unit == .month && payment.every > 1 {
                    Stepper("Каждые " + ReminderPlan.months(payment.every), value: $payment.every, in: 2...24)
                }
                DatePicker("Следующий платёж", selection: $payment.next, displayedComponents: .date)
                Toggle("Есть дата окончания", isOn: $hasEnd)
                if hasEnd { DatePicker("Последний платёж", selection: Binding(get: { payment.end ?? payment.next }, set: { payment.end = $0 }), displayedComponents: .date) }
                Toggle("Активен", isOn: $payment.active)
                TextField("Заметка", text: $payment.note)
                if !isNew { Button("Удалить платёж", role: .destructive) { confirmDelete = true } }
            }.formStyle(.grouped).navigationTitle(isNew ? "Новый платёж" : "Регулярный платёж")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        guard let cents = IncomeMath.positive(amount) else { return }
                        payment.cents = cents
                        payment.title = payment.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        payment.anchorDay = Calendar.autoupdatingCurrent.component(.day, from: payment.next)
                        payment.next = Calendar.autoupdatingCurrent.date(bySettingHour: 12, minute: 0, second: 0, of: payment.next) ?? payment.next
                        if !hasEnd { payment.end = nil }
                        do { try RecurringStore.save(payment, records: records, context: context); dismiss() }
                        catch { context.rollback(); failed = true }
                    }.disabled(IncomeMath.positive(amount) == nil || payment.title.trimmingCharacters(in: .whitespaces).isEmpty || payment.accountKey.isEmpty)
                }
            }
            .alert("Удалить платёж?", isPresented: $confirmDelete) {
                Button("Удалить", role: .destructive) {
                    for row in records where row.id == payment.id { context.delete(row) }
                    try? context.save(); dismiss()
                }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Уже записанные оплаты останутся в операциях.") }
            .alert("Не удалось сохранить", isPresented: $failed) { Button("ОК") {} }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }
}

// MARK: - Budget

struct MonthBudget: Codable, Identifiable, Equatable {
    static let kind = "budget"
    var id = UUID()
    var month: Int
    /// Spending limits per category, in kopecks.
    var limits: [String: Int64] = [:]
}

enum BudgetLevel { case ok, warning, over }

struct BudgetPlan: Equatable {
    var income: Int64 = 0
    var incomeMissing = false
    var regular: Int64 = 0
    var cards: [(String, Int64)] = []
    var coffee: Int64 = 0
    var charity: Int64 = 0
    var limits: Int64 = 0
    var obligations: Int64 { regular + cards.reduce(0) { $0 + $1.1 } + coffee + charity }
    var spendingPlan: Int64 { obligations + limits }
    var balance: Int64 { income - spendingPlan }
    static func == (a: Self, b: Self) -> Bool {
        a.income == b.income && a.regular == b.regular && a.cards.map(\.1) == b.cards.map(\.1) && a.coffee == b.coffee && a.charity == b.charity && a.limits == b.limits
    }
}

enum BudgetMath {
    static func spentLine(used: Int64, limit: Int64) -> String {
        let spent: String = money(used)
        guard limit > 0 else { return "Потрачено \(spent) · лимит не задан" }
        return used <= limit ? "Потрачено \(spent) · осталось \(money(limit - used))" : "Потрачено \(spent) · перерасход \(money(used - limit))"
    }
    static func key(_ date: Date) -> Int { Charity.key(date) }
    static func next(_ month: Int, by delta: Int = 1) -> Int { Charity.key(Charity.calendar.date(byAdding: .month, value: delta, to: Charity.start(month))!) }

    /// Variable spending by category; regular payments and charity are planned separately.
    static func actual(_ entries: [Entry], month: Int) -> [String: Int64] {
        entries.filter { $0.kind == Flow.expense.rawValue && $0.cents > 0 && Charity.key($0.date) == month && !Charity.isDonation($0.category)
            && !($0.importToken?.hasPrefix(RecurringMath.tokenPrefix) ?? false) }
            .reduce(into: [:]) { $0[$1.category, default: 0] += $1.cents }
    }
    static func level(limit: Int64, actual: Int64) -> BudgetLevel {
        guard limit > 0 else { return actual > 0 ? .over : .ok }
        let ratio = Double(actual) / Double(limit)
        return ratio > 1 ? .over : ratio >= 0.8 ? .warning : .ok
    }
    /// Last month's actual spending per category, rounded up to whole hundreds of rubles.
    static func suggestion(_ entries: [Entry], from month: Int) -> [String: Int64] {
        actual(entries, month: month).mapValues { ($0 + 9_999) / 10_000 * 10_000 }
    }
    /// What can still be spent per day: for the current month from today, for a future month over all its days.
    static func perDay(remaining: Int64, month: Int, now: Date, calendar: Calendar) -> Int64? {
        let interval = RecurringMath.month(month, calendar: calendar)
        if now >= interval.end { return nil }
        let from = max(calendar.startOfDay(for: now), interval.start)
        let days = max(1, calendar.dateComponents([.day], from: from, to: interval.end).day ?? 1)
        return max(0, remaining) / Int64(days)
    }
    static func income(_ plans: [IncomePlan], month: Int) -> (Int64, missing: Bool) {
        var total: Int64 = 0, missing = false
        for plan in plans {
            let payout = key(plan.payout)
            let counts = plan.kind.bank ? payout == month
                : plan.monthly ? month >= payout : payout == month   // a monthly income continues into the next years
            guard counts else { continue }
            if plan.kind.bank { total += plan.gross } else { total += plan.amount; if plan.amount == 0 { missing = true } }
        }
        return (total, missing)
    }
    static func plan(month: Int, budget: MonthBudget?, entries: [Entry], plans: [IncomePlan], recurring: [RecurringPayment],
                     payments: [PaymentDue], projects: [SavingsProject], prices: MarketPrices, calendar: Calendar) -> BudgetPlan {
        var result = BudgetPlan()
        (result.income, result.incomeMissing) = income(plans, month: month)
        result.regular = RecurringMath.total(recurring, in: RecurringMath.month(month, calendar: calendar), prices: prices, calendar: calendar)
        result.cards = payments.filter { key($0.due) == month }.sorted { $0.due < $1.due }.map { ($0.title, $0.amount) }
        result.coffee = projects.flatMap(\.schedule).filter { $0.month == month }.reduce(0) { $0 + $1.planned }
        // Charity for the previous month is due by the 15th of this one.
        result.charity = Charity.report(entries, at: Charity.start(month)).upcoming.remaining
        result.limits = budget?.limits.values.reduce(0, +) ?? 0
        return result
    }
}

enum BudgetStore {
    static func budgets(_ records: [FinanceRecord]) -> [MonthBudget] {
        records.filter { $0.kind == MonthBudget.kind }.compactMap { try? JSONDecoder().decode(MonthBudget.self, from: $0.payload) }
    }
    static func save(_ budget: MonthBudget, records: [FinanceRecord], context: ModelContext) throws {
        if let row = records.first(where: { $0.kind == MonthBudget.kind && $0.id == budget.id }) {
            row.payload = try JSONEncoder().encode(budget)
        } else { context.insert(try FinanceRecord(MonthBudget.kind, budget, id: budget.id)) }
        try context.save()
    }
}

struct BudgetScreen: View {
    let entries: [Entry]
    @Query private var records: [FinanceRecord]
    @Query private var plans: [IncomePlan]
    @Environment(\.modelContext) private var context
    @AppStorage("markets.prices") private var priceCache = Data()
    @State private var month = BudgetMath.next(BudgetMath.key(.now))
    @State private var draft: [String: String] = [:]
    @State private var message = ""
    private var prices: MarketPrices { (try? JSONDecoder().decode(MarketPrices.self, from: priceCache)) ?? .initial }
    private var categories: [String] { Flow.expense.categories.filter { !Charity.isDonation($0) && $0 != "Закупка товара" } }

    var body: some View {
        let calendar = Calendar.autoupdatingCurrent
        let budget = BudgetStore.budgets(records).first { $0.month == month }
        let plan = BudgetMath.plan(month: month, budget: budget, entries: entries, plans: plans, recurring: RecurringStore.payments(records),
                                   payments: PaymentDue.stored, projects: ProjectStore.projects(records), prices: prices, calendar: calendar)
        let actual = BudgetMath.actual(entries, month: month)
        let spent = actual.filter { budget?.limits[$0.key] != nil }.values.reduce(0, +)
        HStack {
            Button { switchMonth(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Предыдущий месяц")
            Spacer()
            Text(Charity.title(month).prefix(1).uppercased() + Charity.title(month).dropFirst()).font(.title3.bold())
            Spacer()
            Button { switchMonth(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Следующий месяц")
        }.buttonStyle(.borderless)

        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Ожидаемый доход") { Text(money(plan.income)).monospacedDigit() }.font(.headline)
            if plan.incomeMissing { Text("Укажи сумму зарплаты во вкладке «Доходы» — сейчас она 0 ₽.").font(.caption).foregroundStyle(Palette.negative) }
            Divider()
            Text("Обязательные платежи").font(.subheadline.weight(.semibold))
            row("Регулярные платежи", plan.regular)
            ForEach(plan.cards, id: \.0) { row("Кредитка: " + $0.0, $0.1) }
            if plan.coffee > 0 { row("Проект «Кофемашина»", plan.coffee) }
            row("Благотворительность за " + Charity.title(BudgetMath.next(month, by: -1)), plan.charity)
            row("Лимиты на траты", plan.limits)
            Divider()
            LabeledContent("Всего расходов по плану") { Text(money(plan.spendingPlan)).monospacedDigit().bold() }
            LabeledContent(plan.balance >= 0 ? "Останется" : "Не хватает") {
                Text(money(abs(plan.balance))).monospacedDigit().bold().foregroundStyle(plan.balance >= 0 ? Palette.positive : Palette.negative)
            }
            if budget != nil, let perDay = BudgetMath.perDay(remaining: plan.limits - spent, month: month, now: .now, calendar: calendar) {
                LabeledContent("Можно тратить в день") { Text(money(perDay)).monospacedDigit() }.font(.subheadline)
            }
        }.bankTile()

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Лимиты по категориям").font(.headline)
                Spacer()
                Menu("Заполнить") {
                    Button("По факту " + Charity.title(BudgetMath.next(month, by: -1))) { fill(BudgetMath.suggestion(entries, from: BudgetMath.next(month, by: -1))) }
                    Button("Очистить") { fill([:]) }
                }
            }
            ForEach(categories, id: \.self) { category in
                let limit = Self.cents(draft[category]) ?? budget?.limits[category] ?? 0
                let used = actual[category] ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(category)
                        Spacer()
                        if DemoMode.isOn {
                            Text(limit > 0 ? DemoMode.masked() : "—").foregroundStyle(Palette.secondary)
                        } else {
                            TextField("лимит", text: Binding(get: { draft[category] ?? budget?.limits[category].map { String($0 / 100) } ?? "" },
                                                             set: { draft[category] = $0 }))
                                .multilineTextAlignment(.trailing).frame(width: 100).textFieldStyle(.roundedBorder)
                            #if os(iOS)
                                .keyboardType(.numberPad)
                            #endif
                            Text("₽").foregroundStyle(Palette.secondary)
                        }
                    }
                    if limit > 0 || used > 0 {
                        let tint: Color = switch BudgetMath.level(limit: limit, actual: used) { case .ok: Palette.positive; case .warning: .orange; case .over: Palette.negative }
                        ProgressView(value: Double(min(used, max(limit, 1))), total: Double(max(limit, 1))).tint(tint)
                        Text(BudgetMath.spentLine(used: used, limit: limit))
                            .font(.caption).foregroundStyle(tint == Palette.positive ? Palette.secondary : tint)
                    }
                }
            }
            HStack {
                Button("Сохранить бюджет") { save(budget) }.buttonStyle(.borderedProminent).disabled(draft.isEmpty)
                Spacer()
                Button("Скопировать на следующий месяц") { copy(budget) }.disabled(budget == nil)
            }
            if !message.isEmpty { Text(message).font(.caption) }
            Text("Лимиты — для повседневных трат. Регулярные платежи, кредитки, кофемашина и благотворительность учтены выше отдельно.")
                .font(.caption).foregroundStyle(Palette.secondary)
        }.bankTile()
    }

    private func row(_ title: String, _ cents: Int64) -> some View {
        LabeledContent(title) { Text(money(cents)).monospacedDigit() }.font(.subheadline)
    }
    static func cents(_ text: String?) -> Int64? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if text.trimmingCharacters(in: .whitespaces) == "0" { return 0 }
        return IncomeMath.positive(text)
    }
    private func switchMonth(_ delta: Int) { if !draft.isEmpty { save(BudgetStore.budgets(records).first { $0.month == month }) }; month = BudgetMath.next(month, by: delta); message = "" }
    private func fill(_ values: [String: Int64]) {
        draft = Dictionary(uniqueKeysWithValues: categories.map { ($0, values[$0].map { String($0 / 100) } ?? "") })
        message = values.isEmpty ? "Лимиты очищены — нажми «Сохранить бюджет»." : "Заполнено по факту прошлого месяца — поправь и сохрани."
    }
    private func save(_ existing: MonthBudget?) {
        var budget = existing ?? MonthBudget(month: month)
        for (category, text) in draft {
            if let value = Self.cents(text), value > 0 { budget.limits[category] = value } else { budget.limits[category] = nil }
        }
        do { try BudgetStore.save(budget, records: records, context: context); draft = [:]; message = "Бюджет сохранён." }
        catch { context.rollback(); message = "Не удалось сохранить бюджет." }
    }
    private func copy(_ budget: MonthBudget?) {
        guard let budget else { return }
        let target = BudgetMath.next(month)
        var copy = BudgetStore.budgets(records).first { $0.month == target } ?? MonthBudget(month: target)
        copy.limits = budget.limits
        do { try BudgetStore.save(copy, records: records, context: context); message = "Скопировано на " + Charity.title(target) + "." }
        catch { message = "Не удалось скопировать." }
    }
}
