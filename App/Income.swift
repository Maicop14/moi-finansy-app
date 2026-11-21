import SwiftUI
import SwiftData

// Cash, cards and bank accounts, plus the project account (its money counts as cash).
let liquidAccountKeys = Set([0, 1, 2, 3, 4, 5, 6].map { "excel-20260901-\($0)" } + [ResetSeed.coffeeKey])

enum IncomeKind: String, CaseIterable { case salary = "Зарплата", savings = "Накопительный счёт", deposit = "Вклад", other = "Дополнительный доход"
    var bank: Bool { self == .savings || self == .deposit }
}

@Model final class IncomePlan {
    var title = ""
    var type = ""
    var amount: Int64 = 0
    var rateBP = 0
    var start = Date()
    var payout = Date()
    var monthly = false
    var exempt = false
    var bankExemptionReason: String?
    var passive = false
    init() {}
    var kind: IncomeKind { IncomeKind(rawValue: type) ?? .other }
    var gross: Int64 {
        if kind.bank { return IncomeMath.interest(amount, rateBP, start, payout) }
        let months = 13 - IncomeMath.calendar.component(.month, from: payout)
        return amount * Int64(monthly ? months : 1)
    }
}

enum IncomeMath {
    static var calendar: Calendar { Calendar(identifier: .gregorian) }
    static func rounded(_ value: Decimal) -> Int64 {
        var input = value, result = Decimal()
        NSDecimalRound(&result, &input, 0, .plain)
        return NSDecimalNumber(decimal: result).int64Value
    }

    // Interest accrues from the day after opening through the payout date.
    static func interest(_ principal: Int64, _ bp: Int, _ open: Date, _ end: Date) -> Int64 {
        let c = calendar, last = c.startOfDay(for: end)
        var day = c.date(byAdding: .day, value: 1, to: c.startOfDay(for: open))!
        let stop = c.date(byAdding: .day, value: 1, to: last)!
        var result = Decimal.zero
        while day < stop, let year = c.dateInterval(of: .year, for: day) {
            let boundary = min(stop, year.end)
            let days = c.dateComponents([.day], from: day, to: boundary).day!
            let denominator = c.dateComponents([.day], from: year.start, to: year.end).day!
            result += Decimal(principal) * Decimal(bp) * Decimal(days) / Decimal(10_000 * denominator)
            day = boundary
        }
        return rounded(result)
    }

    static func tax(_ cents: Int64, passive: Bool = false) -> Int64 {
        let tiers = passive ? [(0,13),(2_400_000,15)] : [(0,13),(2_400_000,15),(5_000_000,18),(20_000_000,20),(50_000_000,22)]
        var total = Decimal.zero
        for (i, tier) in tiers.enumerated() {
            let ceiling = i + 1 < tiers.count ? Int64(tiers[i+1].0) * 100 : cents
            let portion = max(0, min(cents, ceiling) - Int64(tier.0) * 100)
            total += Decimal(portion) * Decimal(tier.1) / 10_000
        }
        return rounded(total) * 100
    }

    static func annual(_ plans: [IncomePlan], keyBP: Int) -> (gross: Int64, regularTax: Int64, passiveTax: Int64) {
        var gross: Int64 = 0, regular: Int64 = 0, interest: Int64 = 0, passive: Int64 = 0
        for plan in plans {
            let value = plan.gross
            gross += value
            if plan.exempt { continue }
            if plan.kind.bank {
                interest += value
            } else if plan.passive { passive += value } else { regular += value }
        }
        let taxableInterest = max(0, interest - Int64(keyBP) * 10_000)
        return (gross, tax(regular), tax(taxableInterest + passive, passive: true))
    }

    static func bankMode(_ reason: String, atRateBP rate: Int) -> String {
        if reason == "escrow" { return reason }
        if (reason == "lowRate" || reason == "legacyBank"), rate <= 100 { return reason }
        return "regular"
    }

    static func positive(_ text: String) -> Int64? {
        guard !text.contains("-"), !text.contains("−"), let value = BankRead.cents(text), value > 0 else { return nil }
        return value
    }
}

private struct IncomeSelection: Identifiable { let id = UUID(); var plan: IncomePlan? }

struct IncomeScreen: View {
    static func kindLine(_ plan: IncomePlan) -> String {
        if plan.kind.bank {
            let rate: String = (Decimal(plan.rateBP) / 100).formatted()
            return "\(plan.kind.rawValue) · \(rate)% годовых"
        }
        return plan.monthly ? plan.kind.rawValue + " · ежемесячно до декабря" : plan.kind.rawValue
    }
    @Query(sort: \IncomePlan.payout) private var plans: [IncomePlan]
    let entries: [Entry]
    let accounts: [AccountBalance]
    let addReceipt: () -> Void
    @State private var year = IncomeMath.calendar.component(.year, from: .now)
    @State private var selection: IncomeSelection?
    var body: some View {
        let selected = plans.filter { IncomeMath.calendar.component(.year, from: $0.payout) == year }
        let receipts = entries.filter { $0.income && IncomeMath.calendar.component(.year, from: $0.date) == year }
        Stepper("Год выплат · " + String(year), value: $year, in: 2025...2099)
        .sheet(item: $selection) { choice in IncomeEditor(plan: choice.plan, year: year, accounts: accounts) }
        IncomeTotals(plans: selected, year: year).id(year)
        HStack {
            Text("Источники дохода").font(.title3.bold())
            Spacer()
            Button("Добавить") { selection = IncomeSelection() }.buttonStyle(.borderedProminent)
        }
        if selected.isEmpty { Text("Добавь зарплату до налога, вклад или другой источник за выбранный год.").foregroundStyle(.secondary) }
        ForEach(selected) { plan in
            Button { selection = IncomeSelection(plan: plan) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.title).font(.headline)
                    Text(Self.kindLine(plan))
                    Text(plan.payout, style: .date).font(.caption)
                    Text("Ожидается " + money(plan.gross)).bold()
                }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain)
        }
        Divider()
        LabeledContent("Поступило по операциям", value: money(receipts.reduce(0) { $0 + $1.cents })).font(.headline)
        Text("Прогноз не меняет остатки. Здесь учитываются сохранённые и импортированные поступления.").font(.caption).foregroundStyle(.secondary)
        Button("Записать поступление", action: addReceipt)
        ForEach(receipts) { receipt in
            LabeledContent { Text(money(receipt.cents)) } label: {
                Text(receipt.category)
                Text(receipt.date, style: .date)
            }
        }

    }
}

private struct IncomeTotals: View {
    let plans: [IncomePlan]
    let year: Int
    @AppStorage private var rate: String
    init(plans: [IncomePlan], year: Int) {
        self.plans = plans; self.year = year
        _rate = AppStorage(wrappedValue: year == 2025 ? "21" : year == 2026 ? "16" : "", "income.rate.\(year)")
    }
    var body: some View {
        let bp = IncomeMath.positive(rate)
        let totals = IncomeMath.annual(plans, keyBP: Int(min(bp ?? 0, 10_000)))
        let available = !plans.contains { $0.kind.bank && !$0.exempt } || (bp != nil && bp! <= 10_000)
        VStack(alignment: .leading, spacing: 10) {
            Text("Прогноз за год").font(.title3.bold())
            LabeledContent("До налога", value: money(totals.gross))
            LabeledContent("НДФЛ по основной шкале", value: money(totals.regularTax))
            LabeledContent("НДФЛ по пассивным доходам", value: available ? money(totals.passiveTax) : "Укажи ставку ЦБ")
            if available { LabeledContent("После налога", value: money(totals.gross - totals.regularTax - totals.passiveTax)).bold() }
            Divider()
            LabeledContent("Максимальная ставка ЦБ, %") { TextField("%", text: $rate).textFieldStyle(.roundedBorder).frame(width: 72) }
            if let bp, bp <= 10_000 { Text("Необлагаемые проценты за год · " + money(bp * 10_000)).font(.subheadline) }
            Text("Для резидента РФ, по введённым источникам, без индивидуальных вычетов. Для вкладов берётся максимум ключевой ставки на 1-е число месяцев года. До конца года он может измениться.").font(.caption).foregroundStyle(.secondary)
            Link("Правила расчёта ФНС", destination: URL(string: "https://www.nalog.gov.ru/nu/")!)
        }.padding().background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct IncomeEditor: View {
    @Environment(\.modelContext) var context
    @Environment(\.dismiss) var dismiss
    let plan: IncomePlan?
    let year: Int
    let accounts: [AccountBalance]
    @State var kind: IncomeKind
    @State var title: String
    @State var amount: String
    @State var rate: String
    @State var start: Date
    @State var payout: Date
    @State var monthly: Bool
    @State var taxMode: String
    @State var error = ""
    @State var deleting = false

    init(plan: IncomePlan?, year: Int, accounts: [AccountBalance]) {
        self.plan = plan; self.year = year; self.accounts = accounts
        _kind = State(initialValue: plan?.kind ?? .salary)
        _title = State(initialValue: plan?.title ?? "")
        _amount = State(initialValue: plan.map { String(describing: Decimal($0.amount)/100) } ?? "")
        _rate = State(initialValue: plan.map { String(describing: Decimal($0.rateBP)/100) } ?? "")
        let calendar = IncomeMath.calendar
        let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let date = calendar.component(.year, from: .now) == year ? Date.now : first
        _payout = State(initialValue: plan?.payout ?? date)
        _start = State(initialValue: plan?.start ?? calendar.date(byAdding: .month, value: -1, to: date)!)
        _monthly = State(initialValue: plan?.monthly ?? false)
        if let plan, plan.kind.bank, plan.exempt {
            let legacyMode = plan.rateBP > 100 ? "escrow" : "legacyBank"
            _taxMode = State(initialValue: IncomeMath.bankMode(plan.bankExemptionReason ?? legacyMode, atRateBP: plan.rateBP))
        } else {
            _taxMode = State(initialValue: plan?.exempt == true ? "exempt" : plan?.passive == true ? "passive" : "regular")
        }
    }

    var validAmount: Int64? { IncomeMath.positive(amount) }
    var basisPoints: Int { Int(min(IncomeMath.positive(rate) ?? 0, 100_001)) }
    var validDates: Bool {
        let c = IncomeMath.calendar
        return c.startOfDay(for: payout) > c.startOfDay(for: start) && c.startOfDay(for: payout) <= c.date(byAdding: .month, value: 15, to: c.startOfDay(for: start))!
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Вид дохода", selection: $kind) { ForEach(IncomeKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                TextField("Название источника", text: $title)
                if kind.bank {
                    Menu("Подставить название и остаток счёта") {
                        ForEach(accounts.filter { liquidAccountKeys.contains($0.id) && $0.position.amount > 0 }) { account in
                            Button(account.position.title) {
                                title = account.position.title
                                amount = String(describing: Decimal(account.position.amount)/100)
                            }
                        }
                    }
                }
                LabeledContent(kind.bank ? "Остаток, ₽" : "Сумма до налога, ₽") { TextField("0,00", text: $amount).multilineTextAlignment(.trailing) }
                if kind.bank {
                    LabeledContent("Ставка годовых, %") { TextField("0,00", text: $rate).multilineTextAlignment(.trailing) }
                    DatePicker("Дата внесения", selection: $start, displayedComponents: .date)
                } else {
                    Toggle("Каждый месяц до конца года", isOn: $monthly)
                }
                let c = IncomeMath.calendar
                let first = c.date(from: DateComponents(year: year, month: 1, day: 1))!
                let last = c.date(from: DateComponents(year: year, month: 12, day: 31, hour: 23, minute: 59))!
                DatePicker(!kind.bank && monthly ? "Первая выплата" : "Дата выплаты", selection: $payout, in: first...last, displayedComponents: .date)
                if kind.bank {
                    if validDates, let principal = validAmount, (1...10_000).contains(basisPoints) {
                        LabeledContent("Ожидаемые проценты", value: money(IncomeMath.interest(principal, basisPoints, start, payout))).bold()
                    }
                    Picker("Основание для НДФЛ", selection: $taxMode) {
                        Text("Общие правила").tag("regular")
                        Text("Счёт эскроу").tag("escrow")
                        if basisPoints <= 100 {
                            Text("Ставка весь год до 1% включительно").tag("lowRate")
                            if taxMode == "legacyBank" { Text("Ранее подтверждённое освобождение").tag("legacyBank") }
                        }
                    }.onChange(of: basisPoints) { _, newRate in
                        taxMode = IncomeMath.bankMode(taxMode, atRateBP: newRate)
                    }
                    Text("Прогноз для рублёвого счёта в российском банке. Постоянные остаток и ставка, простые проценты с выплатой в конце периода до 15 месяцев. Для ежемесячных выплат добавляй отдельные периоды. Счета эскроу и ставки до 1% включительно за весь налоговый период освобождены от НДФЛ.")
                    if !validDates { Text("Дата выплаты должна быть позже внесения и в пределах 15 месяцев.").foregroundStyle(.red) }
                } else if kind == .other {
                    Picker("Налоговый режим", selection: $taxMode) {
                        Text("Основная шкала НДФЛ").tag("regular")
                        Text("Пассивная база по п. 6 ст. 210 НК").tag("passive")
                        Text("Освобождён от НДФЛ").tag("exempt")
                    }
                    Text("Для облагаемого дополнительного дохода укажи сумму после применимых расходов. Налог по НПД и УСН здесь не рассчитывается.").font(.caption)
                }
                if plan != nil { Button("Удалить источник", role: .destructive) { deleting = true } }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped).navigationTitle(plan == nil ? "Новый источник" : "Источник дохода")
                .onChange(of: kind) { _, _ in taxMode = "regular" }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") { save() }
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validAmount == nil || (kind.bank && (!validDates || !(1...10_000).contains(basisPoints))))
                    }
                }
                .confirmationDialog("Удалить источник дохода?", isPresented: $deleting) {
                    Button("Удалить", role: .destructive) { if let plan { context.delete(plan); commit() } }
                }
        }
        #if os(macOS)
        .frame(minWidth: 470, minHeight: 530)
        #endif
    }

    func save() {
        guard let amount = validAmount else { return }
        let item = plan ?? IncomePlan()
        if plan == nil { context.insert(item) }
        item.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.type = kind.rawValue; item.amount = amount; item.rateBP = kind.bank ? basisPoints : 0
        item.start = start; item.payout = payout; item.monthly = !kind.bank && monthly
        let bankMode = IncomeMath.bankMode(taxMode, atRateBP: basisPoints)
        item.bankExemptionReason = kind.bank ? bankMode : nil
        item.exempt = kind.bank ? bankMode != "regular" : (kind == .other && taxMode == "exempt")
        item.passive = kind == .other && taxMode == "passive"
        commit()
    }
    func commit() {
        do { try context.save(); dismiss() } catch { context.rollback(); self.error = "Не удалось сохранить изменения." }
    }
}
