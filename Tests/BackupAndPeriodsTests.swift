import XCTest
import PDFKit
import SwiftData
@testable import Balance

final class BackupAndPeriodsTests: XCTestCase {
    @MainActor func testPortableArchiveAndReplacement() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let db = try ModelContainer(for: Entry.self, Checkpoint.self, StatementSource.self, IncomePlan.self, FinanceRecord.self, BackupInstall.self, configurations: config)
        let ctx = db.mainContext
        let doc = BankDocument(name: "test.csv", bytes: Data("demo".utf8))
        ctx.insert(StatementSource(doc))
        let e = Entry(cents: 12345, flow: .expense, category: "Тест", note: "fixture", date: .now)
        e.sourceDigest = doc.digest; e.importToken = "transaction-1"; ctx.insert(e)
        let mark = Checkpoint(position: .init(title: "Счёт", amount: 100, debt: false), key: "cash", date: .now)
        ctx.insert(mark)
        let income = IncomePlan(); income.type = IncomeKind.salary.rawValue; income.amount = 1200
        ctx.insert(income)
        let close = Closing(end: .now, saved: .now, positions: [:], titles: [:], capital: 100, values: nil)
        ctx.insert(try FinanceRecord("close",close))
        var snapshot = try LedgerCopy(ctx)
        snapshot.history = Data(#"{"months":[],"positions":[]}"#.utf8)
        snapshot.workbook = Data([0x50,0x4b,3,4])
        let key = "example for synthetic test"
        let cipher = try BackupCipher.seal(snapshot, password: key)
        XCTAssertThrowsError(try BackupCipher.open(cipher, password: "wrong secret phrase"))
        var damaged = cipher; damaged[damaged.count-1] ^= 1
        XCTAssertThrowsError(try BackupCipher.open(damaged, password: key))
        let opened = try BackupCipher.open(cipher, password: key)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let settings = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: dir); settings.removePersistentDomain(forName:suite) }
        ctx.insert(Entry(cents: 999, flow: .income, category: "Extra", note: "", date: .now))
        try ctx.save()
        try opened.restore(ctx, defaults: settings, archiveRoot: dir)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Entry>()).map(\.cents), [12345])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<StatementSource>()).first?.bytes, doc.bytes)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<FinanceRecord>()), 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<IncomePlan>()), 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Checkpoint>()), 1)
        let generation = try XCTUnwrap(settings.string(forKey:"backup.seed"))
        XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent(generation).appendingPathComponent("history.json")),snapshot.history)
    }
    func testPartialCostAndExports() throws {
        let one = try LotMovement.released(units: 1, left: 3, basis: 100)
        let two = try LotMovement.released(units: 2, left: 2, basis: 100-one)
        XCTAssertEqual(one,33); XCTAssertEqual(one+two,100)
        XCTAssertThrowsError(try LotMovement.released(units: 3, left: 2, basis: 100))
        let value = PeriodValues(opening:10000,closing:11000,income:1000,expenses:0,realized:0,quotes:0)
        let table = ReportTable(title:"2026 год",previous:"2025 год",currentValues:value,previousValues:value,partial:true)
        let pdf = try XCTUnwrap(PDFDocument(data:ReportExport.pdf(table)))
        XCTAssertTrue(pdf.string?.contains("Капитал на начало") == true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("report.xlsx")
        try ReportExport.xlsx(table).write(to:url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/unzip")
        process.arguments = ["-tqq",url.path]; try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0)
    }
}
