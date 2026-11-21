import SwiftUI
import SwiftData

/// Presentation mode for showing the app to others, started only with the `-demoMode` launch argument.
/// It keeps everything in memory with fictional data, never opens the real store, skips the lock,
/// hides every amount and the owner's name, and shows a caption for each section.
enum DemoMode {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-demoMode")
    static let mask = "••••••"
    static func masked(_ symbol: String = "₽") -> String { mask + " " + symbol }

    static func caption(_ page: String) -> String {
        switch page {
        case "Главная": "Главная: деньги на руках, все средства и чистый капитал"
        case "Операции": "Детализация расходов: диаграмма, подкатегории, выделение"
        case "Регулярные платежи": "Регулярные платежи с напоминаниями"
        case "Бюджет": "Бюджет на месяц: обязательные платежи и лимиты"
        case "Кредиты": "Кредитки и проект — рассрочка самому себе"
        case "Капитал": "Капитал: динамика, структура, уведомления и копии"
        case "Благотворительность": "Благотворительность: 10% и напоминания"
        case "Доходы": "Доходы и прогноз налога"
        case "Счета": "Все счета и карты"
        case "Инвестиции": "Металлы и крипта по рыночной цене"
        default: page
        }
    }

    @MainActor static func seed(_ context: ModelContext, now: Date = .now) throws {
        guard try context.fetch(FetchDescriptor<Checkpoint>()).isEmpty else { return }
        let calendar = Calendar.autoupdatingCurrent
        let monthStart = calendar.dateInterval(of: .month, for: now)!.start
        func key(_ i: Int) -> String { ResetSeed.key(i) }
        let accounts: [(String, String, Int64, Bool)] = [
            (key(0), "Наличные", 1_200_000, false), (key(1), "Карта A", 2_350_000, false), (key(2), "Карта B", 800_000, false),
            (key(3), "Счёт C", 4_100_000, false), (key(4), "Валютная карта", 1_600_000, false), (key(5), "Накопительный счёт", 35_000_000, false),
            (key(6), "Карта D", 450_000, false), (key(7), "Золото", 9_000_000, false), (key(8), "Серебро", 700_000, false),
            (key(9), "Обеспечение", 0, false), (key(10), "Имущество", 3_000_000, false), (key(11), "Цифровые активы", 0, false),
            (key(12), "Друг 1", 5_000_000, false), (key(13), "Друг 2", 1_000_000, false), (key(14), "Друг 3", 500_000, false),
            (key(15), "Кредитная карта 1", 12_000_000, true), (key(16), "Кредитная карта 2", 6_000_000, true), (key(17), "Кредитная карта 3", 2_500_000, true),
            (ResetSeed.coffeeKey, "Кофемашина (проект)", 5_500_000, false),
        ]
        for (k, title, amount, debt) in accounts {
            context.insert(Checkpoint(position: .init(title: title, amount: amount, debt: debt), key: k, date: monthStart))
        }
        let spending: [(Int, Int64, String, String?, String)] = [
            (1, 320_000, "Продукты", "Супермаркеты", "Супермаркет"), (3, 180_000, "Продукты", "Доставка продуктов", "Доставка"),
            (5, 260_000, "Продукты", "Супермаркеты", "Гипермаркет"), (2, 45_000, "Кафе", "Кофейни", "Кофейня"),
            (4, 90_000, "Кафе", "Фастфуд", "Бургерная"), (6, 210_000, "Кафе", "Рестораны", "Ресторан"), (7, 38_000, "Кафе", "Кофейни", "Кофейня"),
            (2, 70_000, "Транспорт", "Такси", "Такси"), (8, 25_000, "Транспорт", "Самокаты", "Самокаты"), (9, 40_000, "Транспорт", "Местный транспорт", "Метро"),
            (3, 120_000, "Досуг", "Книги и канцтовары", "Книжный"), (10, 150_000, "Красота", nil, "Салон"), (6, 99_000, "Подписки", "Сервисы", "Музыка"),
            (5, 80_000, "Связь", "Мобильная связь", "Оператор"), (11, 230_000, "Маркетплейсы", nil, "Маркетплейс"), (12, 140_000, "Дом", "Ремонт и мебель", "Хозмаг"),
        ]
        for (day, cents, category, sub, merchant) in spending {
            let date = min(calendar.date(byAdding: .day, value: day - 1, to: monthStart)!.addingTimeInterval(12 * 3600), now.addingTimeInterval(-3600))
            let entry = Entry(cents: cents, flow: .expense, category: category, note: merchant, date: date)
            entry.accountKey = key(1); entry.subcategory = sub
            context.insert(entry)
        }
        let salary = Entry(cents: 12_000_000, flow: .income, category: "Зарплата", note: "Работа", date: min(monthStart.addingTimeInterval(4 * 86_400), now))
        salary.accountKey = key(3)
        context.insert(salary)
        let plan = IncomePlan(); plan.title = "Зарплата"; plan.type = IncomeKind.salary.rawValue; plan.amount = 12_000_000
        plan.monthly = true; plan.payout = calendar.date(byAdding: .month, value: 1, to: monthStart)!.addingTimeInterval(13 * 86_400)
        context.insert(plan)

        let next = BudgetMath.next(BudgetMath.key(now))
        let project = SavingsProject(id: ResetSeed.projectID, title: "Кофемашина", total: 5_500_000, months: 10, firstMonth: next, accountKey: ResetSeed.coffeeKey)
        context.insert(try FinanceRecord(SavingsProject.kind, project, id: project.id))
        func monthDay(_ d: Int) -> Date { calendar.date(byAdding: .day, value: d - 1, to: calendar.date(byAdding: .month, value: 1, to: monthStart)!)!.addingTimeInterval(12 * 3600) }
        let recurring = [
            RecurringPayment(title: "Мобильная связь", cents: 80_000, accountKey: key(1), category: "Связь", subcategory: "Мобильная связь", anchorDay: 5, next: monthDay(5)),
            RecurringPayment(title: "Интернет", cents: 70_000, accountKey: key(1), category: "Связь", subcategory: "Интернет и ТВ", anchorDay: 10, next: monthDay(10)),
            RecurringPayment(title: "Музыка", cents: 999, currency: "USD", accountKey: key(4), category: "Подписки", subcategory: "Сервисы", anchorDay: 15, next: monthDay(15)),
            RecurringPayment(title: "Спортзал", cents: 300_000, accountKey: key(2), category: "Досуг", subcategory: "Тренировки", unit: .month, every: 3, anchorDay: 20, next: monthDay(20)),
        ]
        for item in recurring { context.insert(try FinanceRecord(RecurringPayment.kind, item, id: item.id)) }
        context.insert(try FinanceRecord(MonthBudget.kind, MonthBudget(month: next, limits: ["Продукты": 900_000, "Кафе": 450_000, "Транспорт": 200_000, "Досуг": 250_000]), id: UUID()))
        try context.save()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "breakdown.pins")
        defaults.set(try? JSONEncoder().encode([PaymentDue(id: "demo-1", title: "Кредитная карта 1", amount: 2_000_000, minimum: 300_000, due: monthDay(9))]),
                     forKey: PaymentDue.storageKey)
        defaults.set([project.title], forKey: SavingsProject.activeKey)
        defaults.set(Date.now.timeIntervalSince1970, forKey: ReminderKeys.lastBackup)
    }
}

/// Caption pill shown at the top in demo mode.
struct DemoCaption: View {
    let text: String
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Palette.accent.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            .padding(.horizontal, 16).padding(.top, 4)
            .allowsHitTesting(false).accessibilityHidden(true)
            .animation(.snappy, value: text)
    }
}
