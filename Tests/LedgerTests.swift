import Foundation
import SwiftData
import Testing
@testable import Balance

struct LedgerTests {
    private let snapshot = Date(timeIntervalSince1970: 1_800_000_000)
    private let empty = Archive(months: [], positions: [])

    @Test func transferAndCheckpoint() {
        let cash = Checkpoint(position: .init(title: "Счёт", amount: 10000, debt: false), key: "cash", date: snapshot)
        let card = Checkpoint(position: .init(title: "Кредитка", amount: 6000, debt: true), key: "card", date: snapshot)
        let payment = Entry(cents: 2500, flow: .transfer, category: "", note: "", date: snapshot.addingTimeInterval(1))
        payment.accountKey = cash.key
        payment.destinationKey = card.key
        #expect(payment.cashDelta(for: cash.key) == -2500)
        #expect(payment.cashDelta(for: card.key) == 2500)
        let accounts = balances(archive: empty, checkpoints: [cash, card], entries: [payment])
        #expect(accounts.first { $0.id == cash.key }?.position.amount == 7500)
        #expect(accounts.first { $0.id == card.key }?.position.amount == 3500)
        payment.date = snapshot
        #expect(balances(archive: empty, checkpoints: [cash], entries: [payment]).first?.position.amount == 10000)
    }

    @Test func priceRoundingAndInput() {
        let prices = MarketPrices.initial
        #expect(prices.valuation(of: .gold, quantity: "1,5") == 861300)
        #expect(prices.valuation(of: .silver, quantity: "2.5") == 22275)
        #expect(prices.valuation(of: .crypto, quantity: "1.25") == 10279)
        for value in ["", "-1", "1,2,3", "1e5"] {
            #expect(prices.valuation(of: .gold, quantity: value) == nil)
        }
    }

    @Test func openingQuantitiesFromReportAndBounds() {
        let lines: [Archive.Line] = [
            .init(title: "Золото 585 пробы — 2,5 г", amount: nil, note: ""),
            .init(title: "Серебро 900 пробы — 4 г", amount: nil, note: ""),
            .init(title: "Крипта — $7.75 суммарно", amount: nil, note: "")
        ]
        #expect(Holding.gold.openingQuantity(in: lines) == "2,5")
        #expect(Holding.silver.openingQuantity(in: lines) == "4")
        #expect(Holding.crypto.openingQuantity(in: lines) == "7.75")
        #expect(Holding.gold.openingQuantity(in: []) == nil)
        var prices = MarketPrices.initial
        prices.gold = 99_999_999
        #expect(prices.valuation(of: .gold, quantity: "9999999") == nil)
    }

    @Test func quoteSourcesExpireIndependently() {
        var quotes = MarketPrices.initial
        quotes.metalsChecked = snapshot
        #expect(quotes.needsRefresh(at: snapshot))
        quotes.currencyChecked = snapshot.addingTimeInterval(-3600)
        #expect(quotes.needsRefresh(at: snapshot))
        quotes.currencyChecked = snapshot
        #expect(!quotes.needsRefresh(at: snapshot))
    }

    @Test func currencyFeed() throws {
        let xml = """
        <ValCurs Date="19.11.2026"><Valute><CharCode>EUR</CharCode><Nominal>1</Nominal><Value>50</Value></Valute>
        <Valute><Value>821,5</Value><CharCode>USD</CharCode><Nominal>10</Nominal></Valute></ValCurs>
        """
        let (rate, date) = try MarketPrices.currency(xml)
        #expect(rate == Decimal(string: "82.15"))
        #expect(date == "19.11.2026")
        for bad in [xml.replacingOccurrences(of: "</ValCurs>", with: ""), xml.replacingOccurrences(of: ">10<", with: ">0<"), xml.replacingOccurrences(of: ">10<", with: ">0,1<"), xml.replacingOccurrences(of: "19.11.2026", with: "31.02.2026"), xml.replacingOccurrences(of: "USD", with: "CHF")] {
            #expect(throws: URLError.self) { try MarketPrices.currency(bad) }
        }
    }

    @Test func reportResources() throws {
        let archive = try #require(Archive.bundled)
        #expect(!archive.months.isEmpty)
        #expect(!archive.positions.isEmpty)
        let original = try OriginalBudget()
        #expect(original.data.prefix(2) == Data("PK".utf8))
    }

    @MainActor @Test func legacyMigrationCanResume() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let db = try ModelContainer(for: Checkpoint.self, configurations: config)
        let revision = Revision(date: snapshot, positions: [
            .init(title: "Кошелёк", amount: 123, debt: false),
            .init(title: "Кредит", amount: 234, debt: true)
        ])
        db.mainContext.insert(Checkpoint(position: revision.positions[0], key: "excel-20260901-0", date: snapshot))
        try db.mainContext.save()
        try revision.migrate(into: db.mainContext)
        try revision.migrate(into: db.mainContext)
        #expect(try db.mainContext.fetchCount(FetchDescriptor<Checkpoint>()) == 2)
    }

    @MainActor @Test func persistedChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let configuration = ModelConfiguration(url: folder.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        func openStore() throws -> ModelContainer {
            try ModelContainer(for: Entry.self, Checkpoint.self, configurations: configuration)
        }
        do {
            let db = try openStore()
            let entry = Entry(cents: 500, flow: .income, category: "Доход", note: "", date: snapshot.addingTimeInterval(10))
            entry.accountKey = "cash"
            db.mainContext.insert(entry)
            db.mainContext.insert(Checkpoint(position: .init(title: "Счёт", amount: 1000, debt: false), key: "cash", date: snapshot))
            try db.mainContext.save()
        }
        do {
            let db = try openStore()
            let entries = try db.mainContext.fetch(FetchDescriptor<Entry>())
            let checkpoints = try db.mainContext.fetch(FetchDescriptor<Checkpoint>())
            #expect(balances(archive: empty, checkpoints: checkpoints, entries: entries).first?.position.amount == 1500)
            let entry = try #require(entries.first)
            entry.cents = 700
            try db.mainContext.save()
            #expect(balances(archive: empty, checkpoints: checkpoints, entries: entries).first?.position.amount == 1700)
            db.mainContext.delete(entry)
            try db.mainContext.save()
        }
        let reopened = try openStore()
        #expect(try reopened.mainContext.fetchCount(FetchDescriptor<Entry>()) == 0)
        #expect(try reopened.mainContext.fetchCount(FetchDescriptor<Checkpoint>()) == 1)
    }
}
