import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CryptoKit
import CommonCrypto

// A restore commits its archive generation and settings together with the ledger.
@Model final class BackupInstall {
    var id = UUID()
    var settings = Data()
    init(id: UUID, settings: Data) { self.id = id; self.settings = settings }
}

struct EntryCopy: Codable {
    var cents: Int64
    var kind: String
    var category: String
    var note: String
    var date: Date
    var accountKey: String?
    var destinationKey: String?
    var importAccount: String?
    var importToken: String?
    var bankReference: String?
    var lotEventID: UUID?
    var sourceDigest: String?
    var charityMonth: Int?
    var charityIncluded: Bool?
    var summaryStart: Date?
    var summaryEnd: Date?
    var subcategory: String?
    init(_ value: Entry) {
        cents = value.cents
        kind = value.kind
        category = value.category
        note = value.note
        date = value.date
        accountKey = value.accountKey
        destinationKey = value.destinationKey
        importAccount = value.importAccount
        importToken = value.importToken
        bankReference = value.bankReference
        lotEventID = value.lotEventID
        sourceDigest = value.sourceDigest
        charityMonth = value.charityMonth
        charityIncluded = value.charityIncluded
        summaryStart = value.summaryStart
        summaryEnd = value.summaryEnd
        subcategory = value.subcategory
    }
    func model() -> Entry {
        let value = Entry(cents: cents, flow: Flow(rawValue: kind)!, category: category, note: note, date: date)
        value.accountKey = accountKey
        value.destinationKey = destinationKey
        value.importAccount = importAccount
        value.importToken = importToken
        value.bankReference = bankReference
        value.lotEventID = lotEventID
        value.sourceDigest = sourceDigest
        value.charityMonth = charityMonth
        value.charityIncluded = charityIncluded
        value.summaryStart = summaryStart
        value.summaryEnd = summaryEnd
        value.subcategory = subcategory
        return value
    }
}

struct CheckpointCopy: Codable {
    var key: String
    var title: String
    var amount: Int64
    var debt: Bool
    var date: Date
    var valuationSource: Data?
    var marketDelta: Int64?
    var tieBreaker: String
    init(_ value: Checkpoint) {
        key = value.key
        title = value.title
        amount = value.amount
        debt = value.debt
        date = value.date
        valuationSource = value.valuationSource
        marketDelta = value.marketDelta
        tieBreaker = value.tieBreaker
    }
    func model() -> Checkpoint {
        let value = Checkpoint(position: .init(title: title, amount: amount, debt: debt), key: key, date: date)
        value.valuationSource = valuationSource
        value.marketDelta = marketDelta
        value.tieBreaker = tieBreaker
        return value
    }
}

struct IncomePlanCopy: Codable {
    var title: String
    var type: String
    var amount: Int64
    var rateBP: Int
    var start: Date
    var payout: Date
    var monthly: Bool
    var exempt: Bool
    var bankExemptionReason: String?
    var passive: Bool
    init(_ value: IncomePlan) {
        title = value.title
        type = value.type
        amount = value.amount
        rateBP = value.rateBP
        start = value.start
        payout = value.payout
        monthly = value.monthly
        exempt = value.exempt
        bankExemptionReason = value.bankExemptionReason
        passive = value.passive
    }
    func model() -> IncomePlan {
        let value = IncomePlan()
        value.title = title
        value.type = type
        value.amount = amount
        value.rateBP = rateBP
        value.start = start
        value.payout = payout
        value.monthly = monthly
        value.exempt = exempt
        value.bankExemptionReason = bankExemptionReason
        value.passive = passive
        return value
    }
}

enum BackupError: LocalizedError {
    case invalid, secret, large, incomplete
    var errorDescription: String? {
        switch self {
        case .invalid: "Не удалось проверить копию. Проверьте файл и пароль."
        case .secret: "Введите пароль копии длиной от 12 символов."
        case .large: "Архив превышает поддерживаемый размер 128 МБ."
        case .incomplete: "Данные неполны или формат копии не поддерживается."
        }
    }
}

struct CopySettings: Codable {
    var strings: [String: String]
    var data: [String: Data]
    static let stringsAllowed = Set(Holding.allCases.map { "quantity." + $0.id } + (2025...2099).map { "income.rate." + String($0) } + [FreshStartMark.key, ProfileName.key])
    // "portfolio.reconciliation" is a one-time migration source and is no longer copied:
    // restoring it could replay an old reconciliation on another device.
    static let dataAllowed = ["markets.prices", "accounts.hidden"]
    /// Added later: restored only when the copy has them, so an older copy never erases them.
    static let dataExtra = [LiveCapital.foreignKey, NetWorthHistory.storageKey, PaymentDue.storageKey, RecurringDue.storageKey,
                            Subcategories.storageKey, "breakdown.pins", QuoteFallback.calibrationKey]
    init(_ defaults: UserDefaults) {
        strings = Self.stringsAllowed.reduce(into: [:]) { $0[$1] = defaults.string(forKey: $1) }
        data = (Self.dataAllowed + Self.dataExtra).reduce(into: [:]) { $0[$1] = defaults.data(forKey: $1) }
    }
    func apply(_ defaults: UserDefaults) {
        for k in Self.stringsAllowed { defaults.set(strings[k], forKey: k) }
        for k in Self.dataAllowed { defaults.set(data[k], forKey: k) }
        for k in Self.dataExtra { if let value = data[k] { defaults.set(value, forKey: k) } }
    }
}
struct SourceCopy: Codable { let name: String; let digest: String; let bytes: Data }

struct LedgerCopy: Codable {
    var version = 1
    let date: Date
    let entries: [EntryCopy]
    let accounts: [CheckpointCopy]
    let plans: [IncomePlanCopy]
    let sources: [SourceCopy]
    var history: Data
    var workbook: Data
    let records: [RecordCopy]
    let settings: CopySettings

    @MainActor init(_ context: ModelContext) throws {
        try context.save()
        date = .now
        entries = try context.fetch(FetchDescriptor<Entry>()).map(EntryCopy.init)
        accounts = try context.fetch(FetchDescriptor<Checkpoint>()).map(CheckpointCopy.init)
        plans = try context.fetch(FetchDescriptor<IncomePlan>()).map(IncomePlanCopy.init)
        var total = 0
        sources = try context.fetch(FetchDescriptor<StatementSource>()).map { item in
            total += item.bytes.count
            guard total < BackupCipher.limit else { throw BackupError.large }
            return SourceCopy(name: item.name, digest: item.digest, bytes: item.bytes)
        }
        guard let h = Archive.reportURL("history", "json"), let w = Archive.reportURL("OriginalBudget", "xlsx") else { throw BackupError.incomplete }
        history = try Data(contentsOf: h)
        workbook = try Data(contentsOf: w)
        records = try context.fetch(FetchDescriptor<FinanceRecord>()).map { RecordCopy(id: $0.id, kind: $0.kind, payload: $0.payload) }
        settings = CopySettings(.standard)
        try validate()
    }
    func validate() throws {
        for record in records { try record.validate() }
        let digests = Set(sources.map(\.digest))
        guard version == 1, workbook.starts(with: [0x50,0x4b]), digests.count == sources.count,
              sources.allSatisfy({ BankDocument(name: $0.name, bytes: $0.bytes).digest == $0.digest }),
              entries.allSatisfy({ entry in Flow(rawValue: entry.kind) != nil && entry.cents >= 0 && (entry.sourceDigest.map(digests.contains) ?? true) }),
              plans.allSatisfy({ IncomeKind(rawValue: $0.type) != nil }),
              (try? JSONDecoder().decode(Archive.self, from: history)) != nil else { throw BackupError.incomplete }
    }

    @MainActor func restore(_ context: ModelContext, defaults: UserDefaults = .standard, archiveRoot: URL? = nil) throws {
        try validate()
        let generation = UUID()
        let folder = archiveRoot?.appendingPathComponent(generation.uuidString) ?? Archive.seedDirectory(generation)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try history.write(to: folder.appendingPathComponent("history.json"), options: .atomic)
            try workbook.write(to: folder.appendingPathComponent("OriginalBudget.xlsx"), options: .atomic)
            // Individual deletes participate in the same save as their replacements.
            for value in try context.fetch(FetchDescriptor<Entry>()) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<Checkpoint>()) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<IncomePlan>()) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<StatementSource>()) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<BackupInstall>()) { context.delete(value) }
            for row in try context.fetch(FetchDescriptor<FinanceRecord>()) { context.delete(row) }
            for row in records { context.insert(FinanceRecord(row)) }
            for row in entries { context.insert(row.model()) }
            for row in accounts { context.insert(row.model()) }
            for row in plans { context.insert(row.model()) }
            for row in sources { context.insert(StatementSource(BankDocument(name: row.name, bytes: row.bytes))) }
            let marker = BackupInstall(id: generation, settings: try JSONEncoder().encode(settings))
            context.insert(marker)
            try context.save()
            Self.activate(marker, settings, defaults: defaults)
        } catch {
            context.rollback()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
    @MainActor static func resume(_ context: ModelContext) throws {
        if let marker = try context.fetch(FetchDescriptor<BackupInstall>()).first,
           UserDefaults.standard.string(forKey: "backup.seed") != marker.id.uuidString {
            activate(marker, try JSONDecoder().decode(CopySettings.self, from: marker.settings))
        }
    }
    @MainActor private static func activate(_ marker: BackupInstall, _ settings: CopySettings, defaults: UserDefaults = .standard) {
        settings.apply(defaults)
        defaults.set(marker.id.uuidString, forKey: "backup.seed")
    }
}

enum BackupCipher {
    static let limit = 128 * 1024 * 1024
    private static let header = Data("KDFIN001".utf8)
    private static func key(_ password: String, _ salt: Data) throws -> SymmetricKey {
        guard password.count >= 12 else { throw BackupError.secret }
        let secret = Array(password.utf8)
        var result = [UInt8](repeating: 0, count: 32)
        let code = secret.withUnsafeBytes { p in salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.bindMemory(to: Int8.self).baseAddress, secret.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                 600_000, &result, 32)
        } }
        guard code == kCCSuccess else { throw BackupError.invalid }
        return SymmetricKey(data: result)
    }
    static func seal(_ copy: LedgerCopy, password: String) throws -> Data {
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = try encoder.encode(copy)
        guard payload.count + 52 <= limit else { throw BackupError.large }
        let prefix = header + salt
        guard let sealed = try AES.GCM.seal(payload, using: key(password, salt), authenticating: prefix).combined else { throw BackupError.invalid }
        return prefix + sealed
    }
    static func open(_ data: Data, password: String) throws -> LedgerCopy {
        guard data.count <= limit else { throw BackupError.large }
        guard data.count >= 52, data.starts(with: header) else { throw BackupError.invalid }
        let prefix = data.prefix(24)
        let secret = try key(password, Data(prefix.suffix(16)))
        guard let box = try? AES.GCM.SealedBox(combined: data.dropFirst(24)),
              let payload = try? AES.GCM.open(box, using: secret, authenticating: prefix) else { throw BackupError.invalid }
        let copy = try PropertyListDecoder().decode(LedgerCopy.self, from: payload)
        try copy.validate()
        return copy
    }
}

struct RestoredLedger: View {
    @Environment(\.modelContext) private var context
    @Binding var pendingURL: URL?
    @AppStorage("backup.seed") private var generation = ""
    @State private var ready = false
    @State private var welcome = WelcomeScene.now
    @State private var failed = false
    /// The main screen; on iPhone it also writes the automatic copy once an hour while open.
    @ViewBuilder private var ledger: some View {
        #if os(iOS)
        Ledger(pendingURL: $pendingURL).id(generation)
            .task(id: generation) {
                while !Task.isCancelled {
                    if !DemoMode.isOn { await PhoneCloudBackup.run(context) }
                    do { try await Task.sleep(for: .seconds(3600)) } catch { return }
                }
            }
        #else
        Ledger(pendingURL: $pendingURL).id(generation)
        #endif
    }
    var body: some View {
        Group {
            if ready { ledger }
            else if failed { Text("Не удалось загрузить настройки восстановленной базы.") }
            else { WelcomeScreen(scene: welcome) }
        }.task {
            guard !ready else { return }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .milliseconds(2200))
            do {
                if DemoMode.isOn { try DemoMode.seed(context) } else {
                    try LedgerCopy.resume(context)
                    try ResetSeed.applyIfNeeded(context)
                    try NovemberSeed.applyIfNeeded(context)
                }
                try await clock.sleep(until: deadline)
                try Task.checkCancellation()
                ready = true
            } catch is CancellationError { return }
            catch { failed = true }
        }
    }
}

struct BackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .json] }
    var bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw BackupError.invalid }
        bytes = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}

struct BackupPanel: View {
    /// Kept out of the view body: one long string concatenation is too slow for some compiler versions to type-check.
    static func summary(_ copy: LedgerCopy) -> String {
        let date = copy.date.formatted()
        return "Копия от \(date). Операций: \(copy.entries.count), выписок: \(copy.sources.count), сверок: \(copy.accounts.count)"
    }
    @Environment(\.modelContext) private var context
    @State private var quickRestore = false
    @State private var password = ""
    @State private var repeatPassword = ""
    @State private var document: BackupFile?
    @State private var exporting = false
    @State private var readable = false
    @State private var importing = false
    @State private var preview: LedgerCopy?
    @State private var confirming = false
    @State private var message = ""
    @State private var busy = false
    private var safetyCopy: URL { URL.applicationSupportDirectory.appendingPathComponent("BeforeRestore.kdfin") }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Резервная копия").font(.headline)
            Button("Восстановить из файла копии…") { quickRestore = true }.buttonStyle(.bordered)
            Text("Сохраните зашифрованный файл в iCloud Drive через «Файлы». Для восстановления на другом устройстве понадобится этот файл и отдельный пароль.").font(.callout)
            SecureField("Пароль копии · минимум 12 символов", text: $password)
            SecureField("Повторите пароль для создания копии", text: $repeatPassword)
            Button("Создать копию в Файлах…") {
                do {
                    let copy = try LedgerCopy(context)
                    busy = true
                    let key = password
                    Task {
                        defer { busy = false }
                        do {
                            let bytes = try await Task.detached { try BackupCipher.seal(copy, password: key) }.value
                            readable = false; document = BackupFile(bytes); exporting = true
                        } catch { message = error.localizedDescription }
                    }
                } catch { message = error.localizedDescription }
            }.disabled(password.count < 12 || password != repeatPassword || busy)
            Button("Открыть копию для проверки…") { importing = true }.disabled(password.count < 12 || busy)
            #if os(iOS)
            PhoneCloudFolder(password: password, confirmation: repeatPassword)
            #endif
            if busy { ProgressView() }
            if let copy = preview {
                Text(Self.summary(copy))
                Button("Восстановить эту копию…") { confirming = true }.disabled(busy)
            }
            Button("Экспорт журнала и партий · JSON без пароля…") {
                do {
                    struct ReadableJournal: Encodable {
                        let date: Date
                        let accounts: [String: String]
                        let operations: [EntryCopy]
                        let lots: [LotMovement]
                    }
                    guard let archive = Archive.bundled else { throw BackupError.incomplete }
                    let entries = try context.fetch(FetchDescriptor<Entry>())
                    let accounts = balances(archive: archive, checkpoints: try context.fetch(FetchDescriptor<Checkpoint>()), entries: entries)
                    let journal = ReadableJournal(date: .now, accounts: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.position.title) }),
                                                  operations: entries.map(EntryCopy.init), lots: try LotMovement.decode(context.fetch(FetchDescriptor<FinanceRecord>())))
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    document = BackupFile(try encoder.encode(journal)); readable = true; exporting = true
                } catch { message = error.localizedDescription }
            }
            if FileManager.default.fileExists(atPath: safetyCopy.path) {
                Button("Экспортировать копию перед последним восстановлением…") {
                    do { readable = false; document = BackupFile(try Data(contentsOf: safetyCopy)); exporting = true }
                    catch { message = error.localizedDescription }
                }
            }
            if !message.isEmpty { Text(message).font(.callout) }
        }.textFieldStyle(.roundedBorder)
        .sheet(isPresented: $quickRestore) { QuickRestoreSheet() }
        .onChange(of: password) { _, _ in preview = nil }
        .fileExporter(isPresented: $exporting, document: document, contentType: readable ? .json : .data, defaultFilename: "Мои Финансы " + Date.now.formatted(.iso8601.year().month().day()) + (readable ? ".json" : ".kdfin")) { result in
            document = nil
            switch result {
            case .success:
                if !readable { BackupLog.record() }
                message = "Файл сохранён в выбранной папке."; password = ""; repeatPassword = ""
            case .failure(let error): message = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            preview = nil
            do {
                let url = try result.get()
                let key = password
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        preview = try await Task.detached {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            var coordinationError: NSError?
                            var read: Result<Data, Error>?
                            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { file in
                                read = Result {
                                    let handle = try FileHandle(forReadingFrom: file)
                                    defer { try? handle.close() }
                                    guard try handle.seekToEnd() <= UInt64(BackupCipher.limit) else { throw BackupError.large }
                                    try handle.seek(toOffset: 0)
                                    return try handle.read(upToCount: BackupCipher.limit + 1) ?? Data()
                                }
                            }
                            if let coordinationError { throw coordinationError }
                            guard let read else { throw BackupError.invalid }
                            return try BackupCipher.open(read.get(), password: key)
                        }.value
                        message = "Пароль и целостность проверены."
                    } catch { message = error.localizedDescription }
                }
            } catch { message = error.localizedDescription }
        }
        .alert("Заменить данные на этом устройстве?", isPresented: $confirming) {
            Button("Отмена", role: .cancel) {}
            Button("Восстановить", role: .destructive) {
                if let preview {
                    do {
                        let previous = try LedgerCopy(context)
                        let key = password, target = safetyCopy
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                // Key derivation and encryption of up to 128 MB stay off the main thread.
                                try await Task.detached { try BackupCipher.seal(previous, password: key).write(to: target, options: .atomic) }.value
                                try preview.restore(context)
                                message = "Копия восстановлена."
                            } catch { message = error.localizedDescription }
                        }
                    }
                    catch { message = error.localizedDescription }
                }
            }
        } message: { Text("Операции и вложения будут заменены содержимым проверенной копии. Предварительно сохраните текущую базу отдельным файлом.") }
    }
}

#if os(iOS)
import Security

@MainActor enum PhoneCloudBackup {
    static let folderKey = "phoneBackup.folder"
    static let lastKey = "phoneBackup.last"
    static let statusKey = "phoneBackup.status"
    private static var running = false
    private static var keyQuery: [String: Any] {
        [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:(Bundle.main.bundleIdentifier ?? "") + ".automatic-backup", kSecAttrAccount as String:"recovery-passphrase"]
    }
    static func configure(folder: URL, password: String) throws {
        guard password.count >= 12 else { throw BackupError.secret }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let bytes = Data(password.utf8)
        var item = keyQuery
        item[kSecValueData as String] = bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let inserted = SecItemAdd(item as CFDictionary, nil)
        if inserted == errSecDuplicateItem {
            guard SecItemUpdate(keyQuery as CFDictionary, [kSecValueData as String:bytes] as CFDictionary) == errSecSuccess else { throw BackupError.invalid }
        } else if inserted != errSecSuccess { throw BackupError.invalid }
        UserDefaults.standard.set(bookmark, forKey: folderKey)
        UserDefaults.standard.removeObject(forKey: lastKey)
    }
    static func disable() {
        UserDefaults.standard.removeObject(forKey: folderKey)
        SecItemDelete(keyQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: statusKey)
    }
    static func run(_ context: ModelContext, force: Bool = false) async {
        let defaults = UserDefaults.standard
        guard !running, let bookmark = defaults.data(forKey: folderKey) else { return }
        if !force, let last = defaults.object(forKey: lastKey) as? Date, Calendar.current.isDateInToday(last) { return }
        running = true
        defer { running = false }
        do {
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            if stale { defaults.set(try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: folderKey) }
            var query = keyQuery, output: CFTypeRef?
            query[kSecReturnData as String] = true
            guard SecItemCopyMatching(query as CFDictionary, &output) == errSecSuccess, let bytes = output as? Data,
                  let password = String(data: bytes, encoding: .utf8) else { throw BackupError.invalid }
            let copy = try LedgerCopy(context)
            let device = defaults.string(forKey: "phoneBackup.device") ?? UUID().uuidString
            defaults.set(device, forKey: "phoneBackup.device")
            let slot = Calendar.current.component(.weekday, from: .now)
            let url = folder.appendingPathComponent("Мои Финансы-" + String(device.prefix(8)) + "-" + String(slot) + ".kdfin")
            try await Task.detached {
                let encrypted = try BackupCipher.seal(copy, password: password)
                var error: NSError?
                var result: Result<Void,Error>?
                NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { destination in
                    result = Result { try encrypted.write(to: destination, options: .atomic) }
                }
                if let error { throw error }
                guard let result else { throw BackupError.incomplete }
                try result.get()
            }.value
            defaults.set(Date.now, forKey: lastKey)
            BackupLog.record()
            defaults.set("Файл записан в выбранную папку " + Date.now.formatted(), forKey: statusKey)
        } catch { defaults.set("Не удалось сохранить копию: " + error.localizedDescription, forKey: statusKey) }
    }
}

private struct PhoneCloudFolder: View {
    @Environment(\.modelContext) private var context
    @AppStorage(PhoneCloudBackup.folderKey) private var bookmark = Data()
    @AppStorage(PhoneCloudBackup.statusKey) private var status = ""
    @State private var selecting = false
    @State private var error = ""
    let password: String
    let confirmation: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Автокопии iPhone").font(.headline)
            if bookmark.isEmpty {
                Text("Выберите папку в iCloud Drive. При открытом приложении сохраняется до семи дневных копий. Пароль для автоматической записи будет храниться в связке ключей этого iPhone.").font(.caption)
                Button("Выбрать папку для автокопий…") { selecting = true }.disabled(password.count < 12 || confirmation != password)
            } else {
                Button("Сохранить в привязанную папку сейчас") { Task { await PhoneCloudBackup.run(context, force: true) } }
                Button("Отключить автокопии") { PhoneCloudBackup.disable() }
            }
            if !status.isEmpty { Text(status).font(.caption) }
            if !error.isEmpty { Text(error).font(.caption) }
        }.fileImporter(isPresented: $selecting, allowedContentTypes: [.folder]) { result in
            do {
                try PhoneCloudBackup.configure(folder: result.get(), password: password)
                error = ""
                Task { await PhoneCloudBackup.run(context, force: true) }
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
