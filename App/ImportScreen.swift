import SwiftUI
import SwiftData
import PhotosUI
import QuickLook

private struct StatementPhoto: Transferable {
    let document: BankDocument
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            StatementPhoto(document: try BankFiles.document(at: received.file))
        }
    }
}

struct ImportScreen: View {
    /// «Новых: N · Уже есть: M · До даты остатков: K» — kept out of the body so older compilers type-check it quickly.
    static func counts(_ plan: ImportPlan) -> String {
        let fresh = plan.additions.count, before = plan.beforeCutoff.count, known = plan.skipped.count - before
        return "Новых: \(fresh) · Уже есть: \(known) · До даты остатков: \(before)"
    }

    let accounts: [AccountBalance]
    let incoming: [URL]
    let completed: (Int, [URL]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var entries: [Entry]
    @State private var documents = [BankDocument]()
    @State private var rows = [ImportLine]()
    @State private var account = ""
    @State private var picker = false
    @State private var photos = [PhotosPickerItem]()
    @State private var shareSources = [URL: String]()
    @State private var statementYear = Calendar.current.component(.year, from: .now)
    @State private var showPaste = false
    @State private var pasted = ""
    @FocusState private var pasteFocused: Bool
    @State private var busy = false
    @State private var notice = ""
    @State private var edit: ImportLine?
    @State private var preview: URL?
    @State private var ai: BankDocument?
    @State private var started = false

    var body: some View {
        let cutoffs = Dictionary(accounts.map { ($0.id, $0.cutoff) }, uniquingKeysWith: max)
        let plan = ImportLedger.plan(rows, entries: entries, cutoffs: cutoffs)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Счёт для загрузки", selection: $account) {
                        Text("Выберите счёт").tag("")
                        ForEach(accounts) { Text($0.position.title).tag($0.id) }
                    }.accessibilityIdentifier("importAccount").onChange(of: account) { old, new in
                        for i in rows.indices where rows[i].account == old || rows[i].account.isEmpty {
                            rows[i].account = new; rows[i].confirmedSimilar = false
                        }
                    }
                    HStack {
                        Button { picker = true } label: { Label("Файлы", systemImage: "doc") }
                        PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .images) { Label("Фото", systemImage: "photo") }
                        Button("Текст / JSON") { showPaste = true }
                    }.buttonStyle(.bordered).disabled(busy)
                    Text("CSV, XLSX, PDF, фото и текст. Сверьте суммы в рублях, даты и категории с оригиналом.").font(.caption).foregroundStyle(.secondary)
                    if busy { ProgressView("Чтение документа…") }
                    if !notice.isEmpty { Text(notice).font(.callout).textSelection(.enabled) }
                    ForEach(documents, id: \.digest) { doc in
                        VStack(alignment: .leading) {
                            Text(doc.name).font(.headline)
                            HStack {
                                Button("Оригинал") { do { preview = try ImportPreview.url(doc) } catch { notice = error.localizedDescription } }
                                Button("Добавить строку") {
                                    let next = (rows.filter { $0.source == doc.digest }.map(\.ordinal).max() ?? -1) + 1
                                    edit = ImportLine(source: doc.digest, ordinal: next, original: doc.name, account: account)
                                }
                                Menu("ChatGPT") {
                                    Button("Скопировать шаблон") { copyBankPrompt() }
                                    Button("Разобрать через OpenAI…") { ai = doc }
                                }
                            }.font(.caption)
                        }
                    }
                    #if os(iOS)
                    if incoming.contains(where: { $0.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == ShareInbox.folder?.standardizedFileURL.path }) && !busy {
                        Button("Убрать переданные файлы из очереди", role: .destructive) { ShareInbox.remove(incoming); dismiss() }
                    }
                    #endif
                    if !rows.isEmpty {
                        if rows.contains(where: { $0.date == nil && $0.partialDay != nil }) {
                            Stepper("Год для дат без года: " + String(statementYear), value: $statementYear, in: 2000...Calendar.current.component(.year, from: .now))
                            Button("Применить год к распознанным датам") {
                                for i in rows.indices where rows[i].date == nil {
                                    if let day = rows[i].partialDay, let month = rows[i].partialMonth {
                                        rows[i].date = BankRead.date(String(format: "%02d.%02d.%04d", day, month, statementYear))
                                    }
                                }
                            }
                        }
                        Text("Проверка строк").font(.title2.bold())
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach($rows) { $line in
                                HStack(alignment: .top, spacing: 8) {
                                    Button {
                                        if !line.selected && (!line.valid || line.reviewRequired) { edit = line }
                                        else { line.selected.toggle() }
                                    } label: {
                                        Image(systemName: line.selected ? "checkmark.circle.fill" : "circle").font(.title3)
                                    }.buttonStyle(.borderless).accessibilityLabel("Выбрать строку")
                                    Button { edit = line } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(line.note.isEmpty ? line.original : line.note).lineLimit(2)
                                            Text([accounts.first(where: { $0.id == line.account })?.position.title, line.date?.formatted(date: .numeric, time: .omitted), line.flow?.rawValue, line.category].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                            if let skip = plan.skipped[line.id] { Text(skip).font(.caption).foregroundStyle(.orange) }
                                            if let n = plan.adjusted[line.id] { Text("Разница к учёту: " + money(n)).font(.caption) }
                                            if line.reviewRequired && !line.selected && line.valid { Text("Сверить с оригиналом").font(.caption).foregroundStyle(.orange) }
                                            if !line.valid { Text("Проверить данные").font(.caption).foregroundStyle(.orange) }
                                        }
                                        Spacer()
                                        Text(line.cents.map(money) ?? "—").font(.subheadline.bold())
                                    }.buttonStyle(.plain)
                                }.padding(.vertical, 8)
                                if plan.beforeCutoff.contains(line.id) || line.includeBeforeCutoff {
                                    Toggle("Добавить только в отчёты — остаток не изменится", isOn: $line.includeBeforeCutoff).font(.caption)
                                }
                                if plan.similar.contains(line.id) {
                                    if let match = plan.matchNotes[line.id] { Text(match).font(.caption).foregroundStyle(.secondary) }
                                    Toggle("Это отдельная операция", isOn: $line.confirmedSimilar).font(.caption)
                                }
                                Divider()
                            }
                        }
                        Text(Self.counts(plan)).font(.headline)
                        ForEach([Flow.income, .expense, .transfer]) { kind in
                            let gross = plan.additions.filter { $0.0.flow == kind }.reduce(Int64.zero) { $0 + $1.1 }
                            let covered = plan.replacements.filter { $0.0.kind == kind.rawValue }.reduce(Int64.zero) { $0 + $1.0.cents - $1.1 }
                            if gross > 0 { LabeledContent(kind.rawValue, value: money(gross - covered)) }
                        }
                        if !plan.replacements.isEmpty {
                            let covered: Int64 = plan.replacements.reduce(0) { $0 + $1.0.cents - $1.1 }
                            Text("Из ранее учтённых сводок будет вычтено \(money(covered)) — теперь эта сумма подтверждена покупками.").font(.caption)
                        }
                        let changes = plan.balanceChanges(accounts: accounts)
                        if !changes.isEmpty {
                            DisclosureGroup("Остатки после импорта") {
                                ForEach(accounts.filter { changes[$0.id] != nil }) { acct in
                                    let after: Int64 = acct.position.amount + (changes[acct.id] ?? 0)
                                    LabeledContent(acct.position.title, value: "\(money(acct.position.amount)) → \(money(after))")
                                }
                            }
                        }
                        if let error = plan.errors.first { Text(error).foregroundStyle(.orange) }
                    }
                }.padding().frame(maxWidth: 800).frame(maxWidth: .infinity)
            }.navigationTitle("Импорт операций")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") {
                            do {
                                let count = try ImportLedger.save(rows: rows, documents: documents, container: context.container, expected: plan, cutoffs: cutoffs)
                                completed(count, shareSources.compactMap { file, digest in rows.contains { $0.source == digest && $0.selected } ? file : nil }); dismiss()
                            } catch { notice = error.localizedDescription }
                        }.disabled(busy || !plan.errors.isEmpty || plan.additions.isEmpty)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 650, minHeight: 470)
        #endif
        .quickLookPreview($preview)
        .onChange(of: preview) { old, new in
            if old != new { ImportPreview.remove(old) }
        }
        .onDisappear { ImportPreview.remove(preview) }
        .fileImporter(isPresented: $picker, allowedContentTypes: BankFiles.types, allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { Task { await load(urls) } }
        }
        .dropDestination(for: URL.self) { urls, _ in guard !busy else { return false }; Task { await load(urls) }; return true }
        .task { if !started { started = true; await load(incoming) } }
        .onChange(of: incoming) { _, urls in Task { await load(urls) } }
        .onChange(of: photos) { _, selection in
            guard !selection.isEmpty else { return }
            Task {
                busy = true; defer { busy = false; photos = [] }
                for photo in selection {
                    do {
                        guard let photo = try await photo.loadTransferable(type: StatementPhoto.self) else { throw ImportIssue.message("Фото недоступно") }
                        await add(photo.document)
                    } catch { notice = error.localizedDescription }
                }
            }
        }
        .sheet(item: $edit) { row in
            ReviewEditor(row: row, accounts: accounts) { updated in
                if let i = rows.firstIndex(where: { $0.id == updated.id }) { rows[i] = updated } else { rows.append(updated) }
            }
        }
        .sheet(isPresented: $showPaste) {
            NavigationStack {
                VStack(alignment: .leading) {
                    Button("Скопировать шаблон ChatGPT") { copyBankPrompt() }
                    PasteButton(payloadType: String.self) { values in pasted = values.joined(separator: "\n") }
                    TextEditor(text: $pasted).focused($pasteFocused).onAppear { pasteFocused = true }.accessibilityIdentifier("importText").frame(minHeight: 150)
                }.padding().navigationTitle("Текст или ответ ChatGPT")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { showPaste = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Прочитать") {
                                guard pasted.utf8.count <= BankFiles.textLimit else { showPaste = false; notice = BankFiles.large.localizedDescription; return }
                                let doc = BankDocument(name: "Вставленный текст.txt", bytes: Data(pasted.utf8))
                                showPaste = false; pasted = ""
                                Task { busy = true; await add(doc); busy = false }
                            }.disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }.padding()
        }
        .sheet(isPresented: Binding(get: { ai != nil }, set: { if !$0 { ai = nil } })) {
            if let doc = ai {
                BankAIView(doc: doc) { parsed in
                    let otherCount = rows.filter { $0.source != doc.digest }.count
                    guard otherCount + parsed.count <= BankFiles.rowLimit else {
                        notice = BankFiles.large.localizedDescription; ai = nil; return
                    }
                    rows.removeAll { $0.source == doc.digest }
                    append(parsed)
                    ai = nil
                }
            }
        }
    }

    @MainActor private func load(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        busy = true; defer { busy = false }
        let remainingCount = max(0, BankFileInput.fileCount - documents.count)
        if urls.count > remainingCount { notice = "Один импорт поддерживает до 20 файлов. Оставшиеся файлы можно открыть отдельно." }
        for url in urls.prefix(remainingCount) {
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let doc = try await Task.detached {
                    try BankFiles.document(at: url)
                }.value
                await add(doc)
                shareSources[url] = doc.digest
            } catch { notice = url.lastPathComponent + " · " + error.localizedDescription }
        }
    }
    @MainActor private func add(_ doc: BankDocument) async {
        guard doc.bytes.count <= BankFiles.byteLimit else { notice = "Ограничение файла — 24 МБ."; return }
        guard !documents.contains(where: { $0.digest == doc.digest }) else { notice = "Этот файл уже открыт для проверки."; return }
        guard documents.count < BankFileInput.fileCount,
              documents.reduce(doc.bytes.count, { $0 + $1.bytes.count }) <= BankFileInput.batchLimit else {
            notice = "Один импорт поддерживает до 20 файлов общим объёмом до 64 МБ."; return
        }
        documents.append(doc)
        do {
            let parsed = try await Task.detached { try BankFiles.extract(doc) }.value
            guard parsed.count + rows.count <= 5000 else { throw ImportIssue.message("За один раз можно проверить до 5 000 строк. Выгрузите более короткий период.") }
            append(parsed)
            if parsed.isEmpty { notice = "Строки не найдены. Откройте оригинал или добавьте строку вручную." }
        } catch { notice = doc.name + " · " + error.localizedDescription }
    }
    private func append(_ parsed: [ImportLine]) {
        rows.append(contentsOf: parsed.map { var line = $0; line.account = account; return line })
    }
}

enum ImportPreview {
    static func url(_ doc: BankDocument) throws -> URL {
        purgeOld()
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = (doc.name as NSString).lastPathComponent
        let url = folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "Документ" : name)
        do {
            #if os(iOS)
            try doc.bytes.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try doc.bytes.write(to: url, options: .atomic)
            #endif
            return url
        } catch { remove(url); throw error }
    }
    private static let root = FileManager.default.temporaryDirectory.appendingPathComponent("StatementPreviews", isDirectory: true)
    static func remove(_ url: URL?) {
        guard let folder = url?.deletingLastPathComponent(),
              folder.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: folder)
    }
    // Remove older versions' digest-based previews and leftovers from interrupted sessions.
    static func purgeOld() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for dir in dirs {
            let legacy = dir.lastPathComponent.wholeMatch(of: /[a-f0-9]{64}/) != nil
            let created = try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate
            if legacy || (created ?? .distantPast) < Date.now.addingTimeInterval(-86_400) {
                try? fm.removeItem(at: dir)
            }
        }
    }
}

private func copyBankPrompt() {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(BankJSON.prompt, forType: .string)
    #else
    UIPasteboard.general.string = BankJSON.prompt
    #endif
}

private struct ReviewEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var row: ImportLine
    let accounts: [AccountBalance]
    let finish: (ImportLine) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("Строка источника") { Text(row.original).font(.caption).textSelection(.enabled) }
                Toggle("Итог по категории за период", isOn: $row.summary)
                if row.summary {
                    Text("Сохранить разницу с уже внесёнными операциями или пропустить строку и дождаться детализации.").font(.caption)
                    dateField("Начало периода", $row.since)
                }
                dateField(row.summary ? "Конец периода" : "Дата операции", $row.date, time: !row.summary)
                if let date = row.date, let source = accounts.first(where: { $0.id == row.account }), date <= source.cutoff {
                    Text("Дата до последней сверки счёта. Сумма войдёт в историю операций, подтверждённый остаток сохранится.").font(.caption)
                }
                TextField("Сумма в рублях", text: $row.amount)
                Picker("Направление", selection: $row.flow) {
                    Text("Выберите").tag(nil as Flow?)
                    ForEach(Flow.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                Picker(row.flow == .transfer ? "Счёт списания" : "Счёт", selection: $row.account) {
                    Text("Выберите").tag("")
                    ForEach(accounts) { Text($0.position.title).tag($0.id) }
                }
                if row.flow == .transfer {
                    Picker("Куда", selection: $row.destination) {
                        Text("Выберите").tag("")
                        ForEach(accounts.filter { $0.id != row.account }) { Text($0.position.title).tag($0.id) }
                    }
                } else {
                    TextField("Категория", text: $row.category)
                    Menu("Выбрать категорию") {
                        ForEach((row.flow ?? .expense).categories, id: \.self) { cat in Button(cat) { row.category = cat } }
                    }
                }
                TextField("Описание", text: $row.note)
            }.formStyle(.grouped).navigationTitle("Проверка строки")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Пропустить") { row.selected = false; finish(row); dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Включить") { row.selected = true; row.reviewRequired = false; row.confirmedSimilar = false; finish(row); dismiss() }.disabled(!row.valid) }
                }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 480)
        #endif
    }
    @ViewBuilder func dateField(_ title: String, _ binding: Binding<Date?>, time: Bool = false) -> some View {
        if let value = binding.wrappedValue {
            DatePicker(title, selection: Binding(get: { binding.wrappedValue ?? value }, set: { binding.wrappedValue = $0 }), displayedComponents: time ? [.date, .hourAndMinute] : .date)
        } else {
            Button("Указать: " + title) { binding.wrappedValue = .now }
        }
    }
}

private final class BankAPIRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct BankAIView: View {
    let doc: BankDocument
    let finish: ([ImportLine]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var pasted = ""
    @State private var running = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Обычный чат") {
                    Button("Скопировать шаблон") { copyBankPrompt() }
                    TextField("Вставить JSON из ChatGPT", text: $pasted, axis: .vertical)
                    Button("Применить к этому оригиналу") {
                        do { finish(try BankJSON.read(pasted, source: doc.digest)) }
                        catch { message = "Проверьте формат JSON." }
                    }.disabled(pasted.isEmpty || running)
                }
                Section("OpenAI API") {
                    Text("По нажатию файл «" + doc.name + "» целиком и шаблон будут отправлены в OpenAI. Ответ заменит черновик этого файла для повторной проверки.").font(.callout)
                    SecureField("API-ключ OpenAI на этот сеанс", text: $key)
                    Button("Отправить файл и шаблон") {
                        Task { await analyze() }
                    }.disabled(running || key.isEmpty)
                }
                if running { ProgressView() }
                if !message.isEmpty { Text(message) }
            }.formStyle(.grouped).navigationTitle("Разбор через ChatGPT")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(running) } }
        }.interactiveDismissDisabled(running)
        #if os(macOS)
        .frame(minWidth: 470, minHeight: 370)
        #endif
    }
    @MainActor private func analyze() async {
        guard !running else { return }
        running = true; defer { running = false }
        do {
            let ext = (doc.name as NSString).pathExtension
            let type = UTType(filenameExtension: ext) ?? .data
            let dataURL = "data:" + (type.preferredMIMEType ?? "application/octet-stream") + ";base64," + doc.bytes.base64EncodedString()
            let file: [String: String] = type.conforms(to: .image) ? ["type":"input_image","image_url":dataURL] :
                ["type":"input_file","filename":doc.name,"file_data":dataURL]
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpMethod = "POST"; request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model":"gpt-4.1-mini", "store":false,
                "text":["format":["type":"json_object"]],
                "input":[["role":"user","content":[["type":"input_text","text":BankJSON.prompt], file]]]
            ])
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration, delegate: BankAPIRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200...299).contains(http.statusCode) else { throw ImportIssue.message("OpenAI вернул код " + String(http.statusCode) + ". Проверьте ключ и доступ к API.") }
            var data = Data()
            for try await byte in stream {
                guard data.count < 4_000_000 else { throw BankFiles.large }
                data.append(byte)
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let output = json?["output"] as? [[String: Any]] ?? []
            let strings = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }
            finish(try BankJSON.read(strings.joined(), source: doc.digest))
        } catch { message = error.localizedDescription }
    }
}

struct SourceLink: View {
    let digest: String
    @Environment(\.modelContext) private var context
    @State private var preview: URL?
    @State private var error = false
    var body: some View {
        Button {
            do {
                let id = digest
                var fetch = FetchDescriptor<StatementSource>(predicate: #Predicate { $0.digest == id })
                fetch.fetchLimit = 1
                guard let source = try context.fetch(fetch).first else { throw URLError(.fileDoesNotExist) }
                preview = try ImportPreview.url(BankDocument(name: source.name, bytes: source.bytes))
            } catch { self.error = true }
        } label: { Label("Открыть оригинал", systemImage: "doc.text") }
        .quickLookPreview($preview)
        .onChange(of: preview) { old, new in
            if old != new { ImportPreview.remove(old) }
        }
        .onDisappear { ImportPreview.remove(preview) }
        .alert("Не удалось открыть оригинал", isPresented: $error) { Button("ОК") {} }
    }
}

#if os(iOS)
enum ShareInbox {
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.local.balance.personalledger.imports")?.appendingPathComponent("Pending")
    }
    static func pending() -> [URL] {
        guard let folder else { return [] }
        let fm = FileManager.default
        let batches = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return batches.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }.sorted { $0.path < $1.path }
    }
    static func remove(_ urls: [URL]) {
        guard let root = folder?.standardizedFileURL else { return }
        for url in urls {
            let batch = url.deletingLastPathComponent().standardizedFileURL
            guard batch.deletingLastPathComponent().path == root.path else { continue }
            try? FileManager.default.removeItem(at: url)
            if (try? FileManager.default.contentsOfDirectory(atPath: batch.path).isEmpty) == true { try? FileManager.default.removeItem(at: batch) }
        }
    }
}
#endif
