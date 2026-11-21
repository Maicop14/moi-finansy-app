import SwiftUI
#if os(iOS)
import UserNotifications
#endif

struct CharityMonth: Identifiable {
    let id: Int
    var earned: Int64 = 0
    var expenses: Int64 = 0
    var paid: Int64 = 0
    var movements = 0
    var assessment: Int64 {
        let base = max(0, earned - expenses)
        return base / 10 + (base % 10 >= 5 ? 1 : 0)
    }
    var remaining: Int64 { max(0, assessment - paid) }
    var due: Date {
        Charity.calendar.date(byAdding: DateComponents(month: 1, day: 14), to: Charity.start(id))!
    }
}

enum Charity {
    static let category = "Благотворительность"
    static var calendar: Calendar { Calendar(identifier: .gregorian) }
    static func key(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return parts.year! * 100 + parts.month!
    }
    static func start(_ key: Int) -> Date {
        calendar.date(from: DateComponents(year: key / 100, month: key % 100, day: 1))!
    }
    static func title(_ key: Int) -> String {
        start(key).formatted(.dateTime.locale(Locale(identifier: "ru_RU")).month(.wide).year())
    }
    static func previous(_ date: Date) -> Int {
        key(calendar.date(byAdding: .month, value: -1, to: start(key(date)))!)
    }
    static func options(date: Date, periods: [Int], selected: Int?) -> [Int] {
        var keys = Set(periods.filter { $0 < key(date) })
        if let selected { keys.insert(selected) }
        let first = start(key(date))
        for delta in 1...12 { keys.insert(key(calendar.date(byAdding: .month, value: -delta, to: first)!)) }
        return keys.sorted(by: >)
    }
    static func isDonation(_ value: String) -> Bool { BankRead.clean(value) == BankRead.clean(category) }
    static func includes(_ flow: Flow, _ category: String) -> Bool {
        switch flow {
        case .income:
            return ["зарплата", "заработная плата", "чистая прибыль от торговли", "другой заработок"].contains(BankRead.clean(category))
        case .expense:
            return !["закупка товара", "инвестиции", "погашение кредита", "перевод"].contains(BankRead.clean(category))
        case .transfer: return false
        }
    }
    static func report(_ entries: [Entry], at today: Date) -> (upcoming: CharityMonth, history: [CharityMonth]) {
        let next = calendar.component(.day, from: today) <= 15 ? previous(today) : key(today)
        var months = [next: CharityMonth(id: next)]
        for entry in entries where entry.date <= today && entry.cents > 0 {
            guard let flow = Flow(rawValue: entry.kind), flow != .transfer else { continue }
            let month = key(entry.date)
            let donation = flow == .expense && isDonation(entry.category)
            if donation || (entry.charityIncluded ?? includes(flow, entry.category)) {
                months[month, default: CharityMonth(id: month)].movements += 1
                if flow == .income { months[month]!.earned += entry.cents }
                else { months[month]!.expenses += entry.cents }
            }
            if donation, let target = entry.charityMonth, target < month {
                months[target, default: CharityMonth(id: target)].paid += entry.cents
            }
        }
        return (months[next]!, months.values.filter { $0.id < next }.sorted { $0.id > $1.id })
    }
}

struct CharityScreen: View {
    let entries: [Entry]
    let accounts: [AccountBalance]
    @State private var payment: CharityMonth?
    @State private var editing: Entry?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let today = Date.now
            let report = Charity.report(entries, at: today)
            let upcoming = report.upcoming
            let estimate = upcoming.id == Charity.key(today)
            let periods = report.history.map(\.id) + [upcoming.id]
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("К " + upcoming.due.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month(.wide).year())).font(.headline)
                    Text(money(upcoming.remaining)).font(.largeTitle.bold()).monospacedDigit()
                    Text((estimate ? "Предварительно за " : "Начисление за ") + Charity.title(upcoming.id))
                    details(upcoming)
                    if estimate { Text("Сумма изменится, если до конца месяца появятся операции.").font(.caption) }
                    if upcoming.movements == 0 { Text("За месяц пока нет учтённого заработка или расходов.").font(.caption) }
                    if !estimate && upcoming.remaining > 0 { record(upcoming) }
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 18))
                LabeledContent("Доплатить за прошлые месяцы", value: money(report.history.reduce(0) { $0 + $1.remaining })).font(.headline)
                ForEach(report.history) { month in
                    DisclosureGroup {
                        details(month)
                        if month.paid > month.assessment { LabeledContent("Сверх начисления", value: money(month.paid - month.assessment)) }
                        if month.remaining > 0 { record(month) }
                    } label: {
                        LabeledContent(Charity.title(month.id), value: money(month.remaining))
                    }
                    Divider()
                }
                Text("В расчёт входят зарплата на руки, чистая прибыль и другие отмеченные заработки за вычетом расходов. Состав расчёта можно изменить в операции.").font(.caption).foregroundStyle(.secondary)
                let donations = entries.filter { !$0.income && !$0.transfer && Charity.isDonation($0.category) && $0.cents > 0 }
                if !donations.isEmpty {
                    Text("Перечисления").font(.headline)
                    ForEach(donations) { entry in
                        Button { editing = entry } label: {
                            LabeledContent {
                                Text(money(entry.cents))
                            } label: {
                                Text(entry.date, style: .date)
                                Text(entry.charityMonth.map(Charity.title) ?? "Выбрать месяц начисления").font(.caption)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                CharityReminders()
            }
            .sheet(item: $payment) { month in EntryForm(accounts: accounts, donation: month, periods: periods) }
            .sheet(item: $editing) { entry in EntryForm(accounts: accounts, existing: entry, periods: periods) }
        }
    }

    private func record(_ month: CharityMonth) -> some View {
        Button("Записать перечисление") { payment = month }.buttonStyle(.bordered)
    }

    private func details(_ month: CharityMonth) -> some View {
        VStack(spacing: 5) {
            LabeledContent("Заработок", value: money(month.earned))
            LabeledContent("Расходы", value: money(month.expenses))
            LabeledContent("Начислено 10%", value: money(month.assessment))
            LabeledContent("Перечислено за месяц", value: money(month.paid))
        }.font(.subheadline).foregroundStyle(.secondary)
    }
}

