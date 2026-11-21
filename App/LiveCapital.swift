import SwiftUI
import SwiftData

/// A card or account kept in another currency: how many units it held at the opening balance and at what rate.
struct ForeignHolding: Codable, Equatable {
    let currency: String
    /// Hundredths of the currency at the opening balance (6 200 = $62).
    let units: Int64
    /// Rubles per unit at which the account's ruble balance was set.
    var rate: Decimal
    /// The balance date `rate` belongs to; a later reconciliation re-anchors it.
    var since: Date? = nil
}

/// Net worth at today's prices: metals by the Регион Золото quote, currency cards by the Central Bank rate.
/// Nothing is written to the ledger; balances are revalued each time they are shown.
enum LiveCapital {
    static let foreignKey = "accounts.foreign"

    static func foreign(_ defaults: UserDefaults = .standard) -> [String: ForeignHolding] {
        defaults.data(forKey: foreignKey).flatMap { try? JSONDecoder().decode([String: ForeignHolding].self, from: $0) } ?? [:]
    }

    /// Dollar cards from the fresh start, for a device seeded before the map existed: the opening rate is read
    /// back from their ruble balance.
    @MainActor static func migrateIfNeeded(_ checkpoints: [Checkpoint], defaults: UserDefaults = .standard, start: FreshStart? = FreshStart.bundled) {
        guard defaults.data(forKey: foreignKey) == nil, defaults.bool(forKey: ResetSeed.flag), let start else { return }
        var map = [String: ForeignHolding]()
        for account in start.accounts {
            guard let usd = account.usd?.value, usd > 0,
                  let mark = checkpoints.filter({ $0.key == account.key }).max(by: { $0.date < $1.date }), mark.amount > 0 else { continue }
            let units = Money.cents(usd)
            map[account.key] = ForeignHolding(currency: "USD", units: units, rate: Decimal(mark.amount) / Decimal(units))
        }
        defaults.set(try? JSONEncoder().encode(map), forKey: foreignKey)
    }

    /// Keeps each currency card's rate tied to its latest balance date: after a new reconciliation (entered in
    /// rubles at the day's rate) the rate becomes today's, so the new balance is not revalued twice.
    static func sync(_ accounts: [AccountBalance], prices: MarketPrices, defaults: UserDefaults = .standard) {
        var map = foreign(defaults)
        var changed = false
        for (key, holding) in map {
            guard let account = accounts.first(where: { $0.id == key }) else { continue }
            if holding.since == nil { map[key]?.since = account.cutoff; changed = true }
            else if let since = holding.since, account.cutoff > since, let now = rate(holding.currency, prices: prices) {
                map[key]?.rate = now; map[key]?.since = account.cutoff; changed = true
            }
        }
        if changed { defaults.set(try? JSONEncoder().encode(map), forKey: foreignKey) }
    }

    static func rate(_ currency: String, prices: MarketPrices) -> Decimal? {
        switch currency { case "USD": prices.usd; case "EUR": prices.eur; default: nil }
    }
    static func rounded(_ value: Decimal) -> Int64 {
        var raw = value, result = Decimal()
        NSDecimalRound(&result, &raw, 0, .plain)
        return NSDecimalNumber(decimal: result).int64Value
    }

    static func apply(_ list: [AccountBalance], prices: MarketPrices, defaults: UserDefaults = .standard, lots: [LotMovement] = []) -> [AccountBalance] {
        let foreign = foreign(defaults)
        return list.map { account in
            var account = account
            if let holding = Holding(rawValue: account.id) {
                let typed = (defaults.string(forKey: "quantity." + holding.id) ?? holding.initialQuantity).replacingOccurrences(of: ",", with: ".")
                let net = lots.filter { $0.asset == holding.id }.reduce(Int64(0)) { $0 + $1.units }
                if typed.wholeMatch(of: /[0-9]{1,7}(\.[0-9]{1,6})?/) != nil, let base = Decimal(string: typed),
                   let value = prices.valuation(of: holding, quantity: NSDecimalNumber(decimal: base + Decimal(net) / 1_000_000).stringValue) {
                    account.position.amount = value
                }
            } else if let holding = foreign[account.id], let now = rate(holding.currency, prices: prices), holding.rate > 0 {
                // The ruble balance (opening amount plus spending recorded in rubles) is the card's currency
                // at `rate`; today it is worth the same currency at today's rate.
                account.position.amount = rounded(Decimal(account.position.amount) * now / holding.rate)
            }
            return account
        }
    }
}

/// Daily net worth snapshots: the first and last value seen each day, local time.
struct NetWorthDay: Codable, Equatable {
    var first: Int64
    var last: Int64
    /// Whether `first` was taken at fresh quotes; a stale morning value is replaced by the first fresh one.
    var fresh: Bool? = nil
}

enum NetWorthHistory {
    static let storageKey = "networth.days"
    /// The owner asked to count growth from 21 November 2026.
    static let baselineDay = "2026-11-21"

    static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func days(_ defaults: UserDefaults = .standard) -> [String: NetWorthDay] {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([String: NetWorthDay].self, from: $0) } ?? [:]
    }
    static func record(_ net: Int64, at now: Date, fresh: Bool = true, defaults: UserDefaults = .standard, calendar: Calendar = .autoupdatingCurrent) {
        var all = days(defaults)
        let today = key(now, calendar: calendar)
        if var day = all[today] {
            day.last = net
            if fresh && day.fresh != true { day.first = net; day.fresh = true }
            all[today] = day
        } else { all[today] = NetWorthDay(first: net, last: net, fresh: fresh) }
        defaults.set(try? JSONEncoder().encode(all), forKey: storageKey)
    }

    /// Net worth at the end of each completed month (the last value of its last recorded day), for the chart.
    static func monthEnds(now: Date, defaults: UserDefaults = .standard, calendar: Calendar = .autoupdatingCurrent) -> [(month: Date, cents: Int64)] {
        let all = days(defaults)
        let current = String(key(now, calendar: calendar).prefix(7))
        let byMonth = Dictionary(grouping: all.keys.filter { !$0.hasPrefix(current) }) { String($0.prefix(7)) }
        return byMonth.compactMap { month, keys in
            let parts = month.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2, let last = keys.max(), let value = all[last],
                  let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) else { return nil }
            return (start, value.last)
        }.sorted { $0.month < $1.month }
    }

    struct Change: Equatable {
        let cents: Int64
        let share: Double?
        /// The day compared with (yyyy-MM-dd), when it is an earlier day.
        var since: String? = nil
    }
    static func change(_ net: Int64, from base: Int64, since: String? = nil) -> Change {
        Change(cents: net - base, share: base == 0 ? nil : Double(net - base) / Double(abs(base)), since: since)
    }
    /// "за день" when compared with yesterday, otherwise "с 18 ноября": after skipped days the change covers several days.
    static func dailyTitle(_ change: Change?, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        guard let since = change?.since, let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
              since < key(yesterday, calendar: calendar), let date = FreshStart.day(since, calendar: calendar) else { return "за день" }
        return "с " + date.formatted(Date.FormatStyle(locale: Locale(identifier: "ru_RU"), calendar: calendar, timeZone: calendar.timeZone).day().month(.wide))
    }
    /// Against the last value of the most recent earlier day (or the first value today, on the first day).
    static func daily(_ net: Int64, now: Date, defaults: UserDefaults = .standard, calendar: Calendar = .autoupdatingCurrent) -> Change? {
        let all = days(defaults), today = key(now, calendar: calendar)
        if let previous = all.keys.filter({ $0 < today }).max(), let day = all[previous] { return change(net, from: day.last, since: previous) }
        return all[today].map { change(net, from: $0.first) }
    }
    /// Against the first value of 21 November, or of the first day recorded after it.
    static func sinceBaseline(_ net: Int64, defaults: UserDefaults = .standard) -> Change? {
        let all = days(defaults)
        guard let day = all.keys.filter({ $0 >= baselineDay }).min(), let value = all[day] else { return nil }
        return change(net, from: value.first)
    }
}

/// Two chips above the net worth: change for the day and since 21 November.
struct NetWorthChanges: View {
    let net: Int64
    let format: (Int64) -> String
    @AppStorage(NetWorthHistory.storageKey) private var stored = Data()

    var body: some View {
        let _ = stored
        HStack(spacing: 6) {
            let daily = NetWorthHistory.daily(net, now: .now)
            chip(NetWorthHistory.dailyTitle(daily, now: .now), daily)
            chip("с 21 ноября", NetWorthHistory.sinceBaseline(net))
        }
        .accessibilityElement(children: .combine)
        .help("Сравнение с последним значением прошлого дня и с 21 ноября. Учитываются и котировки, и операции.")
    }

    @ViewBuilder private func chip(_ title: String, _ change: NetWorthHistory.Change?) -> some View {
        let cents = change?.cents ?? 0
        let tone = cents > 0 ? Palette.positive : cents < 0 ? Palette.negative : Palette.secondary
        let percent = change?.share.map { ($0 > 0 ? "+" : $0 < 0 ? "−" : "") + abs($0).formatted(.percent.precision(.fractionLength(1)).locale(Locale(identifier: "ru_RU"))) } ?? "0,0 %"
        let amount = (cents > 0 ? "+" : cents < 0 ? "−" : "") + format(abs(cents))
        HStack(spacing: 4) {
            Image(systemName: cents > 0 ? "arrow.up.right" : cents < 0 ? "arrow.down.right" : "equal").font(.caption2.bold())
            Text(percent + " (" + amount + ")").monospacedDigit()
            Text(title).foregroundStyle(tone.opacity(0.75))
        }
        .font(.caption.weight(.semibold)).foregroundStyle(tone).lineLimit(1).minimumScaleFactor(0.7)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tone.opacity(0.12), in: Capsule())
    }
}

/// Once a day, on the first launch of the day; the result and its wording are kept for the rest of the day.
enum QuoteSchedule {
    static let dayKey = "markets.refreshDay"
    static let noteKey = "markets.note"
    static func due(now: Date, defaults: UserDefaults = .standard, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        defaults.string(forKey: dayKey) != NetWorthHistory.key(now, calendar: calendar)
    }
    static func done(now: Date, defaults: UserDefaults = .standard, calendar: Calendar = .autoupdatingCurrent) {
        defaults.set(NetWorthHistory.key(now, calendar: calendar), forKey: dayKey)
    }

    /// Plain wording: which quotes are fresh, which are kept from an earlier date and why.
    static func note(_ prices: MarketPrices, failed: [MarketPrices.Failure], at now: Date) -> String {
        let time = now.formatted(.dateTime.hour().minute())
        let metals = prices.metalsChecked.formatted(.dateTime.day().month(.twoDigits).hour().minute())
        let names = Set(failed.map(\.source))
        let metalsNote = prices.metalsSource == nil ? "" : " · золото и серебро по мировой цене (Регион Золото недоступен)"
        if failed.isEmpty { return "Котировки обновлены сегодня в " + time + " · курс ЦБ на " + prices.currencyDate + metalsNote }
        if names == ["ЦБ РФ"] { return "Золото обновлено в " + time + metalsNote + " · курс ЦБ на " + prices.currencyDate + " (ЦБ не ответил)" }
        if names == ["Регион Золото"] { return "Курс ЦБ обновлён в " + time + " · золото и серебро по цене от " + metals + " (Регион Золото не ответил)" }
        let offline = failed.allSatisfy(\.offline)
        return (offline ? "Нет интернета" : "Источники котировок не ответили") + " — цены от " + metals + ", курс ЦБ на " + prices.currencyDate
    }
}

/// Backup sources for when the Russian sites block a connection from abroad.
enum QuoteFallback {
    /// The same official Central Bank rates, published as JSON on a mirror that answers worldwide.
    static let cbrMirror = URL(string: "https://www.cbr-xml-daily.ru/daily_json.js")!
    static func world(_ metal: String) -> URL { URL(string: "https://api.gold-api.com/price/" + metal)! }
    static let ounce = Decimal(string: "31.1034768")!
    static let calibrationKey = "markets.calibration"

    static func mirrorRates(_ data: Data) throws -> (usd: Decimal, eur: Decimal?, date: String) {
        struct Feed: Decodable { let Date: String; let Valute: [String: Valute] }
        struct Valute: Decodable { let Value: Decimal; let Nominal: Decimal }
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        guard let usd = feed.Valute["USD"], usd.Value > 0, usd.Nominal > 0 else { throw URLError(.cannotParseResponse) }
        let eur = feed.Valute["EUR"].flatMap { $0.Value > 0 && $0.Nominal > 0 ? $0.Value / $0.Nominal : nil }
        // "2026-11-21T11:30:00+03:00" → "21.11.2026", like the Central Bank feed.
        let day = feed.Date.prefix(10).split(separator: "-")
        guard day.count == 3 else { throw URLError(.cannotParseResponse) }
        return (usd.Value / usd.Nominal, eur, day[2] + "." + day[1] + "." + day[0])
    }
    static func worldPrice(_ data: Data) throws -> Decimal {
        struct Quote: Decodable { let price: Decimal; let currency: String }
        let quote = try JSONDecoder().decode(Quote.self, from: data)
        guard quote.currency == "USD", quote.price > 0 else { throw URLError(.cannotParseResponse) }
        return quote.price
    }

    /// How Регион Золото relates to the world price (wholesale 585 against pure gold, silver 999),
    /// learned whenever both answer; the defaults were measured on 21.11.2026.
    struct Calibration: Codable, Equatable { var gold = 0.9713; var silver = 0.8475 }
    static func calibration(_ defaults: UserDefaults = .standard) -> Calibration {
        defaults.data(forKey: calibrationKey).flatMap { try? JSONDecoder().decode(Calibration.self, from: $0) } ?? Calibration()
    }
    /// Rubles per gram of pure metal from a dollar price per troy ounce.
    static func perGram(_ usdPerOunce: Decimal, usd: Decimal) -> Decimal { usdPerOunce * usd / ounce }
    static func rounded(_ value: Decimal) -> Decimal {
        var raw = value, result = Decimal()
        NSDecimalRound(&result, &raw, 0, .plain)
        return result
    }
    /// Регион Золото-equivalent prices (gold 585 wholesale, silver 999) from world prices.
    static func regional(gold: Decimal, silver: Decimal, usd: Decimal, calibration: Calibration) -> (Decimal, Decimal) {
        (rounded(perGram(gold, usd: usd) * Decimal(string: "0.585")! * Decimal(calibration.gold)),
         rounded(perGram(silver, usd: usd) * Decimal(calibration.silver)))
    }
    static func learn(regionGold: Decimal, regionSilver: Decimal, gold: Decimal, silver: Decimal, usd: Decimal) -> Calibration {
        let g = NSDecimalNumber(decimal: regionGold / (perGram(gold, usd: usd) * Decimal(string: "0.585")!)).doubleValue
        let s = NSDecimalNumber(decimal: regionSilver / perGram(silver, usd: usd)).doubleValue
        var result = Calibration()
        // Ignore implausible ratios (a broken page or a stale world price).
        if (0.8...1.1).contains(g) { result.gold = g }
        if (0.6...1.1).contains(s) { result.silver = s }
        return result
    }
}

extension MarketPrices {
    struct Failure: Equatable {
        let source: String
        let offline: Bool
        var detail = ""
    }

    /// Fresh Регион Золото metals and Central Bank rates, each source on its own with up to three tries.
    /// Whatever cannot be loaded keeps its cached value. Runs detached from any view, so leaving or
    /// redrawing a screen never cancels it halfway.
    static func refreshed(_ prices: MarketPrices) async -> (MarketPrices, failed: [Failure]) {
        await Task.detached { () -> (MarketPrices, [Failure]) in
            var next = prices, failed = [Failure]()
            func attempt<T>(_ work: () async throws -> T) async -> Result<T, Error> {
                var last: Error = URLError(.unknown)
                for round in 0..<3 {
                    do { return .success(try await work()) } catch { last = error }
                    if round < 2 { try? await Task.sleep(for: .seconds(Double(round + 1) * 1.5)) }
                }
                return .failure(last)
            }
            func offline(_ error: Error) -> Bool {
                [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff].contains((error as? URLError)?.code)
            }
            // Currency first: the world metals price needs the dollar rate.
            var currencyError: Error?
            switch await attempt({ try rates(try await load(centralBank, encoding: .windowsCP1251)) }) {
            case .success(let feed):
                (next.usd, next.currencyDate) = (feed.usd, feed.date)
                next.eur = feed.eur ?? next.eur
                next.currencyChecked = .now
            case .failure(let error): currencyError = error
            }
            if currencyError != nil {
                switch await attempt({ try QuoteFallback.mirrorRates(try await URLSession.shared.data(from: QuoteFallback.cbrMirror).0) }) {
                case .success(let feed):
                    (next.usd, next.currencyDate) = (feed.usd, feed.date)
                    next.eur = feed.eur ?? next.eur
                    next.currencyChecked = .now
                case .failure(let error):
                    failed.append(Failure(source: "ЦБ РФ", offline: offline(error), detail: String(describing: currencyError!) + " / " + String(describing: error)))
                }
            }
            let region = await attempt({ try metals(try await load(wholesale, encoding: .utf8)) })
            let world = await attempt({ () async throws -> (Decimal, Decimal) in
                (try QuoteFallback.worldPrice(try await URLSession.shared.data(from: QuoteFallback.world("XAU")).0),
                 try QuoteFallback.worldPrice(try await URLSession.shared.data(from: QuoteFallback.world("XAG")).0))
            })
            switch (region, world) {
            case (.success(let pair), _):
                (next.gold, next.silver) = pair; next.metalsChecked = .now; next.metalsSource = nil
                if case .success(let w) = world, next.currencyChecked.map({ Date.now.timeIntervalSince($0) < 86_400 }) == true {
                    let learned = QuoteFallback.learn(regionGold: pair.0, regionSilver: pair.1, gold: w.0, silver: w.1, usd: next.usd)
                    UserDefaults.standard.set(try? JSONEncoder().encode(learned), forKey: QuoteFallback.calibrationKey)
                }
            case (.failure, .success(let w)):
                (next.gold, next.silver) = QuoteFallback.regional(gold: w.0, silver: w.1, usd: next.usd, calibration: QuoteFallback.calibration())
                next.metalsChecked = .now
                next.metalsSource = "мировая цена"
            case (.failure(let error), .failure(let other)):
                failed.append(Failure(source: "Регион Золото", offline: offline(error) && offline(other), detail: String(describing: error) + " / " + String(describing: other)))
            }
            return (next, failed)
        }.value
    }
}
