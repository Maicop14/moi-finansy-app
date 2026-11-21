import Foundation
import Testing
@testable import Balance

struct ImportSafetyTests {
    @Test func onlyLocalRegularFilesAreAccepted() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("Тест.txt")
        let bytes = Data("Образец".utf8)
        try bytes.write(to: file)
        #expect(try BankFiles.document(at: file).bytes == bytes)
        #expect(try BankFileInput.bytes(at: file, limit: bytes.count) == bytes)
        #expect(throws: (any Error).self) { try BankFileInput.bytes(at: file, limit: bytes.count - 1) }
        #expect(throws: (any Error).self) { try BankFiles.document(at: root) }
        let alias = root.appendingPathComponent("Ссылка")
        try fm.createSymbolicLink(at: alias, withDestinationURL: file)
        #expect(throws: (any Error).self) { try BankFiles.document(at: alias) }
    }

    @Test func jsonAlwaysRequiresSelectionAndBoundsInput() throws {
        let json = #"{"rows":[{"date":"2026-01-01","amount":"12.34","direction":"income","currency":"RUB"}]}"#
        let row = try #require(try BankJSON.read(json, source: "test").first)
        #expect(row.reviewRequired && !row.selected && row.cents == 1234)
        let long = String(repeating: " ", count: BankFiles.textLimit + 1)
        #expect(throws: (any Error).self) { try BankJSON.read(long, source: "test") }
    }

    @Test func paymentCurrencyAndMalformedDebitRequireReview() {
        let fx = "Дата;Сумма платежа;Валюта операции;Валюта платежа\n04.10.2026;-100;USD;\n04.10.2026;-8500;USD;RUB"
        let rows = BankRead.lines(fx, source: "test")
        #expect(rows.count == 2)
        #expect(rows[0].cents == nil && !rows[0].selected)
        #expect(rows[1].cents == 850000 && rows[1].selected)
        let debit = BankRead.lines("Дата;Сумма;Дебет\n04.10.2026;-100;неизвестно", source: "test")
        #expect(debit.first?.selected == false)
    }

    @Test func previewsAreIndependentAndRemovedOnClose() throws {
        let document = BankDocument(name: "Оригинал.txt", bytes: Data("Тест".utf8))
        let first = try ImportPreview.url(document), second = try ImportPreview.url(document)
        defer { ImportPreview.remove(first); ImportPreview.remove(second) }
        #expect(first != second)
        #expect(try Data(contentsOf: first) == document.bytes)
        ImportPreview.remove(first)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
}
