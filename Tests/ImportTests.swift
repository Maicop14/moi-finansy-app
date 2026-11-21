import Foundation
import SwiftData
import Testing
import AppKit
import PDFKit
@testable import Balance

struct ImportTests {
    let october = BankRead.date("04.10.2026")!
    func line(_ ordinal: Int, amount: String, flow: Flow = .expense, source: String = "statement") -> ImportLine {
        ImportLine(source: source, ordinal: ordinal, original: "Тест", date: october, amount: amount,
                   flow: flow, category: "Продукты", note: "Покупка", account: "test")
    }

    @Test func exactAmounts() {
        for (raw, expected) in [("1 234,56 ₽",123456),("−1\u{202f}234,01",123401),("+0.01",1),("1 000 RUB",100000),("12,1",1210)] {
            #expect(BankRead.cents(raw) == Int64(expected))
        }
        for raw in ["", "1 23,45", "1.005", "11.00 USD", "1e4", "17,22,33", "9 99", "−-10"] {
            #expect(BankRead.cents(raw) == nil)
        }
        #expect(BankRead.date("31.02.2026") == nil)
    }

    @Test func csvAndExcel() throws {
        let text = "Дата;Описание;Сумма операции;Валюта операции;Статус\r\n04.10.2026;\"Кафе; обед\";-1 099,90;RUB;OK\r\n04.10.2026;Зарплата;+23 456,78;RUB;OK\r\n04.10.2026;Отмена;-500;RUB;Ошибка\r\n04.10.2026;Доллары;-35;USD;OK"
        let csv = BankRead.lines(text, source: "csv")
        #expect(csv.count == 4)
        #expect(csv[0].note == "Кафе; обед")
        #expect(csv[0].cents == 109990 && csv[0].flow == .expense && csv[0].category == "Кафе")
        #expect(csv[1].cents == 2345678 && csv[1].flow == .income)
        #expect(!csv[2].selected && !csv[3].selected)
        let url = try #require(Bundle.module.url(forResource: "Examples", withExtension: "xlsx", subdirectory: "Fixtures"))
        let xlsx = try BankFiles.extract(BankDocument(name: "тест.xlsx", bytes: Data(contentsOf: url)))
        #expect(xlsx.count == 2 && xlsx[0].ordinal != xlsx[1].ordinal)
        #expect(xlsx[0].date == october && xlsx[1].date == october)
        #expect(xlsx[0].cents == csv[1].cents && xlsx[0].flow == .income)
        #expect(!xlsx[0].selected && xlsx[0].original.contains("ROUND(23000+456.78,2)"))
        #expect(xlsx[1].cents == csv[0].cents && xlsx[1].flow == .expense)
    }

    @Test func incompleteDatesAndSummaryJSON() throws {
        let ocr = BankRead.lines("4 октября\nКафе -1 099,90 ₽", source: "image")
        #expect(ocr.count == 1 && ocr[0].date == nil && ocr[0].partialDay == 4 && ocr[0].partialMonth == 10)
        let json = """
        {"rows":[{"date":"2026-10-31","periodStart":"2026-10-01","amount":"1500.00","direction":"expense","category":"Продукты","currency":"RUB"}]}
        """
        let result = try BankJSON.read(json, source: "image")
        #expect(result[0].summary && result[0].since == BankRead.date("01.10.2026"))
        #expect(result[0].cents == 150000 && !result[0].selected)
    }

    @Test func ambiguousOCRNeedsManualAmount() {
        let lines = BankRead.lines("04.10.2026\nПокупка -1.099,90 ₽\nПокупка -500 ₽ остаток 12 000 ₽", source: "scan")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { !$0.selected && $0.cents == nil })
    }

    @Test func matchingAndTransfers() {
        let a = line(1, amount: "123,45")
        var b = line(2, amount: "123,45")
        let candidate = ImportLedger.plan([a,b], entries: [])
        #expect(candidate.additions.count == 1 && candidate.similar.contains(b.id))
        b.confirmedSimilar = true
        #expect(ImportLedger.plan([a,b], entries: []).additions.count == 2)
        #expect(ImportLedger.plan([a,a], entries: []).additions.count == 1)
        let existing = Entry(cents: 12345, flow: .transfer, category: "Перевод", note: "", date: october)
        existing.accountKey = "cash"; existing.destinationKey = "test"
        #expect(ImportLedger.plan([line(3, amount: "123,45", flow: .income)], entries: [existing]).additions.isEmpty)
        var other = a; other.account = "second"
        #expect(ImportLedger.plan([a,other], entries: []).additions.count == 2)
    }

    @MainActor @Test func monthlyTotalsAndReplay() throws {
        let db = try ModelContainer(for: Entry.self, Checkpoint.self, StatementSource.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = db.mainContext
        let doc = BankDocument(name: "Октябрь.txt", bytes: Data("исходник".utf8))
        let cash = Checkpoint(position: .init(title: "Счёт", amount: 1000000, debt: false), key: "test", date: BankRead.date("01.10.2026")!)
        context.insert(cash); try context.save()
        let income = line(0, amount: "23456.78", flow: .income, source: doc.digest)
        let expense = line(1, amount: "1099.90", source: doc.digest)
        var summary = line(2, amount: "1500,00", source: doc.digest)
        summary.summary = true; summary.since = BankRead.date("01.10.2026"); summary.date = BankRead.date("31.10.2026")
        let lines = [income, expense, summary]
        let opening = AccountBalance(id: "test", position: .init(title: "Счёт", amount: 1000000, debt: false), cutoff: cash.date)
        let preview = ImportLedger.plan(lines, entries: [])
        #expect(preview.balanceChanges(accounts: [opening])["test"] == 2195678)
        #expect(try ImportLedger.save(rows: lines, documents: [doc], container: db) == 3)
        #expect(try ImportLedger.save(rows: lines, documents: [doc], container: db) == 0)
        func all() throws -> [Entry] { try ModelContext(db).fetch(FetchDescriptor<Entry>()) }
        let first = try all()
        #expect(first.first { $0.summaryStart != nil }?.cents == 40010)
        let secondPurchase = line(3, amount: "100,10", source: doc.digest)
        #expect(try ImportLedger.save(rows: [secondPurchase], documents: [doc], container: db) == 1)
        let second = try all()
        #expect(second.first { $0.summaryStart != nil }?.cents == 30000)
        let last = line(4, amount: "400", source: doc.digest)
        let previewDetail = ImportLedger.plan([last], entries: second)
        #expect(previewDetail.balanceChanges(accounts: [opening])["test"] == -10000)
        _ = try ImportLedger.save(rows: [last], documents: [doc], container: db)
        let final = try all()
        #expect(final.first { $0.summaryStart != nil }?.cents == 0)
        // Actual expenses = 1,099.90 + 100.10 + 400.00 = 1,600.00, including all details exactly once.
        let result = balances(archive: Archive(months: [], positions: []), checkpoints: [cash], entries: final)
        #expect(result.first?.position.amount == 3185678)
        #expect(try ModelContext(db).fetch(FetchDescriptor<StatementSource>()).map(\.bytes) == [doc.bytes])
    }

    @MainActor @Test func localImageAndPDF() throws {
        let image = NSImage(size: NSSize(width: 1100, height: 220))
        image.lockFocus()
        NSColor.white.setFill(); NSBezierPath(rect: CGRect(origin: .zero, size: image.size)).fill()
        let attrs: [NSAttributedString.Key:Any] = [.font: NSFont.systemFont(ofSize: 38), .foregroundColor: NSColor.black]
        ("04.10.2026" as NSString).draw(at: CGPoint(x: 30, y: 135), withAttributes: attrs)
        ("Cafe   -1 099,90 ₽" as NSString).draw(at: CGPoint(x: 30, y: 55), withAttributes: attrs)
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let recognized = try BankFiles.extract(BankDocument(name: "банк.png", bytes: png))
        #expect(recognized.contains { $0.cents == 109990 && $0.date == october })
        #expect(recognized.allSatisfy { !$0.selected })
        let pdf = PDFDocument(); pdf.insert(try #require(PDFPage(image: image)), at: 0)
        let scanned = try BankFiles.extract(BankDocument(name: "банк.pdf", bytes: try #require(pdf.dataRepresentation())))
        #expect(scanned.contains { $0.cents == 109990 && $0.date == october })
    }
}
