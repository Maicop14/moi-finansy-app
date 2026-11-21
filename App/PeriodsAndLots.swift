import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts

struct RecordCopy: Codable {
    let id: UUID
    let kind: String
    let payload: Data
    func validate() throws {
        switch kind {
        case "lot": _ = try JSONDecoder().decode(LotMovement.self, from: payload)
        case "close": _ = try JSONDecoder().decode(Closing.self, from: payload)
        case SavingsProject.kind: _ = try JSONDecoder().decode(SavingsProject.self, from: payload)
        case ProjectContribution.kind: _ = try JSONDecoder().decode(ProjectContribution.self, from: payload)
        case RecurringPayment.kind: _ = try JSONDecoder().decode(RecurringPayment.self, from: payload)
        case MonthBudget.kind: _ = try JSONDecoder().decode(MonthBudget.self, from: payload)
        default: throw BackupError.incomplete
        }
    }
}
@Model final class FinanceRecord {
    var id = UUID()
    var kind = ""
    var payload = Data()
    init(_ copy: RecordCopy) { id = copy.id; kind = copy.kind; payload = copy.payload }
    init<T: Encodable>(_ kind: String, _ value: T, id: UUID = UUID()) throws {
        self.kind = kind; self.id = id; payload = try JSONEncoder().encode(value)
    }
}
struct LotMovement: Codable, Identifiable {
    let id: UUID
    let lot: UUID
    let date: Date
    let name: String
    let goods: Bool
    let unit: String
    let asset: String
    let cash: String
    let units: Int64 // millionths of the selected unit, negative on sale
    let gross: Int64
    let fee: Int64
    let cost: Int64 // acquisition cost or cost released by sale, both positive

    static func quantity(_ string: String) -> Int64? {
        let s = string.replacingOccurrences(of: ",", with: ".")
        guard s.wholeMatch(of: /[0-9]{1,8}(\.[0-9]{1,6})?/) != nil, let v = Decimal(string: s), v > 0 else { return nil }
        return NSDecimalNumber(decimal: v * 1_000_000).int64Value
    }
    static func released(units: Int64, left: Int64, basis: Int64) throws -> Int64 {
        guard units > 0, units <= left, basis >= 0 else { throw BackupError.incomplete }
        if units == left { return basis }
        return IncomeMath.rounded(Decimal(basis) * Decimal(units) / Decimal(left))
    }
    static func decode(_ records: [FinanceRecord]) throws -> [Self] {
        try records.filter { $0.kind == "lot" }.map { try JSONDecoder().decode(Self.self, from: $0.payload) }
    }
    var profit: Int64 { units < 0 ? gross - fee - cost : 0 }
    /// A purchase can change while its lot has no sales; a sale only while it is the lot's latest movement,
    /// so the cost released by every remaining sale stays correct.
    static func changeable(_ movement: Self, in all: [Self]) -> Bool {
        let group = all.filter { $0.lot == movement.lot }
        if movement.units > 0 { return !group.contains { $0.units < 0 } }
        guard let latest = group.filter({ $0.units < 0 }).max(by: { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }) else { return false }
        return latest.id == movement.id
    }
}

struct LotsPanel: View {
    @Environment(\.modelContext) private var context
    @Query private var records: [FinanceRecord]
    let accounts: [AccountBalance]
    @State private var goods = false
    @State private var movementDate = Date()
    @State private var sale: UUID?
    @State private var replacing: UUID?
    @State private var name = ""
    @State private var unit = "г"
    @State private var asset = ""
    @State private var cash = ""
    @State private var quantity = ""
    @State private var price = ""
    @State private var fee = ""
    @State private var message = ""
    @State private var editing = false
    @State private var removal: LotMovement?
    var body: some View {
        let movements = (try? LotMovement.decode(records)) ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text("Учёт по партиям").font(.headline)
            Picker("Раздел", selection: $goods) { Text("Инвестиции").tag(false); Text("Товар").tag(true) }.pickerStyle(.segmented)
            ForEach(movements.filter { $0.goods == goods && $0.units > 0 }.sorted { $0.date > $1.date }) { lot in
                let group = movements.filter { $0.lot == lot.id }
                let left = group.reduce(Int64(0)) { $0 + $1.units }
                let profit = group.reduce(Int64(0)) { $0 + $1.profit }
                VStack(alignment: .leading, spacing: 6) {
                    Text(lot.name + " · " + lot.date.formatted(date: .numeric, time: .omitted)).bold()
                    let units: String = (Decimal(left) / 1_000_000).formatted()
                    Text("Осталось \(units) \(lot.unit) · Прибыль \(money(profit))")
                    ForEach(group.sorted { $0.date < $1.date }) { item in
                        HStack {
                            let kind: String = item.units > 0 ? "Покупка" : "Продажа"
                            Text("\(kind) \(item.date.formatted(date: .numeric, time: .omitted)) · \(money(item.gross))").font(.caption)
                            Spacer()
                            if LotMovement.changeable(item, in: movements) {
                                Button("Изменить") { open(item, movements: movements) }.font(.caption)
                                Button("Удалить", role: .destructive) { removal = item }.font(.caption)
                            }
                        }
                    }
                    if left > 0 { Button("Продать из этой партии") { reset(); sale = lot.id; editing = true } }
                }
            }
            Text("Изменить или удалить можно покупку без продаж и последнюю продажу партии.").font(.caption).foregroundStyle(.secondary)
            Button("Добавить покупку") { reset(); editing = true }
            if !message.isEmpty { Text(message).font(.caption) }
        }
        .confirmationDialog("Удалить движение партии?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { item in
            Button("Удалить", role: .destructive) {
                do { try remove(item.id); try context.save(); message = "Движение и связанные операции удалены." }
                catch { context.rollback(); message = error.localizedDescription }
            }
        } message: { item in Text("Операции по счетам от этого движения тоже будут удалены.") }
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form {
                    if sale == nil {
                        TextField("Название партии", text: $name)
                        TextField("Единица измерения", text: $unit)
                        Picker("Где учитывается актив", selection: $asset) {
                            Text("Выберите позицию").tag("")
                            ForEach(accounts.filter { !$0.position.debt }) { Text($0.position.title).tag($0.id) }
                        }
                    }
                    Picker(sale == nil ? "Счёт оплаты" : "Счёт поступления", selection: $cash) {
                        Text("Выберите счёт").tag("")
                        ForEach(accounts.filter { $0.id != (sale.flatMap { id in movements.first { $0.id == id }?.asset } ?? asset) }) { Text($0.position.title).tag($0.id) }
                    }
                    DatePicker("Дата операции", selection: $movementDate, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                    TextField("Количество", text: $quantity)
                    TextField(sale == nil ? "Сумма покупки, ₽" : "Выручка, ₽", text: $price)
                    TextField("Комиссия, ₽", text: $fee)
                    if !message.isEmpty { Text(message) }
                }.formStyle(.grouped).navigationTitle(replacing != nil ? "Изменить движение" : sale == nil ? "Покупка партии" : "Продажа из партии")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { editing = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("Сохранить") { save() } }
                }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 370)
            #endif
        }
    }
    private func reset() { sale = nil; replacing = nil; movementDate = Date(); name = ""; unit = goods ? "шт." : "г"; asset = ""; cash = ""; price = ""; fee = ""; quantity = ""; message = "" }
    private func rubles(_ cents: Int64) -> String { NSDecimalNumber(decimal: Decimal(cents) / 100).stringValue }
    private func open(_ item: LotMovement, movements: [LotMovement]) {
        reset()
        replacing = item.id
        sale = item.units < 0 ? item.lot : nil
        name = item.name; unit = item.unit; asset = item.asset; cash = item.cash
        movementDate = item.date
        quantity = NSDecimalNumber(decimal: Decimal(abs(item.units)) / 1_000_000).stringValue
        price = rubles(item.gross)
        fee = item.fee == 0 ? "" : rubles(item.fee)
        editing = true
    }
    /// Removes a lot movement together with the account entries it created.
    private func remove(_ id: UUID) throws {
        for record in try context.fetch(FetchDescriptor<FinanceRecord>()) where record.kind == "lot" && record.id == id { context.delete(record) }
        for entry in try context.fetch(FetchDescriptor<Entry>()) where entry.lotEventID == id { context.delete(entry) }
    }
    private func save() {
        guard let n = LotMovement.quantity(quantity), let gross = IncomeMath.positive(price),
              let charge = fee.isEmpty || fee == "0" ? 0 : IncomeMath.positive(fee),
              accounts.contains(where: { $0.id == cash }) else { message = "Проверьте количество, сумму, комиссию и денежный счёт."; return }
        do {
            let all = try LotMovement.decode(context.fetch(FetchDescriptor<FinanceRecord>()))
            if let replacing, let old = all.first(where: { $0.id == replacing }), !LotMovement.changeable(old, in: all) {
                message = "Сначала измените или удалите более поздние продажи этой партии."; return
            }
            // The movement being edited is left out, as if it had been deleted first.
            let rows = all.filter { $0.id != replacing }
            let id = UUID(), date = movementDate
            let movement: LotMovement
            if let sale, let buy = rows.first(where: { $0.id == sale && $0.units > 0 }) {
                let related = rows.filter { $0.lot == sale }
                let left = related.reduce(Int64(0)) { $0 + $1.units }
                guard date >= (related.map(\.date).max() ?? buy.date), charge <= gross, n <= left, cash != buy.asset else { message = "Проверьте остаток, комиссию, счёт и дату последней операции партии."; return }
                let basis = related.reduce(Int64(0)) { $0 + ($1.units > 0 ? $1.cost : -$1.cost) }
                let cost = try LotMovement.released(units: n, left: left, basis: basis)
                movement = LotMovement(id: id, lot: sale, date: date, name: buy.name, goods: buy.goods, unit: buy.unit, asset: buy.asset, cash: cash, units: -n, gross: gross, fee: charge, cost: cost)
            } else {
                guard sale == nil, asset != cash, accounts.contains(where: { $0.id == asset && !$0.position.debt }), !name.isEmpty, !unit.isEmpty, Holding.allCases.first(where: { $0.id == asset }).map({ $0.unit == unit && !goods }) ?? true else { message = "Укажите название и позицию актива."; return }
                movement = LotMovement(id: id, lot: id, date: date, name: name, goods: goods, unit: unit, asset: asset, cash: cash, units: n, gross: gross, fee: charge, cost: gross + charge)
            }
            func post(_ amount: Int64, _ flow: Flow, _ category: String, _ source: String, _ destination: String? = nil) {
                guard amount > 0 else { return }
                let e = Entry(cents: amount, flow: flow, category: category, note: movement.name, date: date)
                e.accountKey = source; e.destinationKey = destination; e.lotEventID = id
                if flow != .transfer { e.charityIncluded = true }
                context.insert(e)
            }
            if let replacing { try remove(replacing) }
            context.insert(try FinanceRecord("lot", movement, id: id))
            if movement.units > 0 { post(movement.cost, .transfer, "Покупка партии", cash, movement.asset) }
            else {
                post(movement.cost, .transfer, "Продажа партии", movement.asset, cash)
                post(abs(movement.profit), movement.profit < 0 ? .expense : .income, movement.profit < 0 ? "Убыток от продажи" : "Чистая прибыль от продажи", cash)
            }
            let edited = replacing != nil
            try context.save(); editing = false; replacing = nil
            message = edited ? "Движение партии исправлено." : "Партия и движения по счетам сохранены."
        } catch { context.rollback(); message = error.localizedDescription }
    }
}

struct Closing: Codable {
    let end: Date
    let saved: Date
    let positions: [String: Int64]
    let titles: [String: String]
    let capital: Int64
    var quoteRecords: [String: Data]? = nil
    let values: PeriodValues?
    /// Closed month as yyyyMM. Stored so a closing still matches after a time-zone change;
    /// older records fall back to the month that ends at `end`.
    var month: Int? = nil
    var monthKey: Int { month ?? Charity.key(end.addingTimeInterval(-1)) }
}

struct PeriodValues: Codable {
    var opening: Int64?
    var closing: Int64?
    var income: Int64
    var expenses: Int64
    var realized: Int64
    var quotes: Int64?
    var incomplete: Bool? = nil
    var adjustments: Int64? {
        guard incomplete != true, let opening, let closing, let quotes else { return nil }
        return closing - opening - income + expenses - realized - quotes
    }
    var values: [Int64?] { incomplete == true ? [opening, nil, nil, nil, nil, nil, closing] : [opening, income, expenses, realized, quotes, adjustments, closing] }
    static let labels = ["Капитал на начало", "Доходы без продажи партий", "Расходы без убытков от продажи", "Прибыль от продажи партий", "Переоценка по отмеченным котировкам", "Прочие изменения и сверки", "Капитал на конец"]
}
struct ReportTable {
    let title: String
    let previous: String
    let currentValues: PeriodValues
    let previousValues: PeriodValues
    let partial: Bool
}
private enum ReportSpan: Int, CaseIterable { case month = 1, quarter = 3, year = 12
    var title: String { switch self { case .month: "Месяц"; case .quarter: "Квартал"; case .year: "Год" } }
}
/// Waterfall from opening to closing net worth. Totals use the accent colour, items green or red.
struct BridgeChart: View {
    let title: String
    let bridge: CapitalBridge
    @AppStorage("display.currency") private var displayCode = DisplayCurrency.rub.rawValue
    @AppStorage("markets.prices") private var priceCache = Data()
    private var prices: MarketPrices { (try? JSONDecoder().decode(MarketPrices.self, from: priceCache)) ?? .initial }
    private var display: DisplayCurrency { DisplayCurrency.selected(displayCode, prices: prices) }

    private func color(_ step: CapitalBridge.Step) -> Color {
        step.total ? Palette.accent : step.delta >= 0 ? Palette.positive : Palette.negative
    }
    private func label(_ step: CapitalBridge.Step) -> String {
        if step.total { return display.format(step.end, prices: prices) }
        return (step.delta > 0 ? "+" : step.delta < 0 ? "−" : "") + display.format(abs(step.delta), prices: prices)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(Palette.text)
            Chart(bridge.steps) { step in
                BarMark(xStart: .value("От", display.plotted(step.start, prices: prices)),
                        xEnd: .value("До", display.plotted(step.end, prices: prices)),
                        y: .value("Статья", step.title), height: .fixed(18))
                    .foregroundStyle(color(step))
                    .cornerRadius(3)
                    .accessibilityLabel(step.title)
                    .accessibilityValue(label(step))
                    .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                        Text(label(step)).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(color(step))
                    }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    AxisValueLabel { if let number = value.as(Double.self) { Text(CapitalSummary.compact(number, symbol: display.symbol)) } }
                }
            }
            .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption).foregroundStyle(Palette.text) } }
            .chartXScale(range: .plotDimension(endPadding: 90))
            .frame(height: CGFloat(bridge.steps.count) * 34 + 30)
        }
        .padding(14)
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PeriodPanel: View {
    @Query private var entries: [Entry]
    @Query private var checkpoints: [Checkpoint]
    @Query private var records: [FinanceRecord]
    @Environment(\.modelContext) private var context
    @State private var span = ReportSpan.month
    @State private var chosen = Date()
    @State private var export: ReportFile?
    @State private var exporting = false
    @State private var isPDF = true
    @State private var message = ""
    private var calendar: Calendar { Calendar(identifier: .gregorian) }
    private func interval(_ date: Date, shift: Int = 0) -> DateInterval {
        let c = calendar
        var d = c.dateComponents([.year, .month], from: date)
        d.month = (((d.month ?? 1) - 1) / span.rawValue) * span.rawValue + 1
        let start = c.date(byAdding: .month, value: shift * span.rawValue, to: c.date(from: d)!)!
        return DateInterval(start: start, end: c.date(byAdding: .month, value: span.rawValue, to: start)!)
    }
    private func title(_ range: DateInterval) -> String {
        let year = calendar.component(.year, from: range.start)
        switch span {
        case .month: return range.start.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).month(.wide).year())
        case .quarter: return String((calendar.component(.month, from: range.start) - 1) / 3 + 1) + " квартал " + String(year)
        case .year: return String(year) + " год"
        }
    }
    private func state(at end: Date) -> [AccountBalance]? {
        guard let archive = Archive.bundled,
              end >= ISO8601DateFormatter().date(from: "2026-09-01T00:00:00+03:00")! else { return nil }
        return balances(archive: archive, checkpoints: checkpoints.filter { $0.date < end }, entries: entries.filter { $0.date < end })
    }
    private func historicCapital(at boundary: Date) -> Int64? {
        let prior = boundary.addingTimeInterval(-1)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        formatter.dateFormat = "LLLL yyyy"
        let title = formatter.string(from: prior)
        return Archive.bundled?.months.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }?.capital
    }
    private func net(_ rows: [AccountBalance]?) -> Int64? { rows?.reduce(0) { $0 + ($1.position.debt ? -$1.position.amount : $1.position.amount) } }
    private func summary(_ range: DateInterval, closes: [Closing], freeze: Bool = true) -> PeriodValues {
        let end = min(range.end, Date.now)
        if span != .month {
            var start = range.start
            var parts: [PeriodValues] = []
            while start < end {
                let next = calendar.date(byAdding: .month, value: 1, to: start)!
                parts.append(monthValues(DateInterval(start: start, end: next), closes: closes, freeze: freeze))
                start = next
            }
            return PeriodValues(opening: parts.first?.opening, closing: parts.last?.closing,
                                income: parts.reduce(0) { $0 + $1.income }, expenses: parts.reduce(0) { $0 + $1.expenses },
                                realized: parts.reduce(0) { $0 + $1.realized }, quotes: parts.reduce(0) { $0 + ($1.quotes ?? 0) }, incomplete: parts.contains { $0.incomplete == true })
        }
        return monthValues(range, closes: closes, freeze: freeze)
    }
    private func monthValues(_ range: DateInterval, closes: [Closing], freeze: Bool) -> PeriodValues {
        let end = min(range.end, Date.now)
        let rows = entries.filter { $0.date >= range.start && $0.date < end && !$0.transfer }
        let key = Charity.key(range.start)
        let previous = closes.first { $0.monthKey == Charity.previous(range.start) }
        let current = closes.first { $0.monthKey == key }
        if freeze, let values = current?.values { return values }
        let reprices = checkpoints.filter { $0.date >= range.start && $0.date < end }.compactMap(\.marketDelta)
        return PeriodValues(opening: previous?.capital ?? net(state(at: range.start)) ?? historicCapital(at: range.start), closing: (freeze ? current?.capital : nil) ?? net(state(at: end)) ?? historicCapital(at: end),
                            income: rows.filter { $0.income && $0.lotEventID == nil }.reduce(0) { $0 + $1.cents },
                            expenses: rows.filter { !$0.income && $0.lotEventID == nil }.reduce(0) { $0 + $1.cents },
                            realized: rows.filter { $0.lotEventID != nil }.reduce(0) { $0 + ($1.income ? $1.cents : -$1.cents) },
                            quotes: reprices.reduce(0,+), incomplete: range.end <= ISO8601DateFormatter().date(from: "2026-09-01T00:00:00+03:00")!)
    }
    var body: some View {
        let period = interval(chosen), prior = interval(chosen, shift: -1)
        let closes = records.filter { $0.kind == "close" }.compactMap { try? JSONDecoder().decode(Closing.self, from: $0.payload) }.sorted { $0.saved > $1.saved }
        let report = ReportTable(title: title(period), previous: title(prior), currentValues: summary(period, closes: closes), previousValues: summary(prior, closes: closes), partial: period.end > .now)
        VStack(alignment: .leading, spacing: 10) {
            Text("Отчёты и закрытие месяца").font(.headline)
            Picker("Период", selection: $span) { ForEach(ReportSpan.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            DatePicker("Дата внутри периода", selection: $chosen, in: ...Date.now, displayedComponents: .date)
            Text(report.title + " · сравнение с " + report.previous)
            if report.partial { Text("Текущий период ещё не завершён.").font(.caption) }
            Text("Суммы по внесённым операциям. Для архивных месяцев без детализации обороты могут быть неполными.").font(.caption)
            if let bridge = CapitalBridge(report.currentValues) {
                BridgeChart(title: (span == .month ? "Изменение за месяц" : "Изменение за период") + " · " + report.title, bridge: bridge)
            } else {
                Text("Разложение изменения капитала недоступно: для этого периода нет детализации оборотов.")
                    .font(.caption).foregroundStyle(Palette.secondary)
            }
            ForEach(PeriodValues.labels.indices, id: \.self) { i in
                LabeledContent(PeriodValues.labels[i]) {
                    VStack(alignment: .trailing) {
                        Text(report.currentValues.values[i].map(money) ?? "Нет данных")
                        Text(report.previousValues.values[i].map(money) ?? "Нет данных").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Сохранить PDF") { write(report, pdf: true) }
                Button("Сохранить Excel") { write(report, pdf: false) }
            }
            if span == .month && period.end <= Date.now, let positions = state(at: period.end), let capital = net(positions) {
                let versions = closes.filter { $0.monthKey == Charity.key(period.start) }
                if let latest = versions.first { Text("Версий закрытия: \(versions.count) · \(latest.saved.formatted())").font(.caption) }
                Button(versions.isEmpty ? "Закрыть месяц" : "Сохранить новую версию закрытия") {
                    do {
                        let close = Closing(end: period.end, saved: .now, positions: Dictionary(uniqueKeysWithValues: positions.map { ($0.id,$0.position.amount) }), titles: Dictionary(uniqueKeysWithValues: positions.map { ($0.id,$0.position.title) }), capital: capital, quoteRecords: Dictionary(checkpoints.filter { $0.date < period.end && $0.valuationSource != nil }.sorted { $0.date < $1.date }.compactMap { row in row.valuationSource.map { (row.key, $0) } }, uniquingKeysWith: { _, new in new }), values: summary(period, closes: closes, freeze: false), month: Charity.key(period.start))
                        context.insert(try FinanceRecord("close", close)); try context.save(); message = "Снимок сохранён."
                    } catch { context.rollback(); message = error.localizedDescription }
                }
            }
            if !message.isEmpty { Text(message).font(.caption) }
        }.fileExporter(isPresented: $exporting, document: export, contentType: isPDF ? .pdf : OriginalBudget.type, defaultFilename: "Отчёт " + report.title + (isPDF ? ".pdf" : ".xlsx")) {
            if case .failure(let error) = $0 { message = error.localizedDescription }
        }
    }
    private func write(_ table: ReportTable, pdf: Bool) {
        do { isPDF = pdf; export = ReportFile(data: try pdf ? ReportExport.pdf(table) : ReportExport.xlsx(table)); exporting = true }
        catch { message = error.localizedDescription }
    }
}
