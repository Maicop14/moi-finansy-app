import XCTest
import SwiftData
@testable import Balance

/// A store written before operations had a subcategory must open with every operation intact.
final class EntryMigrationTests: XCTestCase {
    @MainActor func testStoreWithoutSubcategoryStillOpens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfiguration(url: directory.appendingPathComponent("ledger.store"), cloudKitDatabase: .none)
        do {
            let prior = try ModelContainer(for: PriorEntrySchema.Entry.self, configurations: config)
            let entry = PriorEntrySchema.Entry()
            entry.cents = 57_000; entry.kind = Flow.expense.rawValue; entry.category = "Кафе"; entry.note = "Факультет кофе"
            entry.accountKey = "excel-20260901-15"; entry.charityMonth = 202610
            prior.mainContext.insert(entry)
            try prior.mainContext.save()
        }
        let next = try ModelContainer(for: Entry.self, configurations: config)
        let migrated = try XCTUnwrap(try next.mainContext.fetch(FetchDescriptor<Entry>()).first)
        XCTAssertEqual(migrated.cents, 57_000)
        XCTAssertEqual(migrated.accountKey, "excel-20260901-15")
        XCTAssertEqual(migrated.charityMonth, 202610)
        XCTAssertNil(migrated.subcategory)
        XCTAssertEqual(Subcategories.resolve(migrated), "Кофейни")
        migrated.subcategory = "Кофе с собой"
        try next.mainContext.save()
        // Backups written before the field existed still decode.
        let old = try JSONEncoder().encode(EntryCopy(migrated))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        json.removeValue(forKey: "subcategory")
        let decoded = try JSONDecoder().decode(EntryCopy.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.model().subcategory)
        XCTAssertEqual(try JSONDecoder().decode(EntryCopy.self, from: old).model().subcategory, "Кофе с собой")
    }
}

private enum PriorEntrySchema {
    @Model final class Entry {
        var cents: Int64 = 0
        var kind: String = ""
        var category: String = ""
        var note: String = ""
        var date: Date = Date()
        var accountKey: String?
        var destinationKey: String?
        var importAccount: String?
        var importToken: String?
        var bankReference: String?
        var sourceDigest: String?
        var lotEventID: UUID?
        var charityMonth: Int?
        var charityIncluded: Bool?
        var summaryStart: Date?
        var summaryEnd: Date?
        init() {}
    }
}
