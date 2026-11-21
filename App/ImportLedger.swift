import Foundation
import SwiftData

enum ImportIssue: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

struct ImportPlan {
    var additions: [(ImportLine, Int64)] = []
    var replacements: [(Entry, Int64)] = []
    var skipped: [UUID: String] = [:]
    var similar: Set<UUID> = []
    /// Rows dated before the account's opening balance: the balance already includes them.
    var beforeCutoff: Set<UUID> = []
    var matchNotes: [UUID: String] = [:]
    var errors: [String] = []
    var adjusted: [UUID: Int64] = [:]
    // Snapshot amounts, since SwiftData objects in an older preview can update in place.
    var residualAmounts: [PersistentIdentifier: Int64] = [:]

    func balanceChanges(accounts: [AccountBalance]) -> [String: Int64] {
        let lookup = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var delta = [String: Int64]()
        func post(_ key: String?, _ cash: Int64, _ date: Date) {
            guard let key, let account = lookup[key], date > account.cutoff else { return }
            delta[key, default: 0] += account.position.debt ? -cash : cash
        }
        for (line, cents) in additions {
            guard let date = line.date else { continue }
            post(line.account, line.flow == .income ? cents : -cents, date)
            if line.flow == .transfer { post(line.destination, cents, date) }
        }
        for (summary, residual) in replacements {
            let change = residual - summary.cents
            post(summary.accountKey, summary.income ? change : -change, summary.date)
        }
        return delta
    }

    func agrees(with other: ImportPlan) -> Bool {
        additions.map { $0.0.id } == other.additions.map { $0.0.id } &&
        additions.map { $0.1 } == other.additions.map { $0.1 } &&
        skipped == other.skipped && residualAmounts == other.residualAmounts
    }
}

enum ImportLedger {
    /// `cutoffs` are the accounts' balance dates: older statement rows are already part of those balances.
    static func plan(_ rows: [ImportLine], entries: [Entry], cutoffs: [String: Date] = [:]) -> ImportPlan {
        var plan = ImportPlan()
        var accepted: [ImportLine] = []
        let cal = Calendar.current
        func period(_ line: ImportLine) -> DateInterval? {
            guard let first = line.since, let last = line.date,
                  let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last)) else { return nil }
            return DateInterval(start: cal.startOfDay(for: first), end: end)
        }
        func inside(_ date: Date, _ period: DateInterval) -> Bool { date >= period.start && date < period.end }
        func sameGroup(_ line: ImportLine, _ entry: Entry) -> Bool {
            line.account == entry.accountKey && line.flow?.rawValue == entry.kind && BankRead.clean(line.category) == BankRead.clean(entry.category)
        }
        struct CandidateKey: Hashable { let day: Date; let amount: Int64 }
        let entriesByAmount = Dictionary(grouping: entries.filter { $0.summaryStart == nil }) {
            CandidateKey(day: cal.startOfDay(for: $0.date), amount: $0.cents)
        }
        var acceptedByAmount = [CandidateKey: [ImportLine]]()
        struct OriginKey: Hashable { let account: String; let value: String }
        var tokens = Set(entries.compactMap { e in e.importToken.map { OriginKey(account: e.importAccount ?? "", value: $0) } })
        var references = Set(entries.compactMap { e in e.bankReference.map { OriginKey(account: e.importAccount ?? "", value: $0) } })
        for line in rows.filter(\.selected).sorted(by: { !$0.summary && $1.summary }) {
            guard line.valid, let amount = line.cents, let day = line.date, let flow = line.flow else {
                plan.errors.append("Заполните дату, сумму, счёт и направление у выбранных строк."); continue
            }
            let reference = line.reference.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokenKey = OriginKey(account: line.account, value: line.token)
            let referenceKey = OriginKey(account: line.account, value: reference)
            let matchKey = CandidateKey(day: cal.startOfDay(for: day), amount: amount)
            // A bank often posts a card purchase a day after it was entered by hand.
            let nearbyKeys = [-1, 0, 1].compactMap { shift in
                cal.date(byAdding: .day, value: shift, to: matchKey.day).map { CandidateKey(day: cal.startOfDay(for: $0), amount: amount) }
            }
            if tokens.contains(tokenKey) || (!reference.isEmpty && references.contains(referenceKey)) {
                plan.skipped[line.id] = "Уже загружена"; continue
            }
            if let cutoff = cutoffs[line.account], day < cutoff, !line.includeBeforeCutoff {
                plan.beforeCutoff.insert(line.id)
                plan.skipped[line.id] = "До даты остатков — уже учтено в балансе"; continue
            }
            if line.summary, let range = period(line) {
                let overlaps = entries.contains { entry in
                    guard sameGroup(line, entry), let start = entry.summaryStart, let end = entry.summaryEnd else { return false }
                    return start < range.end && end > range.start
                } || accepted.contains { previous in
                    guard previous.summary, previous.account == line.account, previous.flow == flow,
                          BankRead.clean(previous.category) == BankRead.clean(line.category), let other = period(previous) else { return false }
                    return range.start < other.end && other.start < range.end
                }
                if overlaps { plan.skipped[line.id] = "Сводка за пересекающийся период уже учтена"; continue }
                let recorded = entries.filter { sameGroup(line, $0) && inside($0.date, range) }.reduce(Int64(0)) { $0 + $1.cents }
                let added = accepted.filter { !$0.summary && $0.account == line.account && $0.flow == flow && BankRead.clean($0.category) == BankRead.clean(line.category) && inside($0.date!, range) }.reduce(Int64(0)) { $0 + ($1.cents ?? 0) }
                let remainder = amount - recorded - added
                guard remainder > 0 else { plan.skipped[line.id] = "Итог уже покрыт операциями"; continue }
                plan.adjusted[line.id] = remainder
                plan.additions.append((line, remainder))
            } else {
                let savedMatch = nearbyKeys.flatMap { entriesByAmount[$0] ?? [] }.first { entry in
                    if !reference.isEmpty, let ref = entry.bankReference, !ref.isEmpty, entry.importAccount == line.account && ref != reference { return false }
                    if entry.transfer && flow == .transfer {
                        return entry.accountKey == line.account && entry.destinationKey == line.destination
                    }
                    return entry.cashDelta(for: line.account) == (flow == .income ? amount : -amount) ||
                        (flow == .transfer && entry.accountKey == line.destination && entry.income)
                }
                let batchMatch = nearbyKeys.flatMap { acceptedByAmount[$0] ?? [] }.first { previous in
                    if previous.account == line.account && !reference.isEmpty && !previous.reference.isEmpty && previous.reference != reference { return false }
                    return (previous.account == line.account && (previous.flow == .income) == (flow == .income)) ||
                        (previous.flow == .transfer && previous.destination == line.account && flow == .income) ||
                        (flow == .transfer && previous.account == line.destination && previous.flow == .income)
                }
                if savedMatch != nil || batchMatch != nil {
                    if let savedMatch {
                        plan.matchNotes[line.id] = "В журнале: " + savedMatch.category + " · " + savedMatch.note
                    } else if let batchMatch {
                        plan.matchNotes[line.id] = "В этой загрузке: " + batchMatch.category + " · " + batchMatch.note
                    }
                    plan.similar.insert(line.id)
                    if !line.confirmedSimilar { plan.skipped[line.id] = "Похожая операция · пропуск"; continue }
                }
                plan.additions.append((line, amount))
            }
            accepted.append(line)
            if !line.summary { acceptedByAmount[matchKey, default: []].append(line) }
            tokens.insert(tokenKey)
            if !reference.isEmpty { references.insert(referenceKey) }
        }
        for entry in entries {
            guard let start = entry.summaryStart, let end = entry.summaryEnd, entry.cents > 0 else { continue }
            let covered = plan.additions.filter { line, _ in
                !line.summary && sameGroup(line, entry) && line.date! >= start && line.date! < end
            }.reduce(Int64(0)) { $0 + $1.1 }
            if covered > 0 {
                let residual = max(0, entry.cents - covered)
                plan.replacements.append((entry, residual))
                plan.residualAmounts[entry.persistentModelID] = entry.cents - residual
            }
        }
        return plan
    }

    /// `cutoffs` must be the same balance dates the preview used, or rows it skipped as already counted would be saved.
    @MainActor static func save(rows: [ImportLine], documents: [BankDocument], container: ModelContainer, expected: ImportPlan? = nil,
                                cutoffs: [String: Date] = [:]) throws -> Int {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let current = try context.fetch(FetchDescriptor<Entry>())
        let plan = plan(rows, entries: current, cutoffs: cutoffs)
        if let expected, !expected.agrees(with: plan) { throw ImportIssue.message("Операции изменились. Проверьте обновлённые итоги и повторите сохранение.") }
        if let error = plan.errors.first { throw ImportIssue.message(error) }
        let originals = try context.fetch(FetchDescriptor<StatementSource>())
        let available = Set(documents.map(\.digest)).union(originals.map(\.digest))
        guard plan.additions.allSatisfy({ available.contains($0.0.source) }) else { throw ImportIssue.message("Не найден оригинал для сохранения.") }
        for document in documents where plan.additions.contains(where: { $0.0.source == document.digest }) && !originals.contains(where: { $0.digest == document.digest }) {
            context.insert(StatementSource(document))
        }
        for (row, cents) in plan.additions {
            guard let date = row.date, let flow = row.flow else { throw ImportIssue.message("Незаполненная строка") }
            let entry = Entry(cents: cents, flow: flow, category: flow == .transfer ? flow.rawValue : row.category,
                              note: row.note, date: date)
            entry.accountKey = row.account
            entry.destinationKey = flow == .transfer ? row.destination : nil
            entry.importToken = row.token
            entry.importAccount = row.account
            entry.bankReference = row.reference.isEmpty ? nil : row.reference
            entry.sourceDigest = row.source
            if row.summary, let since = row.since {
                entry.summaryStart = Calendar.current.startOfDay(for: since)
                entry.summaryEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))
            }
            context.insert(entry)
        }
        // Retain zero residuals as receipts so re-importing a fully covered summary stays idempotent.
        for (summary, cents) in plan.replacements { summary.cents = cents }
        try context.save()
        return plan.additions.count
    }
}
