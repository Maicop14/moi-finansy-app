import SwiftUI
import SwiftData
import Security
import UniformTypeIdentifiers

/// The password for one-tap copies, kept in this device's keychain. Copies stay encrypted with it, so it is also
/// needed to restore on a new device: the owner is asked to write it down.
enum BackupPassword {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "local.balance.personalledger") + ".quick-backup",
         kSecAttrAccount as String: "password"]
    }
    static func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        var output: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &output) == errSecSuccess, let data = output as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ password: String) throws {
        guard password.count >= 12 else { throw BackupError.secret }
        let bytes = Data(password.utf8)
        var item = query
        item[kSecValueData as String] = bytes
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary) == errSecSuccess else { throw BackupError.invalid }
        } else if status != errSecSuccess { throw BackupError.invalid }
    }
}

/// Reads a chosen copy file (possibly in iCloud Drive or another provider) within the size limit.
enum BackupFileReader {
    static func read(_ url: URL) throws -> Data {
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
        return try read.get()
    }
}

/// One tap on «Нужна резервная копия»: collect, encrypt (with a progress bar at the bottom), then save the file.
@MainActor final class QuickBackup: ObservableObject {
    enum Phase: Equatable { case idle, collecting, encrypting, ready, saved, failed(String) }
    @Published var phase = Phase.idle
    @Published var progress = 0.0
    @Published var document: BackupFile?
    @Published var exporting = false
    private var ticker: Task<Void, Never>?

    var busy: Bool { phase == .collecting || phase == .encrypting || phase == .ready }
    var filename: String { "Мои Финансы " + Date.now.formatted(.iso8601.year().month().day()) + ".kdfin" }

    func start(context: ModelContext, password: String) {
        guard !busy else { return }
        phase = .collecting
        progress = 0.08
        do {
            let copy = try LedgerCopy(context)
            progress = 0.25
            phase = .encrypting
            // Key derivation takes a second or two; the bar moves towards 90 % meanwhile, then completes.
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled, let self, self.progress < 0.9 else { return }
                    self.progress += (0.92 - self.progress) * 0.06
                }
            }
            Task {
                do {
                    let bytes = try await Task.detached { try BackupCipher.seal(copy, password: password) }.value
                    ticker?.cancel()
                    progress = 1
                    phase = .ready
                    document = BackupFile(bytes)
                    try? await Task.sleep(for: .milliseconds(350))
                    exporting = true
                } catch { fail(error) }
            }
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        ticker?.cancel()
        phase = .failed(error.localizedDescription)
        Task { try? await Task.sleep(for: .seconds(4)); if case .failed = phase { phase = .idle } }
    }

    func finished(_ result: Result<URL, Error>) {
        exporting = false
        document = nil
        switch result {
        case .success:
            BackupLog.record()
            phase = .saved
            Task { try? await Task.sleep(for: .seconds(2.5)); if phase == .saved { phase = .idle } }
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled { cancelled() } else { fail(error) }
        }
    }
    func cancelled() { exporting = false; document = nil; phase = .idle }
}

/// The progress bar at the bottom of the screen while a copy is being made; it disappears when done.
struct QuickBackupBar: View {
    @ObservedObject var backup: QuickBackup
    var body: some View {
        if backup.phase != .idle {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).foregroundStyle(tint)
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    if backup.busy { Text(backup.progress.formatted(.percent.precision(.fractionLength(0)))).font(.caption).monospacedDigit() }
                }
                if backup.busy || backup.phase == .saved {
                    ProgressView(value: backup.progress).tint(tint)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
    private var title: String {
        switch backup.phase {
        case .idle: ""
        case .collecting: "Собираю данные…"
        case .encrypting: "Шифрую копию…"
        case .ready: "Копия готова — выберите, куда сохранить"
        case .saved: "Резервная копия сохранена"
        case .failed(let message): "Не удалось: " + message
        }
    }
    private var icon: String {
        switch backup.phase {
        case .saved: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "externaldrive.fill.badge.timemachine"
        }
    }
    private var tint: Color {
        switch backup.phase { case .saved: Palette.positive; case .failed: Palette.negative; default: Palette.accent }
    }
}

/// First tap: choose the password for copies (once), then the copy starts.
struct QuickBackupPasswordSheet: View {
    let start: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var repeated = ""
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Пароль · минимум 12 символов", text: $password)
                    SecureField("Повторите пароль", text: $repeated)
                } footer: {
                    Text("Копия шифруется этим паролем. Он сохранится на этом iPhone, и дальше копия будет делаться одним нажатием. **Запишите пароль**: без него копию не открыть на новом телефоне.")
                }
                if !error.isEmpty { Text(error).foregroundStyle(Palette.negative) }
            }.formStyle(.grouped).navigationTitle("Пароль для копий")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сделать копию") {
                        do { try BackupPassword.save(password); dismiss(); start(password) }
                        catch { self.error = error.localizedDescription }
                    }.disabled(password.count < 12 || password != repeated)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
    }
}

/// Restore everything from a copy file: pick the file, enter (or reuse) the password, check what is inside, confirm.
struct QuickRestoreSheet: View {
    /// A copy opened from the Files app or the safety copy; nil to pick a file.
    var initialURL: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var picking = false
    @State private var data: Data?
    @State private var name = ""
    @State private var password = BackupPassword.load() ?? ""
    @State private var preview: LedgerCopy?
    @State private var busy = false
    @State private var message = ""
    @State private var done = false
    private var safetyCopy: URL { URL.applicationSupportDirectory.appendingPathComponent("BeforeRestore.kdfin") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(data == nil ? "Выбрать файл копии (.kdfin)…" : "Файл: " + name) { picking = true }
                    SecureField("Пароль копии", text: $password)
                } footer: { Text("Файл копии лежит там, куда вы его сохранили: «Файлы» → «На iPhone», iCloud Drive или другое место.") }
                if let preview {
                    Section("В копии") {
                        LabeledContent("Дата копии", value: preview.date.formatted(date: .long, time: .shortened))
                        LabeledContent("Операций", value: String(preview.entries.count))
                        LabeledContent("Остатков по счетам", value: String(preview.accounts.count))
                        LabeledContent("Планов и проектов", value: String(preview.plans.count + preview.records.count))
                    }
                    Section {
                        Button(done ? "Готово — данные восстановлены" : "Восстановить и заменить данные на этом устройстве", role: .destructive) { restore(preview) }
                            .disabled(busy || done)
                    } footer: { Text("Текущие данные будут заменены. Перед заменой они сохраняются зашифрованной копией на этом устройстве.") }
                }
                if busy { ProgressView() }
                if !message.isEmpty { Text(message).font(.callout) }
            }.formStyle(.grouped).navigationTitle("Восстановление")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(done ? "Закрыть" : "Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Проверить") { check() }.disabled(data == nil || password.count < 12 || busy || preview != nil)
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { result in
                do { load(try result.get()) } catch { message = error.localizedDescription }
            }
            .task { if let initialURL, data == nil { load(initialURL) } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    private func load(_ url: URL) {
        preview = nil; message = ""
        do {
            name = url.lastPathComponent
            data = try BackupFileReader.read(url)
            #if os(iOS)
            // A copy shared via «Поделиться» waits in the share inbox: read once, then removed so it is not offered again.
            ShareInbox.remove([url])
            #endif
            if password.count >= 12 { check() }
        } catch { message = error.localizedDescription }
    }

    private func check() {
        guard let data else { return }
        let key = password
        busy = true; message = ""
        Task {
            defer { busy = false }
            do { preview = try await Task.detached { try BackupCipher.open(data, password: key) }.value; message = "Пароль и целостность проверены." }
            catch { message = error.localizedDescription }
        }
    }

    private func restore(_ copy: LedgerCopy) {
        busy = true
        let key = password, target = safetyCopy
        Task {
            defer { busy = false }
            do {
                let previous = try LedgerCopy(context)
                try await Task.detached { try BackupCipher.seal(previous, password: key).write(to: target, options: .atomic) }.value
                try copy.restore(context)
                // Remember the password on this device, so the next copy is one tap.
                try? BackupPassword.save(key)
                done = true
                message = "Данные восстановлены. Все суммы пересчитаны по сегодняшним котировкам."
            } catch { message = error.localizedDescription }
        }
    }
}

/// Marks that the owner started from scratch (the old archive months are not their history any more).
/// Kept as a setting that travels with backups.
enum FreshStartMark {
    static let key = "capital.freshSince"
    static var isSet: Bool { UserDefaults.standard.string(forKey: key) != nil }
    static func migrate(_ defaults: UserDefaults = .standard) {
        if defaults.string(forKey: key) == nil, defaults.bool(forKey: ResetSeed.flag) { defaults.set("2026-11-20", forKey: key) }
    }
}

/// The sheets and the file saver for one-tap copies, attached to the main screen.
struct QuickBackupHost: ViewModifier {
    @ObservedObject var backup: QuickBackup
    @Binding var askPassword: Bool
    @Binding var restoring: Bool
    @Environment(\.modelContext) private var context
    var restoreURL: URL? = nil
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $askPassword) { QuickBackupPasswordSheet { password in backup.start(context: context, password: password) } }
            .sheet(isPresented: $restoring) { QuickRestoreSheet(initialURL: restoreURL) }
            .fileExporter(isPresented: $backup.exporting, document: backup.document, contentType: .data,
                          defaultFilename: backup.filename) { backup.finished($0) }
            // Closing the save sheet without saving: the bar goes away, nothing is recorded.
            .onChange(of: backup.exporting) { _, open in
                if !open, backup.phase == .ready { Task { try? await Task.sleep(for: .milliseconds(400)); if backup.phase == .ready { backup.cancelled() } } }
            }
    }
}

extension UTType {
    /// Backup files («Мои Финансы 2026-11-21.kdfin»).
    static let kdfin = UTType(exportedAs: "local.balance.personalledger.kdfin", conformingTo: .data)
}

/// «Восстановление»: bring everything back from a copy file — after reinstalling the app, on a new phone, or to undo.
struct RestoreScreen: View {
    let makeBackup: () -> Void
    let restore: (URL?) -> Void
    @AppStorage(ReminderKeys.lastBackup) private var lastBackup = 0.0
    private var safetyCopy: URL { URL.applicationSupportDirectory.appendingPathComponent("BeforeRestore.kdfin") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Восстановить из резервной копии", systemImage: "arrow.counterclockwise.circle.fill").font(.headline)
            Text("Загрузите файл копии (.kdfin) — приложение вернёт все операции, остатки, проекты, бюджет, регулярные платежи, долларовые карты, историю капитала и сроки платежей и пересчитает всё по сегодняшним котировкам.")
                .font(.callout)
            Button { restore(nil) } label: { Label("Выбрать файл копии…", systemImage: "doc.badge.arrow.up") }
                .buttonStyle(.borderedProminent)
            Text("Можно и проще: откройте файл .kdfin в «Файлах» — приложение сразу предложит восстановление.")
                .font(.caption).foregroundStyle(Palette.secondary)
        }.bankTile()

        VStack(alignment: .leading, spacing: 8) {
            Text("Если приложение слетело или новый телефон").font(.headline)
            ForEach(Array(["Установите «Мои Финансы» и задайте PIN.",
                           "Откройте этот раздел: «Главная» → «Восстановление из копии».",
                           "Выберите файл копии из «Файлов» или iCloud Drive.",
                           "Введите пароль копии и нажмите «Восстановить»."].enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text(String(index + 1)).font(.caption.bold()).frame(width: 22, height: 22)
                        .background(Palette.accent.opacity(0.14), in: Circle()).foregroundStyle(Palette.accent)
                    Text(step).font(.callout)
                }
            }
            Text("Пароль копии хранится только на телефоне, где его задали. Для нового телефона его нужно знать.")
                .font(.caption).foregroundStyle(Palette.secondary)
        }.bankTile()

        VStack(alignment: .leading, spacing: 10) {
            Text("Свежая копия").font(.headline)
            Text(lastBackup > 0 ? "Последняя копия: " + Date(timeIntervalSince1970: lastBackup).formatted(date: .long, time: .shortened)
                                : "Копий ещё не было.").font(.callout)
            Button { makeBackup() } label: { Label("Сделать копию сейчас", systemImage: "externaldrive.badge.plus") }.buttonStyle(.bordered)
            if FileManager.default.fileExists(atPath: safetyCopy.path) {
                Divider()
                Text("Перед последним восстановлением прежние данные сохранены здесь, на устройстве.").font(.caption).foregroundStyle(Palette.secondary)
                Button("Вернуть данные, бывшие до восстановления…") { restore(safetyCopy) }
            }
        }.bankTile()
    }
}

/// «Как к вам обращаться?» — asked once after the first unlock; the name can be changed later in «Капитал».
struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ProfileName.current ?? ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Имя", text: $name)
                } footer: {
                    Text("Приложение будет приветствовать: «" + WelcomeScene.title(hour: Calendar.current.component(.hour, from: .now), name: name.trimmingCharacters(in: .whitespaces)) + "». Можно не указывать — тогда просто «Добрый день».")
                }
            }.formStyle(.grouped).navigationTitle("Как к вам обращаться?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Не указывать") { ProfileName.set(""); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить") { ProfileName.set(name); dismiss() } }
            }
        }
        .interactiveDismissDisabled()
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 220)
        #endif
    }
}

/// The greeting name on the «Капитал» page.
struct ProfileSection: View {
    @AppStorage(ProfileName.key) private var stored = ""
    @State private var editing = false
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Приветствие").font(.headline)
                Text("«" + WelcomeScene.title(hour: Calendar.current.component(.hour, from: .now)) + "»").font(.callout).foregroundStyle(Palette.secondary)
            }
            Spacer()
            Button(stored.isEmpty ? "Указать имя" : "Изменить имя") { editing = true }.buttonStyle(.bordered)
        }.bankTile()
        .sheet(isPresented: $editing) { NameSheet() }
    }
}
