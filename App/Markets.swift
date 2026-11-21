import SwiftUI
import SwiftData

enum Holding: String, CaseIterable, Identifiable {
    case gold = "excel-20260901-7", silver = "excel-20260901-8", crypto = "excel-20260901-11"
    var id: String { rawValue }
    var unit: String { self == .crypto ? "USD" : "г" }
    var initialQuantity: String {
        openingQuantity(in: Archive.bundled?.months.last?.lines ?? []) ?? ""
    }
    func openingQuantity(in lines: [Archive.Line]) -> String? {
        let titlePrefix: String
        switch self {
        case .gold: titlePrefix = "Золото"
        case .silver: titlePrefix = "Серебро"
        case .crypto: titlePrefix = "Крипта"
        }
        guard let title = lines.first(where: { $0.title.hasPrefix(titlePrefix) })?.title,
              let dash = title.firstIndex(of: "—") else { return nil }
        let description = title[title.index(after: dash)...]
        if self == .crypto {
            return description.firstMatch(of: /\$([0-9]+(?:[,.][0-9]+)?)/).map { String($0.1) }
        }
        return description.firstMatch(of: /([0-9]+(?:[,.][0-9]+)?)\s*г(?:\s|$)/).map { String($0.1) }
    }
    var rule: String {
        switch self {
        case .gold: "Золото 585 · опт без НДС + 150 ₽/г"
        case .silver: "Серебро 900 · цена 999 пробы × 0,9"
        case .crypto: "Оценка крипты в USD × курс ЦБ"
        }
    }
}

struct MarketPrices: Codable {
    var gold: Decimal
    var silver: Decimal
    var usd: Decimal
    var metalsChecked: Date
    var currencyDate: String
    var currencyChecked: Date?
    /// Euro rate from the same Central Bank feed. Older caches have no value until the next refresh.
    var eur: Decimal? = nil
    /// Where the metals price came from when Регион Золото was unreachable (nil: Регион Золото).
    var metalsSource: String? = nil

    /// The dollar and euro rates are older than an hour, or the euro was never loaded.
    func needsCurrencyRefresh(at now: Date) -> Bool {
        guard let currencyChecked, eur != nil else { return true }
        return now.timeIntervalSince(currencyChecked) >= 3600 || currencyChecked > now
    }

    func needsRefresh(at now: Date) -> Bool {
        guard let currencyChecked else { return true }
        return [metalsChecked, currencyChecked].contains { now.timeIntervalSince($0) >= 3600 || $0 > now }
    }

    static let wholesale = URL(string: "https://www.region-zoloto.ru/zoloto-optom")!
    static let centralBank = URL(string: "https://www.cbr.ru/scripts/XML_daily.asp")!

    // First offline observation from the same feeds used for refresh.
    static let initial = MarketPrices(gold: 5592, silver: 99, usd: Decimal(string: "82.2281")!,
                                      metalsChecked: ISO8601DateFormatter().date(from: "2026-11-19T05:04:00+08:00")!,
                                      currencyDate: "19.11.2026")
    func unitPrice(_ holding: Holding) -> Decimal {
        switch holding { case .gold: gold + 150; case .silver: silver * 9 / 10; case .crypto: usd }
    }

    func valuation(of holding: Holding, quantity: String) -> Int64? {
        let input = quantity.replacingOccurrences(of: ",", with: ".")
        guard input.wholeMatch(of: /[0-9]{1,7}(\.[0-9]{1,6})?/) != nil, let units = Decimal(string: input) else { return nil }
        var raw = units * unitPrice(holding) * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 0, .plain)
        // Keep checkpoints within the exact amount range accepted by reconciliation.
        guard !rounded.isNaN, rounded >= 0, rounded <= 99_999_999_999_999 else { return nil }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    static func positiveNumber(_ text: String) throws -> Decimal {
        let normalized = text.filter { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".")
        guard normalized.wholeMatch(of: /[0-9]{1,8}(\.[0-9]{1,6})?/) != nil,
              let value = Decimal(string: normalized), value > 0 else { throw URLError(.cannotParseResponse) }
        return value
    }

    static func metals(_ html: String) throws -> (Decimal, Decimal) {
        guard let start = html.range(of: "id=\"pricends\""),
              let table = html[start.upperBound...].components(separatedBy: "</table>").first,
              table.contains("Золото 585"), table.contains("Серебро 999"),
              let beginning = table.range(of: "Без учёта НДС"),
              let row = table[beginning.upperBound...].components(separatedBy: "</tr>").first,
              let gold = row.firstMatch(of: /data-price="130">([^<]+)</),
              let silver = row.firstMatch(of: /data-price="136">([^<]+)</) else { throw URLError(.cannotParseResponse) }
        return try (positiveNumber(String(gold.1)), positiveNumber(String(silver.1)))
    }

    static func currency(_ xml: String) throws -> (Decimal, String) {
        let feed = try rates(xml)
        return (feed.usd, feed.date)
    }

    /// Dollar (required) and euro (when present and valid) per one unit, in rubles.
    static func rates(_ xml: String) throws -> (usd: Decimal, eur: Decimal?, date: String) {
        // The network response was decoded from its declared Windows-1251 encoding.
        // Feed the parser bytes with the same encoding so its declaration stays valid.
        guard !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY"),
              let bytes = xml.data(using: .windowsCP1251) else { throw URLError(.cannotParseResponse) }
        let parser = XMLParser(data: bytes)
        let reader = DollarRateReader()
        parser.delegate = reader
        guard parser.parse(), parser.parserError == nil, let date = reader.date,
              BankRead.date(date) != nil, date.count == 10, date.contains("."),
              let usd = reader.rates["USD"], usd.nominal.wholeMatch(of: /[1-9][0-9]{0,7}/) != nil else { throw URLError(.cannotParseResponse) }
        var eur: Decimal?
        if let euro = reader.rates["EUR"], euro.nominal.wholeMatch(of: /[1-9][0-9]{0,7}/) != nil {
            eur = try? positiveNumber(euro.value) / positiveNumber(euro.nominal)
        }
        return try (positiveNumber(usd.value) / positiveNumber(usd.nominal), eur, date)
    }

    /// Fresh Central Bank rates applied to `prices`, or nil when the feed cannot be read.
    static func withCurrentRates(_ prices: MarketPrices) async -> MarketPrices? {
        guard let xml = try? await load(centralBank, encoding: .windowsCP1251),
              let feed = try? rates(xml) else { return nil }
        var next = prices
        next.usd = feed.usd
        next.eur = feed.eur ?? prices.eur
        next.currencyDate = feed.date
        next.currencyChecked = .now
        return next
    }

    static func load(_ url: URL, encoding: String.Encoding) async throws -> String {
        // Demo mode works offline with the built-in rates.
        if DemoMode.isOn { throw URLError(.notConnectedToInternet) }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: MarketRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        let byteLimit = 2 * 1024 * 1024
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.expectedContentLength <= Int64(byteLimit) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        guard let text = String(data: data, encoding: encoding) else { throw URLError(.cannotDecodeContentData) }
        return text
    }
}

private final class MarketRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.host == task.originalRequest?.url?.host else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private final class DollarRateReader: NSObject, XMLParserDelegate {
    var date: String?
    var rates: [String: (value: String, nominal: String)] = [:]
    private var fields: [String: String] = [:]
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        text = ""
        if elementName == "ValCurs" { date = attributes["Date"] }
        if elementName == "Valute" { fields.removeAll() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "CharCode", "Nominal", "Value":
            fields[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "Valute":
            if let code = fields["CharCode"], ["USD", "EUR"].contains(code),
               let value = fields["Value"], let nominal = fields["Nominal"] {
                rates[code] = (value, nominal)
            }
        default: break
        }
    }
}

struct MarketView: View {
    let accounts: [AccountBalance]
    @AppStorage("markets.prices") private var cache = Data()
    @State private var loading = false
    @State private var status = ""
    private var prices: MarketPrices { (try? JSONDecoder().decode(MarketPrices.self, from: cache)) ?? .initial }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Рыночная оценка").font(.headline)
                Spacer()
                Button { Task { await refresh() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }.disabled(loading)
            }
            if loading { ProgressView() }
            ForEach(Holding.allCases) { holding in
                if let account = accounts.first(where: { $0.id == holding.id }) {
                    HoldingTile(holding: holding, account: account, prices: prices)
                }
            }
            if !status.isEmpty { Text(status).font(.caption) }
            HStack {
                Link("Регион Золото", destination: MarketPrices.wholesale)
                Spacer()
                Link("Курс ЦБ РФ", destination: MarketPrices.centralBank)
            }.font(.caption)
        }
    }

    @MainActor private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let (next, errors) = await MarketPrices.refreshed(prices)
        if let data = try? JSONEncoder().encode(next) { cache = data }
        status = errors.isEmpty ? "Котировки обновлены" : "Сохранена предыдущая цена: " + errors.map(\.source).joined(separator: ", ")
    }
}

private struct HoldingTile: View {
    static func priceLine(_ holding: Holding, prices: MarketPrices) -> String {
        let price: String = prices.unitPrice(holding).formatted(.number.precision(.fractionLength(0...4)))
        let when: String = holding == .crypto ? prices.currencyDate : prices.metalsChecked.formatted(date: .numeric, time: .shortened)
        return "\(price) ₽/\(holding.unit) · \(when)"
    }
    let holding: Holding
    let account: AccountBalance
    let prices: MarketPrices
    @AppStorage private var savedQuantity: String
    @Query private var lotRecords: [FinanceRecord]
    @State private var quantity: String
    @FocusState private var editingQuantity: Bool
    @State private var feedback = ""
    @Environment(\.modelContext) private var context

    init(holding: Holding, account: AccountBalance, prices: MarketPrices) {
        self.holding = holding
        self.account = account
        self.prices = prices
        let key = "quantity." + holding.id
        _savedQuantity = AppStorage(wrappedValue: holding.initialQuantity, key)
        _quantity = State(initialValue: UserDefaults.standard.string(forKey: key) ?? holding.initialQuantity)
    }
    private var valuation: Int64? {
        let net = ((try? LotMovement.decode(lotRecords)) ?? []).filter { $0.asset == holding.id }.reduce(Int64(0)) { $0 + $1.units }
        if net == 0 { return prices.valuation(of: holding, quantity: quantity) }
        let typed = quantity.isEmpty ? "0" : quantity.replacingOccurrences(of: ",", with: ".")
        // Decimal(string:) accepts a numeric prefix such as "12abc"; require the whole text to be a number.
        guard typed.wholeMatch(of: /[0-9]{1,7}(\.[0-9]{1,6})?/) != nil, let initial = Decimal(string: typed) else { return nil }
        let units = initial + Decimal(net) / 1_000_000
        return prices.valuation(of: holding, quantity: NSDecimalNumber(decimal: units).stringValue)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(account.position.title).font(.headline)
            Text(valuation.map(money) ?? "Проверь количество").font(.title2.bold())
            LabeledContent("Количество вне партий, " + holding.unit) {
                TextField(holding.unit, text: $quantity).focused($editingQuantity).textFieldStyle(.roundedBorder).frame(maxWidth: 100)
            }
            .onChange(of: editingQuantity) { _, editing in
                if !editing, valuation != nil { savedQuantity = quantity }
            }
            .onChange(of: savedQuantity) { _, updated in
                if !editingQuantity { quantity = updated }
            }
            .onDisappear { if valuation != nil { savedQuantity = quantity } }
            Text(holding.rule).font(.subheadline)
            Text(Self.priceLine(holding, prices: prices))
                .font(.caption).foregroundStyle(.secondary)
            Text("В капитале: " + money(account.position.amount)).font(.caption)
            Text("Оценка по этой цене автоматически входит в капитал.").font(.caption).foregroundStyle(.secondary)
            if !feedback.isEmpty { Text(feedback).font(.caption) }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Currency used to show totals. Amounts are kept in rubles and converted at the Central Bank rate.
enum DisplayCurrency: String, CaseIterable, Identifiable {
    case rub = "RUB", usd = "USD", eur = "EUR"
    var id: Self { self }
    var symbol: String {
        switch self { case .rub: "₽"; case .usd: "$"; case .eur: "€" }
    }
    /// Rubles per one unit of the currency, or nil when the rate is not loaded yet.
    func rate(_ prices: MarketPrices) -> Decimal? {
        switch self {
        case .rub: 1
        case .usd: prices.usd > 0 ? prices.usd : nil
        case .eur: prices.eur.flatMap { $0 > 0 ? $0 : nil }
        }
    }
    /// Amount in this currency, or nil without a rate.
    func amount(_ cents: Int64, prices: MarketPrices) -> Decimal? {
        guard let rate = rate(prices) else { return nil }
        return Decimal(cents) / 100 / rate
    }
    /// Stored choice, or rubles when that currency has no rate yet.
    static func selected(_ code: String, prices: MarketPrices) -> DisplayCurrency {
        guard let choice = DisplayCurrency(rawValue: code), choice.rate(prices) != nil else { return .rub }
        return choice
    }
    /// Value for charts in whole units of this currency (rubles without a rate).
    func plotted(_ cents: Int64, prices: MarketPrices) -> Double {
        NSDecimalNumber(decimal: amount(cents, prices: prices) ?? Decimal(cents) / 100).doubleValue
    }
    func format(_ cents: Int64, prices: MarketPrices) -> String {
        if DemoMode.isOn { return DemoMode.masked(symbol) }
        if self == .rub { return money(cents) }
        guard let value = amount(cents, prices: prices) else { return "курс недоступен" }
        return value.formatted(.currency(code: rawValue).locale(Locale(identifier: "ru_RU")))
    }
}

/// Picker ₽ / $ / € plus the Central Bank rates it uses. Refreshes the rates once an hour.
struct CurrencySwitch: View {
    @AppStorage("display.currency") private var selected = DisplayCurrency.rub.rawValue
    @AppStorage("markets.prices") private var cache = Data()
    @State private var loading = false
    var showsRates = true
    private var prices: MarketPrices { (try? JSONDecoder().decode(MarketPrices.self, from: cache)) ?? .initial }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Picker("Валюта", selection: $selected) {
                ForEach(DisplayCurrency.allCases) { option in
                    Text(option.symbol).tag(option.rawValue).selectionDisabled(option.rate(prices) == nil)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 132)
            .help("Показать суммы в рублях, долларах или евро по курсу ЦБ РФ")
            if showsRates { CurrencyRatesNote(prices: prices, loading: loading) }
        }
    }
}

struct CurrencyRatesNote: View {
    let prices: MarketPrices
    var loading = false
    var body: some View {
        let rate = { (value: Decimal) in value.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "ru_RU"))) + " ₽" }
        let euro = " · € " + (prices.eur.map(rate) ?? "курс недоступен")
        let prefix: String = loading ? "Обновляю курс… " : ""
        let usd: String = rate(prices.usd)
        Text("\(prefix)Курс ЦБ на \(prices.currencyDate): $ \(usd)\(euro)")
            .font(.caption).foregroundStyle(Palette.secondary).monospacedDigit()
    }
}

struct NewDebt: View {
    let isLoan: Bool
    @State private var name = ""
    @State private var amount = ""
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    private var cents: Int64? {
        let text = amount.replacingOccurrences(of: ",", with: ".")
        guard text.wholeMatch(of: /[0-9]{1,12}(\.[0-9]{1,2})?/) != nil,
              let value = Decimal(string: text), value > 0 else { return nil }
        return NSDecimalNumber(decimal: value * 100).int64Value
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField(isLoan ? "Кредитор или банк" : "Кто должен", text: $name)
                TextField("Остаток долга, ₽", text: $amount)
                Text("Введите остаток на сегодня. Последующие платежи можно записать переводом.").font(.caption)
            }.formStyle(.grouped).navigationTitle(isLoan ? "Добавить кредит" : "Добавить должника")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") {
                            guard let cents else { return }
                            let position = Archive.Position(title: name.trimmingCharacters(in: .whitespacesAndNewlines), amount: cents, debt: isLoan)
                            context.insert(Checkpoint(position: position, key: (isLoan ? "loan-" : "receivable-") + UUID().uuidString, date: .now))
                            do { try context.save(); dismiss() } catch { context.rollback(); failed = true }
                        }.disabled(cents == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 250)
        #endif
        .alert("Не удалось сохранить долг", isPresented: $failed) { Button("ОК") {} }
    }
}
