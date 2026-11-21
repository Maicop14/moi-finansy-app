import SwiftUI
import SwiftData
import Charts

/// Subcategories per expense category: built-in names, the owner's own additions and renames.
enum Subcategories {
    static let none = "Без подкатегории"
    static let storageKey = "subcategories.custom"
    static let builtIn: [String: [String]] = [
        "Кафе": ["Фастфуд", "Кофейни", "Рестораны"],
        "Продукты": ["Супермаркеты", "Доставка продуктов"],
        "Транспорт": ["Такси", "Самокаты", "Местный транспорт"],
        "Досуг": ["Книги и канцтовары", "Тренировки"],
        "Связь": ["Мобильная связь", "Интернет и ТВ"],
        "Подписки": ["Цифровые товары", "Сервисы"],
        "Дом": ["Ремонт и мебель"],
    ]

    static func stored(_ defaults: UserDefaults = .standard) -> [String: [String]] {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }
    static func list(for category: String, defaults: UserDefaults = .standard) -> [String] {
        stored(defaults)[category] ?? builtIn[category] ?? []
    }
    static func save(_ names: [String], for category: String, defaults: UserDefaults = .standard) {
        var all = stored(defaults)
        var seen = Set<String>()
        all[category] = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != none && seen.insert($0).inserted }
        defaults.set(try? JSONEncoder().encode(all), forKey: storageKey)
    }
    static func add(_ name: String, to category: String, defaults: UserDefaults = .standard) {
        save(list(for: category, defaults: defaults) + [name], for: category, defaults: defaults)
    }

    /// "Пятёрочка · итого за ноябрь по выписке" → "Пятёрочка".
    static func merchant(_ note: String) -> String {
        let head = note.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return head.isEmpty ? "Без описания" : head
    }

    /// A best guess from the merchant for operations recorded before subcategories existed.
    static func infer(category: String, note: String) -> String {
        let text = note.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        switch category {
        case "Кафе":
            if has("кофе", "coffee", "дринкит", "кофейн") { return "Кофейни" }
            if has("ресторан") { return "Рестораны" }
            return "Фастфуд"
        case "Продукты": return has("самокат", "лавка", "доставк") ? "Доставка продуктов" : "Супермаркеты"
        case "Транспорт":
            if has("такси") { return "Такси" }
            if has("самокат") { return "Самокаты" }
            if has("транспорт", "метро", "автобус", "электрич") { return "Местный транспорт" }
        case "Досуг":
            if has("книг", "читай", "канц") { return "Книги и канцтовары" }
            if has("трениров", "фитнес", "спорт") { return "Тренировки" }
        case "Связь": return has("мобильн") ? "Мобильная связь" : "Интернет и ТВ"
        case "Подписки": return has("цифров") ? "Цифровые товары" : "Сервисы"
        case "Дом": if has("ремонт", "мебел") { return "Ремонт и мебель" }
        default: break
        }
        return none
    }
    static func resolve(_ entry: Entry) -> String {
        if let explicit = entry.subcategory, !explicit.isEmpty { return explicit }
        return infer(category: entry.category, note: entry.note)
    }
}

/// One expense as the breakdown sees it.
struct SpendRow: Equatable {
    let date: Date
    let cents: Int64
    let category: String
    let subcategory: String
    let merchant: String

    init(date: Date, cents: Int64, category: String, subcategory: String, merchant: String) {
        self.date = date; self.cents = cents; self.category = category; self.subcategory = subcategory; self.merchant = merchant
    }
    init(_ entry: Entry) {
        self.init(date: entry.date, cents: entry.cents, category: entry.category,
                  subcategory: Subcategories.resolve(entry), merchant: Subcategories.merchant(entry.note))
    }
}

enum SpendPeriod: String, CaseIterable, Identifiable {
    case week = "Неделя", month = "Месяц", year = "Год"
    var id: Self { self }
    var component: Calendar.Component { switch self { case .week: .weekOfYear; case .month: .month; case .year: .year } }

    func interval(offset: Int, now: Date, calendar: Calendar) -> DateInterval {
        let shifted = calendar.date(byAdding: component, value: offset, to: now) ?? now
        return calendar.dateInterval(of: component, for: shifted) ?? DateInterval(start: shifted, duration: 1)
    }
    func title(_ interval: DateInterval, calendar: Calendar) -> String {
        let locale = Locale(identifier: "ru_RU")
        switch self {
        case .week:
            let end = interval.end.addingTimeInterval(-1)
            return interval.start.formatted(.dateTime.locale(locale).day().month()) + " – " + end.formatted(.dateTime.locale(locale).day().month())
        case .month:
            let text = interval.start.formatted(.dateTime.locale(locale).month(.wide).year())
            return text.prefix(1).uppercased() + text.dropFirst()
        case .year: return String(calendar.component(.year, from: interval.start))
        }
    }
}

enum SpendingBreakdown {
    struct Slice: Identifiable, Equatable {
        let name: String
        let cents: Int64
        let share: Double
        var id: String { name }
    }
    static let other = "Остальное"

    static func rows(_ entries: [Entry], in interval: DateInterval) -> [SpendRow] {
        entries.filter { $0.kind == Flow.expense.rawValue && $0.cents > 0 && interval.contains($0.date) && $0.date < interval.end }
            .map(SpendRow.init)
    }
    static func group(_ rows: [SpendRow], by key: (SpendRow) -> String) -> [Slice] {
        let total = rows.reduce(Int64(0)) { $0 + $1.cents }
        return Dictionary(grouping: rows, by: key).map { name, items in
            let cents = items.reduce(Int64(0)) { $0 + $1.cents }
            return Slice(name: name, cents: cents, share: total > 0 ? Double(cents) / Double(total) : 0)
        }.sorted { ($0.cents, $1.name) > ($1.cents, $0.name) }
    }
    /// Level 0: categories; 1: subcategories of a category; 2: merchants of a subcategory.
    static func slices(_ rows: [SpendRow], category: String?, subcategory: String?) -> [Slice] {
        let scoped = filter(rows, category: category, subcategory: subcategory)
        if category == nil { return group(scoped) { $0.category } }
        if subcategory == nil { return group(scoped) { $0.subcategory } }
        return group(scoped) { $0.merchant }
    }
    static func filter(_ rows: [SpendRow], category: String?, subcategory: String?) -> [SpendRow] {
        rows.filter { (category == nil || $0.category == category) && (subcategory == nil || $0.subcategory == subcategory) }
    }
    /// The largest `limit` slices, the rest folded into «Остальное» for the chart.
    static func top(_ slices: [Slice], limit: Int = 6) -> [Slice] {
        guard slices.count > limit + 1 else { return slices }
        let rest = slices.dropFirst(limit)
        return Array(slices.prefix(limit)) + [Slice(name: other, cents: rest.reduce(0) { $0 + $1.cents }, share: rest.reduce(0) { $0 + $1.share })]
    }
}

/// Pinned subcategories or merchants, shown separately at the top of the breakdown.
struct SpendPin: Codable, Hashable, Identifiable {
    let category: String
    let subcategory: String?
    let merchant: String?
    var id: String { [category, subcategory ?? "", merchant ?? ""].joined(separator: "›") }
    var title: String { merchant ?? subcategory ?? category }
    func matches(_ row: SpendRow) -> Bool {
        row.category == category && (subcategory == nil || row.subcategory == subcategory) && (merchant == nil || row.merchant == merchant)
    }
}

/// «Детализация расходов» at the top of «Операции»: donut chart, drill-down and pinned items.
struct SpendingBreakdownView: View {
    let entries: [Entry]
    let format: (Int64) -> String
    let edit: (Entry) -> Void
    @State private var period = SpendPeriod.month
    @State private var offset = 0
    @State private var category: String?
    @State private var subcategory: String?
    @State private var angle: Double?
    @State private var managing: String?
    @AppStorage("breakdown.pins") private var pinData = Data()

    private var pins: [SpendPin] { (try? JSONDecoder().decode([SpendPin].self, from: pinData)) ?? [] }
    private func toggle(_ pin: SpendPin) {
        var list = pins
        if let index = list.firstIndex(of: pin) { list.remove(at: index) } else { list.append(pin) }
        pinData = (try? JSONEncoder().encode(list)) ?? Data()
    }
    static let colors: [Color] = [Palette.accent, Color(red: 0.93, green: 0.55, blue: 0.13), Color(red: 0.13, green: 0.62, blue: 0.66),
                                  Color(red: 0.55, green: 0.36, blue: 0.80), Palette.positive, Color(red: 0.86, green: 0.33, blue: 0.47),
                                  Color(red: 0.62, green: 0.66, blue: 0.72)]
    private func color(_ slice: SpendingBreakdown.Slice, in list: [SpendingBreakdown.Slice]) -> Color {
        if slice.name == SpendingBreakdown.other { return Self.colors[6] }
        return Self.colors[(list.firstIndex(of: slice) ?? 0) % 6]
    }
    private func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(share < 0.01 && share > 0 ? 1 : 0)).locale(Locale(identifier: "ru_RU")))
    }

    var body: some View {
        let calendar = Calendar.autoupdatingCurrent
        let interval = period.interval(offset: offset, now: .now, calendar: calendar)
        let rows = SpendingBreakdown.rows(entries, in: interval)
        let scoped = SpendingBreakdown.filter(rows, category: category, subcategory: subcategory)
        let total = scoped.reduce(Int64(0)) { $0 + $1.cents }
        let slices = SpendingBreakdown.slices(rows, category: category, subcategory: subcategory)
        let chart = SpendingBreakdown.top(slices)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Детализация расходов").font(.title3.bold())
                Spacer()
                Picker("Период", selection: $period) { ForEach(SpendPeriod.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(maxWidth: 220)
                    .onChange(of: period) { _, _ in offset = 0 }
            }
            HStack {
                Button { offset -= 1 } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Предыдущий период")
                Spacer()
                Text(period.title(interval, calendar: calendar)).font(.headline)
                Spacer()
                Button { offset += 1 } label: { Image(systemName: "chevron.right") }.disabled(offset >= 0).accessibilityLabel("Следующий период")
            }.buttonStyle(.borderless)
            breadcrumbs
            if rows.isEmpty {
                ContentUnavailableView("Нет расходов за период", systemImage: "chart.pie", description: Text("Добавьте расход или выберите другой период."))
            } else {
                donut(chart, total: total)
                FlowChips(items: chart) { slice in
                    Button { drill(slice, all: slices) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(color(slice, in: chart)).frame(width: 9, height: 9)
                            Text(slice.name).lineLimit(1)
                            Text(format(slice.cents) + " · " + percent(slice.share)).foregroundStyle(Palette.secondary).monospacedDigit()
                        }.font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(color(slice, in: chart).opacity(0.12), in: Capsule())
                    }.buttonStyle(.plain).disabled(subcategory != nil || slice.name == SpendingBreakdown.other)
                }
                pinned(rows)
                list(slices, rows: scoped)
            }
        }.bankTile()
        .sheet(item: Binding(get: { managing.map(ManagedCategory.init) }, set: { managing = $0?.name })) { item in
            SubcategoryEditor(category: item.name, entries: entries)
        }
    }

    @ViewBuilder private var breadcrumbs: some View {
        if let category {
            HStack(spacing: 6) {
                Button("Все расходы") { self.category = nil; subcategory = nil }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                if let subcategory {
                    Button(category) { self.subcategory = nil }
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(subcategory).bold()
                } else { Text(category).bold() }
                Spacer()
                Button { managing = category } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Подкатегории")
            }.font(.subheadline).buttonStyle(.borderless)
        }
    }

    private func donut(_ chart: [SpendingBreakdown.Slice], total: Int64) -> some View {
        Chart(chart) { slice in
            SectorMark(angle: .value("Сумма", Double(slice.cents)), innerRadius: .ratio(0.64), angularInset: 1.5)
                .cornerRadius(4)
                .foregroundStyle(color(slice, in: chart))
                .accessibilityLabel(slice.name)
                .accessibilityValue(format(slice.cents) + ", " + percent(slice.share))
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $angle)
        .onChange(of: angle) { _, value in
            guard let value else { return }
            var running = 0.0
            for slice in chart {
                running += Double(slice.cents)
                if value <= running { drill(slice, all: chart); break }
            }
            angle = nil
        }
        .chartBackground { _ in
            VStack(spacing: 2) {
                Text(subcategory ?? category ?? "Всего").font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                Text(format(total)).font(.title3.bold()).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
            }.padding(.horizontal, 60)
        }
        .frame(height: 230)
    }

    private func drill(_ slice: SpendingBreakdown.Slice, all: [SpendingBreakdown.Slice]) {
        guard slice.name != SpendingBreakdown.other, subcategory == nil else { return }
        withAnimation(.snappy) {
            if category == nil { category = slice.name } else { subcategory = slice.name }
        }
    }

    @ViewBuilder private func pinned(_ rows: [SpendRow]) -> some View {
        let active = pins.filter { pin in category == nil || pin.category == category }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Выделено", systemImage: "pin.fill").font(.subheadline.weight(.semibold))
                ForEach(active) { pin in
                    let cents = rows.filter(pin.matches).reduce(Int64(0)) { $0 + $1.cents }
                    Button {
                        withAnimation(.snappy) { category = pin.category; subcategory = pin.subcategory }
                    } label: {
                        HStack {
                            Text(pin.title)
                            Text(pin.merchant != nil ? (pin.subcategory ?? pin.category) : pin.category).font(.caption).foregroundStyle(Palette.secondary)
                            Spacer()
                            Text(format(cents)).monospacedDigit().bold()
                        }
                    }.buttonStyle(.plain).contextMenu { Button("Убрать из выделенного", role: .destructive) { toggle(pin) } }
                }
            }.padding(10).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder private func list(_ slices: [SpendingBreakdown.Slice], rows: [SpendRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(slices) { slice in
                let pin = SpendPin(category: category ?? slice.name, subcategory: category == nil ? nil : (subcategory ?? slice.name),
                                   merchant: subcategory == nil ? nil : slice.name)
                HStack(spacing: 10) {
                    Button { drill(slice, all: slices) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slice.name).font(.subheadline)
                                ProgressView(value: slice.share).tint(Palette.accent).frame(maxWidth: 160)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(format(slice.cents)).monospacedDigit()
                                Text(percent(slice.share)).font(.caption).foregroundStyle(Palette.secondary)
                            }
                            if subcategory == nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if category != nil {
                        Button { toggle(pin) } label: { Image(systemName: pins.contains(pin) ? "pin.fill" : "pin") }
                            .buttonStyle(.borderless).accessibilityLabel(pins.contains(pin) ? "Убрать из выделенного" : "Выделить отдельно")
                    }
                }.padding(.vertical, 8)
                Divider()
            }
            if let category, let subcategory {
                let operations = entries.filter { $0.kind == Flow.expense.rawValue && $0.category == category && Subcategories.resolve($0) == subcategory
                    && period.interval(offset: offset, now: .now, calendar: .autoupdatingCurrent).contains($0.date) }.sorted { $0.date > $1.date }
                Text("Операции").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                ForEach(operations) { entry in
                    Button { edit(entry) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Subcategories.merchant(entry.note)).font(.subheadline)
                                Text(entry.date.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month())).font(.caption).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Text(format(entry.cents)).monospacedDigit()
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ManagedCategory: Identifiable { let name: String; var id: String { name } }

/// Wrapping row of chips.
private struct FlowChips<Content: View>: View {
    let items: [SpendingBreakdown.Slice]
    @ViewBuilder let content: (SpendingBreakdown.Slice) -> Content
    var body: some View {
        ChipLayout(spacing: 6) { ForEach(items) { content($0) } }
    }
}

private struct ChipLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}

/// Add and rename subcategories of one category; renames carry over to existing operations.
private struct SubcategoryEditor: View {
    let category: String
    let entries: [Entry]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var names: [String] = []
    @State private var original: [String] = []
    @State private var newName = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Подкатегории «" + category + "»") {
                    ForEach(names.indices, id: \.self) { index in
                        TextField("Название", text: $names[index])
                    }
                    .onDelete { names.remove(atOffsets: $0); original.remove(atOffsets: $0) }
                }
                Section("Новая подкатегория") {
                    HStack {
                        TextField("Например, «Кофейни»", text: $newName)
                        Button("Добавить") {
                            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty, !names.contains(name) else { return }
                            names.append(name); original.append(""); newName = ""
                        }
                    }
                }
                Text("Переименование применяется и к уже записанным операциям. Подкатегорию операции можно сменить в самой операции.").font(.caption)
            }.formStyle(.grouped).navigationTitle("Подкатегории")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        for (old, new) in zip(original, names) where !old.isEmpty && old != new {
                            let target = new.trimmingCharacters(in: .whitespacesAndNewlines)
                            for entry in entries where entry.category == category && Subcategories.resolve(entry) == old {
                                entry.subcategory = target.isEmpty ? nil : target
                            }
                        }
                        try? context.save()
                        Subcategories.save(names, for: category)
                        dismiss()
                    }
                }
            }
            .onAppear { names = Subcategories.list(for: category); original = names }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 360)
        #endif
    }
}
