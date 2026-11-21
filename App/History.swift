import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts

struct Archive: Decodable {
    struct Line: Decodable {
        let title: String
        let amount: Int64?
        let note: String
    }
    struct Month: Decodable {
        let title: String
        let capital: Int64
        let note: String
        let lines: [Line]
    }
    struct Position: Codable, Equatable {
        var title: String
        var amount: Int64
        var debt: Bool
    }
    let months: [Month]
    let positions: [Position]

    static var resources: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }

    // Keep both files from the same snapshot. An incomplete local archive must
    // never mix real account positions with the demonstration workbook.
    static func reportURL(_ name: String, _ ext: String) -> URL? {
        if DemoMode.isOn {
            return resources.resourceURL?.appendingPathComponent("ArchiveResources/Demo").appendingPathComponent(name).appendingPathExtension(ext)
        }
        if let id = UserDefaults.standard.string(forKey: "backup.seed"), let uuid = UUID(uuidString: id) {
            return seedDirectory(uuid).appendingPathComponent(name).appendingPathExtension(ext)
        }
        guard let directory = resources.resourceURL?.appendingPathComponent("ArchiveResources") else { return nil }
        let local = directory.appendingPathComponent("Local")
        let location = FileManager.default.fileExists(atPath: local.path) ? local : directory.appendingPathComponent("Demo")
        let url = location.appendingPathComponent(name).appendingPathExtension(ext)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func seedDirectory(_ id: UUID) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("RestoredArchives").appendingPathComponent(id.uuidString)
    }

    private final class Box { let value: Archive; init(_ value: Archive) { self.value = value } }
    nonisolated(unsafe) private static let cache = NSCache<NSURL, Box>()
    static var bundled: Archive? {
        guard let url = Archive.reportURL("history", "json") else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached.value }
        guard
              let data = try? Data(contentsOf: url) else { return nil }
        guard let value = try? JSONDecoder().decode(Archive.self, from: data) else { return nil }
        cache.setObject(Box(value), forKey: url as NSURL)
        return value
    }
}

@Model final class Checkpoint {
    var key: String = ""
    var title: String = ""
    var amount: Int64 = 0
    var debt: Bool = false
    var date: Date = Date()
    var valuationSource: Data?
    var marketDelta: Int64?
    var tieBreaker: String = UUID().uuidString

    init(position: Archive.Position, key: String, date: Date) {
        self.key = key
        self.title = position.title
        self.amount = position.amount
        self.debt = position.debt
        self.date = date
    }
}

struct AccountBalance: Identifiable, Equatable {
    var id: String
    var position: Archive.Position
    var cutoff: Date
}

extension Entry {
    /// Signed change in money on the account, before converting to a liability balance.
    func cashDelta(for key: String) -> Int64 {
        var delta: Int64 = 0
        if accountKey == key { delta = income ? cents : -cents }
        if transfer && destinationKey == key { delta += cents }
        return delta
    }
}

func balances(archive: Archive, checkpoints: [Checkpoint], entries: [Entry]) -> [AccountBalance] {
    let start = ISO8601DateFormatter().date(from: "2026-09-01T00:00:00+03:00")!
    var accounts = Dictionary(uniqueKeysWithValues: archive.positions.enumerated().map { index, position in
        let key = "excel-20260901-\(index)"
        return (key, AccountBalance(id: key, position: position, cutoff: start))
    })
    for item in checkpoints.sorted(by: { ($0.date, $0.tieBreaker) < ($1.date, $1.tieBreaker) }) {
        accounts[item.key] = AccountBalance(id: item.key, position: .init(title: item.title, amount: item.amount, debt: item.debt), cutoff: item.date)
    }
    for entry in entries {
        func post(to key: String?) {
            guard let key, let account = accounts[key], entry.date > account.cutoff else { return }
            let delta = entry.cashDelta(for: key)
            accounts[key]?.position.amount += account.position.debt ? -delta : delta
        }
        post(to: entry.accountKey)
        if entry.transfer && entry.destinationKey != entry.accountKey { post(to: entry.destinationKey) }
    }
    return accounts.values.sorted { ($0.position.title, $0.id) < ($1.position.title, $1.id) }
}

/// Asset groups for the capital structure.
enum AssetClass: String, CaseIterable, Identifiable {
    case property = "Имущество", investments = "Инвестиции", money = "Деньги", loans = "Займы выданные", other = "Прочие"
    var id: Self { self }
    var color: Color {
        switch self {
        case .money: Palette.accent
        case .investments: Color(red: 0.84, green: 0.55, blue: 0.13)
        case .loans: Color(red: 0.13, green: 0.62, blue: 0.66)
        case .property: Color(red: 0.49, green: 0.40, blue: 0.80)
        case .other: Color(red: 0.62, green: 0.66, blue: 0.72)
        }
    }
    static let loanKeys: Set<String> = ["excel-20260901-12", "excel-20260901-13", "excel-20260901-14"]
    static let propertyKeys: Set<String> = ["excel-20260901-10"]
    static func of(_ account: AccountBalance) -> AssetClass {
        if liquidAccountKeys.contains(account.id) || account.id == "excel-20260901-4" { return .money }
        if Holding.allCases.contains(where: { $0.id == account.id }) { return .investments }
        if loanKeys.contains(account.id) || account.id.hasPrefix("receivable-") { return .loans }
        if propertyKeys.contains(account.id) { return .property }
        return .other
    }
}

/// One income or expense row for the capital ratios (transfers and lot postings excluded).
struct CashFlowRow {
    let date: Date
    let cents: Int64
    let income: Bool
}

/// Breakdown under the home screen «Чистый капитал»: own assets, receivables, minus liabilities.
struct NetWorthRows {
    let rows: [(String, Int64)]
    init(summary: CapitalSummary, accounts: [AccountBalance]) {
        let receivables = summary.slices.filter { $0.kind == .loans }.reduce(Int64(0)) { $0 + $1.cents }
        rows = [("Активы: деньги, металлы, имущество", summary.assets - receivables),
                ("Мне должны", receivables),
                ("Обязательства", -summary.debts)]
    }
}

/// Figures behind the capital screen: balance sheet totals, structure, ratios and history.
struct CapitalSummary {
    struct Slice: Identifiable { let kind: AssetClass; let cents: Int64; var id: AssetClass { kind } }
    struct Point: Identifiable { let index: Int; let title: String; let label: String; let month: Date?; let cents: Int64; let current: Bool; var id: Int { index } }
    struct Liability: Identifiable { let id: String; let title: String; let cents: Int64 }

    let assets: Int64
    let debts: Int64
    let cash: Int64
    let slices: [Slice]
    let history: [Point]
    let liabilities: [Liability]
    /// Average monthly expenses over the three full months before `now`, nil without expenses.
    let averageExpenses: Int64?
    let monthIncome: Int64
    let monthExpenses: Int64
    var net: Int64 { assets - debts }
    var previous: Point? { history.last(where: { !$0.current }) }
    var change: Int64? { previous.map { net - $0.cents } }
    var changeShare: Double? {
        guard let previous, previous.cents != 0 else { return nil }
        return Double(net - previous.cents) / Double(abs(previous.cents))
    }
    var debtRatio: Double? { assets > 0 ? Double(debts) / Double(assets) : nil }
    /// Months of average expenses covered by cash on hand.
    var runway: Double? { averageExpenses.map { Double(cash) / Double($0) } }
    var savingsRate: Double? { monthIncome > 0 ? Double(monthIncome - monthExpenses) / Double(monthIncome) : nil }
    /// Last 12 months of points (current one included).
    var lastYear: [Point] { Array(history.suffix(12)) }
    /// Growth against the earliest point inside the last 12 months, with that point.
    var growth: (share: Double, since: Point)? {
        guard let base = lastYear.first(where: { !$0.current }), base.cents != 0 else { return nil }
        return (Double(net - base.cents) / Double(abs(base.cents)), base)
    }
    func share(_ cents: Int64) -> Double { assets > 0 ? Double(cents) / Double(assets) : 0 }
    func debtShare(_ cents: Int64) -> Double { debts > 0 ? Double(cents) / Double(debts) : 0 }

    /// `monthEnds` are net worth values at the end of months not covered by the archive.
    init(accounts: [AccountBalance], months: [Archive.Month], monthEnds: [(month: Date, cents: Int64)] = [], flows: [CashFlowRow] = [], now: Date = .now) {
        let owned = accounts.filter { !$0.position.debt }
        assets = owned.reduce(0) { $0 + $1.position.amount }
        debts = accounts.filter(\.position.debt).reduce(0) { $0 + $1.position.amount }
        cash = owned.filter { liquidAccountKeys.contains($0.id) }.reduce(0) { $0 + $1.position.amount }
        slices = AssetClass.allCases.compactMap { kind in
            let total = owned.filter { AssetClass.of($0) == kind }.reduce(Int64.zero) { $0 + $1.position.amount }
            return total > 0 ? Slice(kind: kind, cents: total) : nil
        }.sorted { $0.cents > $1.cents }
        liabilities = accounts.filter { $0.position.debt && $0.position.amount != 0 }
            .sorted { $0.position.amount > $1.position.amount }
            .map { Liability(id: $0.id, title: $0.position.title, cents: $0.position.amount) }

        var dated = months.map { (title: $0.title, month: Self.monthStart($0.title), cents: $0.capital) }
        let known = Set(dated.compactMap(\.month))
        for end in monthEnds.sorted(by: { $0.month < $1.month }) where !known.contains(end.month) {
            dated.append((title: Self.monthTitle(end.month), month: end.month, cents: end.cents))
        }
        var points = dated.enumerated().map { Point(index: $0.offset, title: $0.element.title, label: Self.shortMonth($0.element.title), month: $0.element.month, cents: $0.element.cents, current: false) }
        points.append(Point(index: points.count, title: "Сейчас", label: "Сейчас", month: nil, cents: assets - debts, current: true))
        history = points

        let calendar = Calendar(identifier: .gregorian)
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let window = calendar.date(byAdding: .month, value: -3, to: thisMonth) ?? thisMonth
        let spent = flows.filter { !$0.income && $0.date >= window && $0.date < thisMonth }.reduce(Int64.zero) { $0 + $1.cents }
        averageExpenses = spent > 0 ? spent / 3 : nil
        let current = flows.filter { $0.date >= thisMonth && $0.date <= now }
        monthIncome = current.filter(\.income).reduce(0) { $0 + $1.cents }
        monthExpenses = current.filter { !$0.income }.reduce(0) { $0 + $1.cents }
    }

    private static let monthNames = ["январь", "февраль", "март", "апрель", "май", "июнь", "июль", "август", "сентябрь", "октябрь", "ноябрь", "декабрь"]
    /// "Декабрь 2025" → 1 December 2025 (Moscow time); nil for other titles.
    static func monthStart(_ title: String) -> Date? {
        let parts = title.lowercased().split(separator: " ")
        guard parts.count == 2, let index = monthNames.firstIndex(of: String(parts[0])), let year = Int(parts[1]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        return calendar.date(from: DateComponents(year: year, month: index + 1, day: 1))
    }
    static func monthTitle(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        let parts = calendar.dateComponents([.year, .month], from: date)
        return monthNames[(parts.month ?? 1) - 1].capitalized + " " + String(parts.year ?? 0)
    }

    /// "Декабрь 2025" → "дек 25"; anything else stays as it is.
    static func shortMonth(_ title: String) -> String {
        let parts = title.split(separator: " ")
        guard parts.count == 2, parts[1].count == 4 else { return title }
        return parts[0].prefix(3).lowercased() + " " + parts[1].suffix(2)
    }

    /// Axis label for a month title: "Декабрь 2025" → "дек".
    static func axisMonth(_ title: String) -> String {
        title == "Сейчас" ? "сейчас" : String(shortMonth(title).prefix(3))
    }

    /// Axis-friendly amount: 1 250 000 → "1,3 млн ₽".
    static func compact(_ value: Double, symbol: String = "₽") -> String {
        if DemoMode.isOn { return DemoMode.masked(symbol) }
        let size = abs(value)
        let (scaled, suffix): (Double, String) = size >= 1e9 ? (size / 1e9, " млрд") : size >= 1e6 ? (size / 1e6, " млн") : size >= 1e3 ? (size / 1e3, " тыс.") : (size, "")
        return (value < 0 ? "−" : "") + scaled.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "ru_RU"))) + suffix + " " + symbol
    }
}

/// Month bridge from opening to closing net worth, built from the monthly report values.
struct CapitalBridge {
    struct Step: Identifiable {
        let id: Int
        let title: String
        let start: Int64
        let end: Int64
        let total: Bool
        var delta: Int64 { end - start }
    }
    let steps: [Step]
    /// Nil when the period has no detailed turnover (archive months) or no opening/closing value.
    init?(_ values: PeriodValues) {
        guard let opening = values.opening, let closing = values.closing, let quotes = values.quotes, let other = values.adjustments else { return nil }
        let items: [(String, Int64)] = [("Доходы", values.income), ("Расходы", -values.expenses), ("Результат по партиям", values.realized),
                                        ("Переоценка", quotes), ("Прочее и сверки", other)]
        var rows = [Step(id: 0, title: "Капитал на начало", start: 0, end: opening, total: true)]
        var running = opening
        for (index, item) in items.enumerated() {
            rows.append(Step(id: index + 1, title: item.0, start: running, end: running + item.1, total: false))
            running += item.1
        }
        rows.append(Step(id: rows.count, title: "Капитал на конец", start: 0, end: closing, total: true))
        steps = rows
    }
    /// The running total after all items equals the closing value.
    var balanced: Bool { steps.count >= 2 && steps[steps.count - 2].end == steps[steps.count - 1].end }
}

func percent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(1)).locale(Locale(identifier: "ru_RU")))
}

/// Card used across the capital screen: title, optional caption, content.
struct AnalyticsCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Palette.text)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Palette.secondary) }
            }
            content
        }.bankTile(16)
    }
}

struct PortfolioOverview: View {
    @Environment(\.modelContext) private var context
    let accounts: [AccountBalance]
    @Query private var entries: [Entry]
    @Query private var checkpoints: [Checkpoint]
    @State private var editing = false
    @State private var exporting = false
    @State private var exportProblem = false
    @State private var workbook: OriginalBudget?
    @AppStorage("display.currency") private var displayCode = DisplayCurrency.rub.rawValue
    @AppStorage("markets.prices") private var priceCache = Data()
    private var prices: MarketPrices { (try? JSONDecoder().decode(MarketPrices.self, from: priceCache)) ?? .initial }
    private var display: DisplayCurrency { DisplayCurrency.selected(displayCode, prices: prices) }
    private func shown(_ cents: Int64) -> String { display.format(cents, prices: prices) }

    /// Net worth at the end of each completed month after the archive (from 1 September 2026).
    private func monthEnds(_ archive: Archive) -> [(month: Date, cents: Int64)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        guard var month = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)) else { return [] }
        var result: [(month: Date, cents: Int64)] = []
        while let next = calendar.date(byAdding: .month, value: 1, to: month), next <= .now {
            let rows = balances(archive: archive, checkpoints: checkpoints.filter { $0.date < next }, entries: entries.filter { $0.date < next })
            result.append((month, rows.reduce(0) { $0 + ($1.position.debt ? -$1.position.amount : $1.position.amount) }))
            month = next
        }
        return result
    }

    var body: some View {
        if let archive = Archive.bundled {
            let flows = entries.filter { !$0.transfer && $0.lotEventID == nil }.map { CashFlowRow(date: $0.date, cents: $0.cents, income: $0.income) }
            // After the fresh start the old archive months are not the owner's history any more: the chart is built
            // from the daily net worth values recorded since then.
            let fresh = FreshStartMark.isSet && !DemoMode.isOn
            let summary = CapitalSummary(accounts: accounts, months: fresh ? [] : archive.months,
                                         monthEnds: fresh ? NetWorthHistory.monthEnds(now: .now) : monthEnds(archive), flows: flows)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Баланс на сегодня").font(.headline).foregroundStyle(Palette.text)
                        if let latest = accounts.map(\.cutoff).max() {
                            Text("Последняя сверка: " + latest.formatted(date: .numeric, time: .omitted))
                                .font(.caption).foregroundStyle(Palette.secondary)
                        }
                    }
                    Spacer()
                    CurrencySwitch()
                }
                kpiCard(summary)
                trendCard(summary)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { structureCard(summary); liabilitiesCard(summary) }
                    VStack(alignment: .leading, spacing: 16) { structureCard(summary); liabilitiesCard(summary) }
                }
                detailsCard(summary, archive: archive)
            }
            .animation(.snappy, value: displayCode)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fileExporter(isPresented: $exporting, document: workbook, contentType: OriginalBudget.type, defaultFilename: "Личный бюджет.xlsx") { result in
                if case .failure = result { exportProblem = true }
            }
            .alert("Не удалось сохранить исходный отчёт", isPresented: $exportProblem) { Button("ОК") {} }
            .sheet(isPresented: $editing) {
                Reconciliation(accounts: accounts) { rows, date, startingAccounts in
                    let checkpoints = try context.fetch(FetchDescriptor<Checkpoint>())
                    let entries = try context.fetch(FetchDescriptor<Entry>()).filter { $0.date <= date }
                    guard balances(archive: archive, checkpoints: checkpoints, entries: entries) == startingAccounts else {
                        throw ReconciliationError.accountsChanged
                    }
                    // Only rows the person changed or added become new checkpoints. Untouched
                    // accounts keep their cutoff, so later back-dated entries still move them.
                    for row in Reconciliation.changedRows(rows, from: startingAccounts) {
                        context.insert(Checkpoint(position: row.position, key: row.id, date: date))
                    }
                    do { try context.save() } catch { context.rollback(); throw error }
                }
            }
        } else {
            Text("Не удалось прочитать историю из Excel.").bankTile()
        }
    }

    private func kpiCard(_ summary: CapitalSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Чистый капитал").font(.subheadline).foregroundStyle(Palette.secondary)
            NetWorthChanges(net: summary.net) { shown($0) }
            Text(shown(summary.net)).font(.system(size: 34, weight: .bold)).monospacedDigit().foregroundStyle(Palette.text)
                .lineLimit(1).minimumScaleFactor(0.5).contentTransition(.numericText())
            if let delta = summary.change {
                let tone = delta > 0 ? Palette.positive : delta < 0 ? Palette.negative : Palette.secondary
                let share = summary.changeShare.map { " (" + ($0 > 0 ? "+" : "") + percent($0) + ")" } ?? ""
                Text(delta == 0 ? "Без изменений к отчёту «" + (summary.previous?.title ?? "") + "»"
                     : (delta > 0 ? "▲ +" : "▼ ") + shown(delta) + share + " к отчёту «" + (summary.previous?.title ?? "") + "»")
                    .font(.subheadline.weight(.medium)).foregroundStyle(tone)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                metric("Активы", shown(summary.assets), nil)
                metric("Обязательства", shown(summary.debts), nil)
                metric("Долговая нагрузка", summary.debtRatio.map(percent) ?? "—",
                       summary.debtRatio.map { $0 < 0.3 ? Palette.positive : $0 < 0.5 ? Color.orange : Palette.negative },
                       "Обязательства к активам")
                metric("Запас ликвидности", summary.runway.map { $0.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "ru_RU"))) + " мес." } ?? "нет данных",
                       summary.runway.map { $0 >= 6 ? Palette.positive : $0 >= 3 ? Color.orange : Palette.negative },
                       "Деньги на руках к средним расходам за 3 месяца")
                metric("Норма сбережений", summary.savingsRate.map(percent) ?? "нет доходов",
                       summary.savingsRate.map { $0 >= 0 ? Palette.positive : Palette.negative },
                       "(Доходы − расходы) / доходы, текущий месяц")
                metric(summary.growth.map { "Рост с " + CapitalSummary.shortMonth($0.since.title) } ?? "Рост за 12 мес",
                       summary.growth.map { ($0.share > 0 ? "+" : "") + percent($0.share) } ?? "—",
                       summary.growth.map { $0.share >= 0 ? Palette.positive : Palette.negative },
                       "Чистый капитал за доступные 12 мес.")
            }
        }.bankTile(18)
    }

    private func metric(_ title: String, _ value: String, _ tone: Color?, _ hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Palette.secondary)
            Text(value).font(.title3.bold()).monospacedDigit().foregroundStyle(tone ?? Palette.text)
                .lineLimit(1).minimumScaleFactor(0.5).contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 14))
        .help(hint ?? title)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint ?? "")
    }

    private func trendCard(_ summary: CapitalSummary) -> some View {
        let points = summary.lastYear
        let value = { (point: CapitalSummary.Point) in display.plotted(point.cents, prices: prices) }
        let symbol = display.symbol
        return AnalyticsCard(title: "Чистый капитал, 12 месяцев",
                             subtitle: "На конец каждого месяца с данными и сегодня" + (display == .rub ? "" : " · по текущему курсу ЦБ")) {
            Chart(points) { point in
                AreaMark(x: .value("Месяц", point.title), yStart: .value("База", points.map(value).min() ?? 0), yEnd: .value("Капитал", value(point)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Palette.accent.opacity(0.22), Palette.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Месяц", point.title), y: .value("Капитал", value(point)))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.4))
                    .foregroundStyle(Palette.accent)
                PointMark(x: .value("Месяц", point.title), y: .value("Капитал", value(point)))
                    .symbolSize(point.current ? 80 : 24)
                    .foregroundStyle(Palette.accent)
                    .accessibilityLabel(point.title)
                    .accessibilityValue(shown(point.cents))
                    .annotation(position: .top, spacing: 6) {
                        if point.current {
                            Text(CapitalSummary.compact(value(point), symbol: symbol)).font(.caption.bold()).monospacedDigit().foregroundStyle(Palette.text)
                        }
                    }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel { if let title = value.as(String.self) { Text(CapitalSummary.axisMonth(title)) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    AxisValueLabel { if let number = value.as(Double.self) { Text(CapitalSummary.compact(number, symbol: symbol)) } }
                }
            }
            .frame(height: 230)
            if summary.history.count > points.count {
                Text("Показаны последние 12 точек из " + String(summary.history.count) + ".").font(.caption2).foregroundStyle(Palette.secondary)
            }
        }
    }

    private func structureCard(_ summary: CapitalSummary) -> some View {
        AnalyticsCard(title: "Структура активов", subtitle: "Доли групп в стоимости активов") {
            if summary.slices.isEmpty {
                Text("Нет активов с положительной оценкой").foregroundStyle(Palette.secondary)
            } else {
                Chart(summary.slices) { slice in
                    BarMark(x: .value("Доля", summary.share(slice.cents)), y: .value("Активы", "Активы"))
                        .foregroundStyle(slice.kind.color)
                        .accessibilityLabel(slice.kind.rawValue)
                        .accessibilityValue(percent(summary.share(slice.cents)))
                }
                .chartXScale(domain: 0...1)
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .frame(height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(spacing: 9) {
                    ForEach(summary.slices) { slice in
                        HStack(spacing: 8) {
                            Circle().fill(slice.kind.color).frame(width: 9, height: 9)
                            Text(slice.kind.rawValue).font(.subheadline).foregroundStyle(Palette.text)
                            Spacer()
                            Text(shown(slice.cents)).font(.subheadline).monospacedDigit().foregroundStyle(Palette.text)
                            Text(percent(summary.share(slice.cents))).font(.subheadline.bold()).monospacedDigit().foregroundStyle(Palette.secondary)
                                .frame(minWidth: 52, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func liabilitiesCard(_ summary: CapitalSummary) -> some View {
        AnalyticsCard(title: "Обязательства", subtitle: "Итого " + shown(summary.debts)) {
            if summary.liabilities.isEmpty {
                Text("Обязательств нет").foregroundStyle(Palette.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(summary.liabilities) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.title).font(.subheadline).foregroundStyle(Palette.text)
                                Spacer()
                                Text(shown(item.cents)).font(.subheadline).monospacedDigit().foregroundStyle(Palette.text)
                                Text(percent(summary.debtShare(item.cents))).font(.subheadline.bold()).monospacedDigit().foregroundStyle(Palette.secondary)
                                    .frame(minWidth: 52, alignment: .trailing)
                            }
                            GeometryReader { geometry in
                                Capsule().fill(Palette.negative.opacity(0.75))
                                    .frame(width: max(4, geometry.size.width * summary.debtShare(item.cents)))
                            }.frame(height: 5)
                        }
                    }
                }
            }
        }
    }

    private func detailsCard(_ summary: CapitalSummary, archive: Archive) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("Остатки по счетам и позициям") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(AssetClass.allCases) { kind in
                        let rows = accounts.filter { !$0.position.debt && AssetClass.of($0) == kind }
                        if !rows.isEmpty {
                            Text(kind.rawValue).font(.subheadline.bold()).foregroundStyle(kind.color).padding(.top, 6)
                            ForEach(rows) { account in
                                LabeledContent(account.position.title) {
                                    HStack(spacing: 10) {
                                        Text(shown(account.position.amount)).monospacedDigit()
                                        Text(percent(summary.share(account.position.amount))).foregroundStyle(Palette.secondary).monospacedDigit()
                                            .frame(minWidth: 52, alignment: .trailing)
                                    }
                                }
                            }
                        }
                    }
                }.padding(.top, 4)
            }
            Divider()
            HStack(spacing: 12) {
                Button {
                    do {
                        workbook = try OriginalBudget()
                        exporting = true
                    } catch { exportProblem = true }
                } label: { Label("Исходный отчёт Excel", systemImage: "square.and.arrow.down") }
                Button { editing = true } label: { Label("Сверить остатки", systemImage: "checkmark.circle") }
                Spacer()
                NavigationLink("История по месяцам") {
                    List(archive.months.reversed(), id: \.title) { month in
                        NavigationLink {
                            List {
                                LabeledContent("Чистый капитал", value: money(month.capital))
                                if !month.note.isEmpty { Text(month.note).foregroundStyle(.secondary) }
                                ForEach(month.lines.indices, id: \.self) { i in
                                    let line = month.lines[i]
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(line.title).font(line.amount == nil ? .headline : .body)
                                        if let amount = line.amount { Text(money(amount)).monospacedDigit() }
                                        if !line.note.isEmpty { Text(line.note).font(.caption) }
                                    }
                                }
                            }.navigationTitle(month.title)
                        } label: {
                            LabeledContent(month.title, value: money(month.capital))
                        }
                    }.navigationTitle("История капитала")
                }
            }.buttonStyle(.bordered)
        }.bankTile()
    }
}

struct OriginalBudget: FileDocument {
    static let type = UTType(filenameExtension: "xlsx") ?? .data
    static var readableContentTypes: [UTType] { [type] }
    let data: Data

    init() throws {
        guard let url = Archive.reportURL("OriginalBudget", "xlsx") else {
            throw CocoaError(.fileNoSuchFile)
        }
        data = try Data(contentsOf: url)
    }

    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = bytes
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct Revision: Codable {
    let date: Date
    let positions: [Archive.Position]

    @MainActor func migrate(into context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<Checkpoint>())
        for (index, position) in positions.enumerated() {
            let key = "excel-20260901-\(index)"
            // A previous release may already have committed these rows before
            // clearing the separate UserDefaults marker.
            if existing.contains(where: {
                $0.key == key && $0.date == date && $0.title == position.title &&
                $0.amount == position.amount && $0.debt == position.debt
            }) { continue }
            context.insert(Checkpoint(position: position, key: key, date: date))
        }
        try context.save()
    }
}

private enum ReconciliationError: LocalizedError {
    case accountsChanged
    var errorDescription: String? { "Остатки изменились в другом окне. Закройте сверку и откройте её снова." }
}

struct Reconciliation: View {
    nonisolated static func changedRows(_ rows: [AccountBalance], from starting: [AccountBalance]) -> [AccountBalance] {
        let before = Dictionary(uniqueKeysWithValues: starting.map { ($0.id, $0.position) })
        return rows.filter { before[$0.id] != $0.position }
    }
    struct Row: Identifiable {
        var id = UUID().uuidString
        var name: String
        var rubles: String
        var debt: Bool
        var position: Archive.Position? {
            let value = rubles.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.wholeMatch(of: /-?[0-9]{1,12}(\.[0-9]{1,2})?/) != nil,
                  let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            return Archive.Position(title: name, amount: NSDecimalNumber(decimal: amount * 100).int64Value, debt: debt)
        }
    }
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]
    @State private var failure = ""
    @State private var startingAccounts: [AccountBalance]
    @State private var asOf = Date()
    let save: ([AccountBalance], Date, [AccountBalance]) throws -> Void
    init(accounts: [AccountBalance], save: @escaping ([AccountBalance], Date, [AccountBalance]) throws -> Void) {
        _startingAccounts = State(initialValue: accounts)
        _rows = State(initialValue: accounts.map {
            Row(id: $0.id, name: $0.position.title, rubles: NSDecimalNumber(decimal: Decimal($0.position.amount) / 100).stringValue, debt: $0.position.debt)
        })
        self.save = save
    }
    var body: some View {
        NavigationStack {
            Form {
                ForEach([false,true], id: \.self) { debt in
                    Section(debt ? "Обязательства, ₽" : "Активы, ₽") {
                        ForEach($rows) { $row in
                            if row.debt == debt {
                                VStack(alignment: .leading) {
                                    TextField("Название", text: $row.name)
                                    TextField("Стоимость в рублях", text: $row.rubles)
                                }
                            }
                        }
                        Button(debt ? "Добавить обязательство" : "Добавить актив") {
                            rows.append(Row(name: "", rubles: "0", debt: debt))
                        }
                    }
                }
                Section {
                    Text("Сохраняются только изменённые и новые строки. Остальные счета продолжают учитывать операции задним числом.").font(.caption)
                }
            }.formStyle(.grouped).navigationTitle("Сверка остатков")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let accounts = rows.compactMap { row in
                            row.position.map { AccountBalance(id: row.id, position: $0, cutoff: asOf) }
                        }
                        guard accounts.count == rows.count else { return }
                        do { try save(accounts, asOf, startingAccounts); dismiss() } catch { failure = error.localizedDescription }
                    }.disabled(rows.contains { $0.position == nil } || !rows.contains { row in
                        startingAccounts.first { $0.id == row.id }?.position != row.position
                    })
                }
            }
        }
        .alert("Не удалось сохранить сверку", isPresented: Binding(get: { !failure.isEmpty }, set: { if !$0 { failure = "" } })) { Button("ОК") {} } message: { Text(failure) }
        #if os(macOS)
        .frame(minWidth: 450, minHeight: 440)
        #endif
    }
}
