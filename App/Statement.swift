import Foundation
import SwiftData
import CryptoKit

@Model final class StatementSource {
    var digest: String
    var name: String
    @Attribute(.externalStorage) var bytes: Data
    init(_ document: BankDocument) {
        digest = document.digest
        name = document.name
        bytes = document.bytes
    }
}

struct BankDocument: Sendable {
    let name: String
    let bytes: Data
    let digest: String
    init(name: String, bytes: Data) {
        self.name = name
        self.bytes = bytes
        digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct ImportLine: Identifiable {
    let id = UUID()
    let source: String
    var ordinal: Int
    var original: String
    var date: Date?
    var partialDay: Int?
    var partialMonth: Int?
    var amount = ""
    var flow: Flow?
    var category = "Другое"
    var note = ""
    var method = "local"
    var reference = ""
    var account = ""
    var destination = ""
    var reviewRequired = false
    var selected = true
    var confirmedSimilar = false
    /// The owner chose to add a row dated before the opening balances, for reports only.
    var includeBeforeCutoff = false
    var summary = false
    var since: Date?
    var cents: Int64? { BankRead.cents(amount) }
    var valid: Bool {
        guard let date, date < (Calendar.current.dateInterval(of: .day, for: .now)?.end ?? .now), let cents, cents > 0, let flow,
              !account.isEmpty, !category.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if summary { return flow != .transfer && since.map { Calendar.current.startOfDay(for: $0) <= date } == true }
        return flow != .transfer || (!destination.isEmpty && destination != account)
    }
    var token: String { source + ":" + method + ":" + String(ordinal) }
}

enum BankRead {
    static let rubleCodes = ["rub", "rur", "₽", "руб", "руб."]
    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "ё", with: "е")
    }
    static func cents(_ text: String) -> Int64? {
        var t = clean(text).replacingOccurrences(of: "−", with: "-")
        for unit in ["₽", "rub", "rur", "руб.", "руб"] where t.hasSuffix(unit) {
            t = String(t.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        // "1,234.56": comma groups thousands only when a dot decimal part follows.
        if t.wholeMatch(of: /[+\-]?[0-9]{1,3}(?:,[0-9]{3}){1,3}\.[0-9]{1,2}/) != nil {
            t = t.replacingOccurrences(of: ",", with: "")
        }
        guard t.wholeMatch(of: /[+\-]?(?:[0-9]{1,12}|[0-9]{1,3}(?:[ \u{00a0}\u{202f}][0-9]{3}){1,3})(?:[.,][0-9]{1,2})?/) != nil else { return nil }
        let digits = t.filter { !$0.isWhitespace && $0 != "+" && $0 != "-" }.replacingOccurrences(of: ",", with: ".")
        guard let d = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return NSDecimalNumber(decimal: d * 100).int64Value
    }
    static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in ["dd.MM.yyyy HH:mm:ss", "dd.MM.yyyy HH:mm", "dd.MM.yyyy", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: t), formatter.string(from: date) == t { return date }
        }
        return nil
    }
    static func suggest(_ text: String) -> String {
        let value = clean(text)
        let rules = [("Продукты", ["продукт", "пятероч", "супермаркет", "перекресток"]), ("Кафе", ["кафе","ресторан","кофе"]), ("Транспорт", ["метро","такси","транспорт"]), ("Зарплата", ["зарплат"]), ("Здоровье", ["аптек","здоровье"]), ("Подписки", ["подписк"]), ("Благотворительность", ["пожертв","благотвор"])]
        return rules.first { $0.1.contains(where: value.contains) }?.0 ?? "Другое"
    }
    static func direction(_ text: String, amount: String) -> Flow? {
        let t = clean(text)
        if ["расход","списание","дебет","expense","debit"].contains(t) { return .expense }
        if ["доход","приход","зачисление","поступление","кредит","income","credit"].contains(t) { return .income }
        if ["перевод","transfer"].contains(t) { return .transfer }
        let n = amount.trimmingCharacters(in: .whitespaces)
        if n.hasPrefix("+") { return .income }
        if n.hasPrefix("-") || n.hasPrefix("−") { return .expense }
        return nil
    }

    // RFC-style quoting, embedded separators and line breaks, including CRLF.
    static func table(_ text: String, separator: Character) -> [[String]] {
        var rows = [[String]](), fields = [String](), field = "", quoted = false
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i+1] == "\"" { field.append(c); i += 1 }
                else { quoted.toggle() }
            } else if !quoted && c == separator { fields.append(field); field = "" }
            else if !quoted && c == "\n" {
                fields.append(field); rows.append(fields); fields = []; field = ""
            } else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !fields.isEmpty { fields.append(field); rows.append(fields) }
        return rows
    }
    static func lines(_ text: String, source: String) -> [ImportLine] {
        let text = text.replacingOccurrences(of: "\u{feff}", with: "")
        let dates = ["дата операции", "дата", "date", "дата платежа", "дата проводки"]
        for separator: Character in [";", "\t", ","] {
            let rows = table(text, separator: separator)
            guard let h = rows.prefix(40).firstIndex(where: { row in row.count > 1 && row.contains { dates.contains(clean($0)) } }) else { continue }
            let headers = rows[h].map(clean)
            return rows.indices.dropFirst(h + 1).compactMap { index in
                let values = rows[index]
                guard values.contains(where: { !clean($0).isEmpty }) else { return nil }
                func value(_ names: [String]) -> String {
                    for name in names {
                        if let i = headers.firstIndex(of: name), i < values.count, !clean(values[i]).isEmpty { return values[i] }
                    }
                    return ""
                }
                var line = ImportLine(source: source, ordinal: index, original: values.joined(separator: " | "))
                line.date = date(value(dates))
                line.note = value(["описание","назначение платежа","описание операции","получатель","description","note"])
                line.reference = value(["идентификатор операции","id операции","transaction id","transaction_id"])
                line.category = value(["категория","category"])
                if line.category.isEmpty { line.category = suggest(line.note) }
                let debit = value(["расход","списание","дебет","debit"]), credit = value(["доход","приход","поступление","зачисление","кредит","credit"])
                let currencyColumns = ["валюта операции", "валюта", "currency"]
                let foreignCurrency = clean(value(currencyColumns + ["валюта платежа"]))
                let d = cents(debit) ?? 0, c = cents(credit) ?? 0
                if d > 0 && c == 0 && (credit.isEmpty || cents(credit) == 0) { line.amount = debit; line.flow = .expense }
                else if c > 0 && d == 0 && (debit.isEmpty || cents(debit) == 0) { line.amount = credit; line.flow = .income }
                else if d == 0 && c == 0 && (debit.isEmpty || cents(debit) == 0) && (credit.isEmpty || cents(credit) == 0) {
                    let payment = value(["сумма платежа"])
                    line.amount = payment.isEmpty ? value(["сумма","сумма операции","amount"]) : payment
                    line.flow = direction(value(["тип","тип операции","type","направление"]), amount: line.amount)
                    let currency = clean(payment.isEmpty ? value(currencyColumns + ["валюта платежа"]) : value(["валюта платежа"] + currencyColumns))
                    if !currency.isEmpty && !rubleCodes.contains(currency) { line.amount = "" }
                }
                if (d > 0 || c > 0) && !foreignCurrency.isEmpty && !rubleCodes.contains(foreignCurrency) { line.amount = "" }
                let signed = clean(line.amount)
                if (line.flow == .income && (signed.hasPrefix("-") || signed.hasPrefix("−"))) || (line.flow == .expense && signed.hasPrefix("+")) { line.selected = false }
                if ["итого", "остаток", "баланс"].contains(where: { clean(line.note).hasPrefix($0) }) { line.selected = false }
                let transferHint = clean([line.category, line.note].joined(separator: " "))
                if transferHint.contains("между своими") || transferHint.contains("погашение кредит") {
                    line.flow = .transfer
                    line.selected = false
                } else if clean(line.category).contains("перевод") { line.selected = false }
                let state = clean(value(["статус","статус операции","status"]))
                if !state.isEmpty && !["ok","исполнено","проведена","успешно","completed","success"].contains(state) { line.selected = false }
                if !value(["проверка формул"]).isEmpty {
                    line.original += " · Значение формулы взято из сохранённого расчёта Excel. Сверьте его перед включением."
                    line.selected = false
                }
                if !line.validWithoutAccount { line.selected = false }
                line.reviewRequired = !line.selected
                return line
            }
        }
        let monthNames = ["января","февраля","марта","апреля","мая","июня","июля","августа","сентября","октября","ноября","декабря"]
        var result = [ImportLine](), day: Date?, partialDay: Int?, partialMonth: Int?
        let byCategory = clean(text).contains("по категориям")
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let raw = raw.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            if let standalone = date(raw) { day = standalone; partialDay = nil; partialMonth = nil; continue }
            let heading = clean(raw)
            if heading == "сегодня" || heading == "вчера" {
                day = nil; partialDay = nil; partialMonth = nil; continue
            }
            if let match = heading.wholeMatch(of: /([0-9]{1,2}) ([а-я]+)(?: ([0-9]{4}))?(?:, [а-я]+)?/),
               let index = monthNames.firstIndex(of: String(match.2)), let number = Int(match.1), (1...31).contains(number) {
                partialDay = number; partialMonth = index + 1
                day = match.3.flatMap { year in date(String(format: "%02d.%02d.", number, index + 1) + year) }
                continue
            }
            var line = ImportLine(source: source, ordinal: i, original: raw)
            var description = raw
            if let m = raw.firstMatch(of: /(?:[0-9]{2}\.[0-9]{2}\.[0-9]{4}|[0-9]{4}-[0-9]{2}-[0-9]{2})(?: [0-9]{2}:[0-9]{2}(?::[0-9]{2})?)?/) {
                day = date(String(m.0)); partialDay = nil; partialMonth = nil
                description.removeSubrange(m.range)
            }
            line.date = day; line.partialDay = partialDay; line.partialMonth = partialMonth
            if let m = description.firstMatch(of: /([+−\-]?\s*[0-9]+(?:[ \u{00a0}\u{202f}][0-9]{3})*(?:[,.][0-9]{1,2})?\s*(?:₽|руб\.?|RUB))\s*$/) {
                let prefix = description[..<m.range.lowerBound].trimmingCharacters(in: .whitespaces)
                let ambiguous = prefix.last.map { $0.isNumber || $0 == "." || $0 == "," } == true ||
                    prefix.contains("₽") || prefix.uppercased().contains("RUB") || prefix.lowercased().contains("руб.")
                let amount = ambiguous ? "" : String(m.1).trimmingCharacters(in: .whitespaces)
                line.amount = amount.replacing(/([+−\-])\s+/) { String($0.1) }
                line.flow = direction("", amount: line.amount)
                if !ambiguous { description.removeSubrange(m.range) }
            }
            line.note = description.trimmingCharacters(in: .whitespaces)
            line.category = suggest(line.note)
            if byCategory && line.cents != nil {
                line.summary = true
                if line.category == "Другое" && !line.note.isEmpty { line.category = line.note }
            }
            // Unstructured pages may contain balances, totals and several monetary columns.
            // Each OCR candidate needs explicit inclusion after comparison with the original.
            line.selected = false; line.reviewRequired = true
            result.append(line)
        }
        return result
    }
}
extension ImportLine {
    var validWithoutAccount: Bool { date != nil && flow != nil && (cents ?? 0) > 0 }
}
