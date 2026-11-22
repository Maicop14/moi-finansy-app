import SwiftUI
import QuickLook
import SwiftData
import UserNotifications
#if os(macOS)
import Charts
#endif

enum Flow: String, CaseIterable, Identifiable {
    case expense = "Расход", income = "Доход", transfer = "Перевод"
    var id: Self { self }
    var categories: [String] {
        if self == .transfer { return ["Перевод"] }
        return self == .expense ? ["Продукты", "Кафе", "Транспорт", "Дом", "Здоровье", "Досуг", "Подписки", "Связь", "Красота", "Одежда и обувь", "Маркетплейсы", "Техника", "Закупка товара", Charity.category, "Другое"] : ["Зарплата", "Чистая прибыль от торговли", "Другой заработок", "Подарки", "Другое"]
    }
}

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
    /// Optional finer split of the category, e.g. Кафе → Кофейни. Older operations get one inferred from the note.
    var subcategory: String?
    var transfer: Bool { kind == Flow.transfer.rawValue }
    init(cents: Int64, flow: Flow, category: String, note: String, date: Date) {
        self.cents = cents
        self.kind = flow.rawValue
        self.category = category
        self.note = note
        self.date = date
    }
    var income: Bool { kind == Flow.income.rawValue }
}

func money(_ cents: Int64) -> String {
    if DemoMode.isOn { return DemoMode.masked() }
    return (Decimal(cents) / 100).formatted(.currency(code: "RUB").locale(Locale(identifier: "ru_RU")))
}

@main struct BalanceApp: App {
    @StateObject private var gate = AppLock()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    #endif
    /// The delegate is set before launch finishes, so a tap on a notification that opened the app is not lost.
    init() {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        #if SNAPSHOTS && os(macOS)
        WindowSnapshots.run()
        #endif
    }
    var body: some Scene {
        WindowGroup {
            LockedRoot(gate: gate).environment(\.locale, Locale(identifier: "ru_RU"))
        }.modelContainer(for: [Entry.self, Checkpoint.self, StatementSource.self, IncomePlan.self, BackupInstall.self, FinanceRecord.self],
                         inMemory: DemoMode.isOn)
        #if os(macOS)
        .defaultSize(width: 1100, height: 740)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { LedgerCommands(gate: gate) }
        #endif
        #if os(macOS)
        Settings { MacSettings(gate: gate).environment(\.locale, Locale(identifier: "ru_RU")) }
        #endif
    }
}

private enum BankPage: String, CaseIterable, Identifiable {
    case home = "Главная", operations = "Операции", accounts = "Счета", capital = "Капитал"

    case charity = "Благотворительность"
    case recurring = "Регулярные платежи", budget = "Бюджет", restore = "Восстановление"
    case earnings = "Доходы", investments = "Инвестиции", loans = "Кредиты", receivables = "Мне должны"

    var id: Self { self }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .operations: "arrow.left.arrow.right"
        case .accounts: "wallet.bifold.fill"
        case .capital: "chart.bar.fill"
        case .charity: "heart.fill"
        case .recurring: "repeat.circle.fill"
        case .budget: "chart.bar.doc.horizontal.fill"
        case .restore: "arrow.counterclockwise.circle.fill"
        case .earnings: "banknote.fill"
        case .investments: "chart.line.uptrend.xyaxis"
        case .loans: "creditcard.fill"
        case .receivables: "person.2.fill"
        }
    }
}

extension BankPage {
    /// Sidebar groups on the Mac, in the order of the menu «Раздел» (⌘1…⌘9 for the first nine).
    static let sidebar: [(title: String, pages: [BankPage])] = [
        ("Обзор", [.home, .capital]),
        ("Деньги", [.operations, .accounts, .earnings, .investments]),
        ("Долги", [.loans, .receivables]),
        ("Планирование", [.budget, .recurring, .charity]),
        ("Данные", [.restore]),
    ]
}

/// Menu bar commands, delivered to the open main window through the notification centre.
enum LedgerCommand: String {
    case newExpense, newIncome, newTransfer, importStatements, search, refreshQuotes, backup, restore
    static let notification = Notification.Name("kd.ledger.command")
    static func send(_ raw: String) { NotificationCenter.default.post(name: notification, object: raw) }
}

#if os(macOS)
/// Closing the window quits the app, so the next start asks for the PIN or Touch ID again;
/// minimising keeps it open where it was.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The macOS menu bar: «Файл», «Правка → Найти», «Вид», «Раздел» and «Справка».
struct LedgerCommands: Commands {
    @ObservedObject var gate: AppLock
    private var open: Bool { gate.screen == .open }
    private func send(_ command: LedgerCommand) { LedgerCommand.send(command.rawValue) }

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .appSettings) {
            Button("Заблокировать") { gate.lock() }.keyboardShortcut("l", modifiers: [.command, .control]).disabled(!open)
        }
        CommandGroup(replacing: .newItem) {
            Group {
                Button("Новый расход") { send(.newExpense) }.keyboardShortcut("n")
                Button("Новый доход") { send(.newIncome) }.keyboardShortcut("n", modifiers: [.command, .option])
                Button("Новый перевод") { send(.newTransfer) }.keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                Button("Импорт выписки…") { send(.importStatements) }.keyboardShortcut("i")
            }.disabled(!open)
        }
        CommandGroup(replacing: .saveItem) {
            Group {
                Button("Создать резервную копию") { send(.backup) }.keyboardShortcut("s")
                Button("Восстановить из копии…") { send(.restore) }.keyboardShortcut("o", modifiers: [.command, .shift])
            }.disabled(!open)
        }
        CommandGroup(replacing: .textEditing) {
            Button("Найти…") { send(.search) }.keyboardShortcut("f").disabled(!open)
        }
        CommandGroup(before: .toolbar) {
            Button("Обновить котировки") { send(.refreshQuotes) }.keyboardShortcut("r").disabled(!open)
            Divider()
        }
        CommandMenu("Раздел") {
            Group {
                let pages = BankPage.sidebar.flatMap(\.pages)
                ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                    if index < 9 {
                        Button(page.rawValue) { LedgerCommand.send(page.rawValue) }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    } else {
                        Button(page.rawValue) { LedgerCommand.send(page.rawValue) }
                    }
                }
            }.disabled(!open)
        }
        CommandGroup(replacing: .help) {
            Link("О приложении «Мои Финансы»", destination: URL(string: "https://github.com/Maicop14/moi-finansy-app#readme")!)
        }
    }
}

/// «Настройки…» (⌘,): only settings without amounts. While the app is locked they stay closed.
struct MacSettings: View {
    @ObservedObject var gate: AppLock
    var body: some View {
        Group {
            if gate.screen == .open {
                TabView {
                    MacGeneralSettings(gate: gate).tabItem { Label("Основные", systemImage: "gearshape") }
                    ScrollView { NotificationsPanel().padding(20) }
                        .tabItem { Label("Уведомления", systemImage: "bell.badge") }
                }
            } else {
                ContentUnavailableView("Приложение заблокировано", systemImage: "lock.fill",
                                       description: Text("Войдите в «Мои Финансы», чтобы изменить настройки."))
            }
        }.frame(width: 500, height: 440)
    }
}

private struct MacGeneralSettings: View {
    @ObservedObject var gate: AppLock
    @AppStorage(ProfileName.key) private var name = ""
    @AppStorage("display.currency") private var displayCode = DisplayCurrency.rub.rawValue
    var body: some View {
        Form {
            Section("Приветствие") {
                TextField("Как к вам обращаться", text: Binding(get: { name }, set: { ProfileName.set($0) }), prompt: Text("Без имени"))
                Text("«" + WelcomeScene.title(hour: Calendar.current.component(.hour, from: .now)) + "»").foregroundStyle(.secondary)
            }
            Section("Суммы") {
                Picker("Показывать в", selection: $displayCode) {
                    ForEach(DisplayCurrency.allCases) { Text($0.rawValue + " · " + $0.symbol).tag($0.rawValue) }
                }
            }
            Section("Вход") {
                LabeledContent("PIN", value: "4 цифры, только на этом Mac")
                LabeledContent("Touch ID", value: gate.biometricLabel == nil ? "после входа по PIN" : "включён")
                Text("Вход запрашивается при каждом запуске. Закрытие окна завершает приложение; свёрнутое окно остаётся открытым.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Заблокировать сейчас") { gate.lock() }
            }
        }.formStyle(.grouped)
    }
}
#endif

struct HoverOutline: ViewModifier {
    let radius: CGFloat
    let row: Bool
    @State private var over = false
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .background { if row { RoundedRectangle(cornerRadius: radius).fill(Palette.accent.opacity(over ? 0.07 : 0)).padding(.horizontal, -6) } }
            .overlay { if !row { RoundedRectangle(cornerRadius: radius).strokeBorder(Palette.accent.opacity(over ? 0.4 : 0), lineWidth: 1.5).allowsHitTesting(false) } }
            .onHover { over = $0 }
            .animation(.easeOut(duration: 0.12), value: over)
        #else
        content
        #endif
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// Colours of the «Ясный» design. Light mode uses them as is; dark mode keeps system colours.
enum Palette {
    static let canvasLight = Color(red: 0xF4 / 255, green: 0xF6 / 255, blue: 0xFA / 255)
    static let accent = Color(red: 0x24 / 255, green: 0x57 / 255, blue: 0xD6 / 255)
    static let positive = Color(red: 0x1E / 255, green: 0x8E / 255, blue: 0x5A / 255)
    static let negative = Color(red: 0xC2 / 255, green: 0x41 / 255, blue: 0x2D / 255)
    #if os(macOS)
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let text = adaptive(NSColor(red: 0x0F / 255, green: 0x1B / 255, blue: 0x2D / 255, alpha: 1), .labelColor)
    static let secondary = adaptive(NSColor(red: 0x5B / 255, green: 0x66 / 255, blue: 0x76 / 255, alpha: 1), .secondaryLabelColor)
    static let canvas = adaptive(NSColor(red: 0xF4 / 255, green: 0xF6 / 255, blue: 0xFA / 255, alpha: 1), NSColor(white: 0.13, alpha: 1))
    #else
    private static func adaptive(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    static let text = adaptive(UIColor(red: 0x0F / 255, green: 0x1B / 255, blue: 0x2D / 255, alpha: 1), .label)
    static let secondary = adaptive(UIColor(red: 0x5B / 255, green: 0x66 / 255, blue: 0x76 / 255, alpha: 1), .secondaryLabel)
    static let canvas = adaptive(UIColor(red: 0xF4 / 255, green: 0xF6 / 255, blue: 0xFA / 255, alpha: 1), UIColor(white: 0.13, alpha: 1))
    #endif
}

extension View {
    /// Mac: a light outline (or a row tint) under the pointer on clickable tiles. iPhone: unchanged.
    func hoverOutline(_ radius: CGFloat = 20, row: Bool = false) -> some View { modifier(HoverOutline(radius: radius, row: row)) }
    /// A right-click menu on the Mac; on iPhone the row keeps its usual tap and buttons.
    @ViewBuilder func desktopMenu<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
        #if os(macOS)
        contextMenu(menuItems: items)
        #else
        self
        #endif
    }
    func bankTile(_ inset: CGFloat = 16) -> some View {
        padding(inset).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.055), radius: 6, y: 3)
    }
}

struct Ledger: View {
    @Binding var pendingURL: URL?
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \Entry.date, order: .reverse) private var entries: [Entry]
    @Query private var checkpoints: [Checkpoint]
    @Query private var records: [FinanceRecord]
    @State private var quotesBusy = false
    @State private var quotesNote = ""
    @State private var quotesSettled = false
    @StateObject private var quickBackup = QuickBackup()
    @State private var askBackupPassword = false
    @State private var restoring = false
    @State private var restoreURL: URL?
    @State private var askName = false
    @FocusState private var searchFocused: Bool
    @State private var page = BankPage.home
    @State private var query = ""
    @State private var newDebt: BankPage?
    @State private var transferSource = ""
    @State private var transferTarget = ""
    @State private var creating: Flow?
    @State private var editingEntry: Entry?
    @State private var removal: Entry?
    @State private var selectedAccount: AccountBalance?
    @Environment(\.scenePhase) private var phase
    @State private var importing = false
    @State private var incoming = [URL]()
    @State private var importedNotice = ""
    @State private var problem = ""
    @AppStorage("portfolio.reconciliation") private var legacy = Data()
    @AppStorage("display.currency") private var displayCode = DisplayCurrency.rub.rawValue
    @AppStorage("markets.prices") private var priceCache = Data()
    private var display: DisplayCurrency { DisplayCurrency.selected(displayCode, prices: prices) }
    private var prices: MarketPrices { (try? JSONDecoder().decode(MarketPrices.self, from: priceCache)) ?? .initial }
    /// Accounts closed by the person (zero balance), as a JSON array of keys. Balances still count them.
    @AppStorage("accounts.hidden") private var hiddenData = Data()
    @State private var showHidden = false
    private var hidden: Set<String> { Set((try? JSONDecoder().decode([String].self, from: hiddenData)) ?? []) }
    private func setHidden(_ key: String, _ value: Bool) {
        var keys = hidden
        if value { keys.insert(key) } else { keys.remove(key) }
        hiddenData = (try? JSONEncoder().encode(keys.sorted())) ?? Data()
    }
    /// Balances at today's quotes: metals and currency cards are revalued every time prices refresh.
    private var accounts: [AccountBalance] {
        guard let archive = Archive.bundled else { return [] }
        return LiveCapital.apply(balances(archive: archive, checkpoints: checkpoints, entries: entries), prices: prices,
                                 lots: (try? LotMovement.decode(records)) ?? [])
    }
    private var netWorth: Int64 { accounts.reduce(0) { $0 + ($1.position.debt ? -$1.position.amount : $1.position.amount) } }

    /// One tap on «Нужна резервная копия»: the first time asks for the copy password, then copies right away.
    private func makeBackup() {
        if let password = BackupPassword.load() { withAnimation(.snappy) { quickBackup.start(context: context, password: password) } }
        else { askBackupPassword = true }
    }

    /// Fresh metals and currency quotes once a day, on the first launch of the day; later launches that day
    /// use the stored quotes without going online. Pull down on the home screen to refresh by hand.
    private func refreshQuotes(force: Bool = false) async {
        let defaults = UserDefaults.standard
        guard force || QuoteSchedule.due(now: .now) else {
            quotesNote = defaults.string(forKey: QuoteSchedule.noteKey) ?? ""
            quotesSettled = true
            NetWorthHistory.record(netWorth, at: .now, fresh: true)
            return
        }
        guard !quotesBusy else { return }
        quotesBusy = true
        let (next, failed) = await MarketPrices.refreshed(prices)
        if let data = try? JSONEncoder().encode(next) { priceCache = data }
        quotesBusy = false
        quotesNote = QuoteSchedule.note(next, failed: failed, at: .now)
        defaults.set(quotesNote, forKey: QuoteSchedule.noteKey)
        defaults.removeObject(forKey: "markets.lastErrors")
        // A day counts as done once anything loaded; if both sources failed, the next launch tries again.
        if failed.count < 2 { QuoteSchedule.done(now: .now) }
        quotesSettled = true
        NetWorthHistory.record(netWorth, at: .now, fresh: failed.count < 2)
    }
    private var canvas: Color { scheme == .dark ? Color(white: 0.09) : Palette.canvasLight }

    var body: some View {
        let list = accounts
        mainLayout(list)
        #if os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 0) {
                ForEach([BankPage.home, .operations, .accounts, .capital]) { tab in tabButton(tab) }
            }.padding(.vertical, 5).background(.bar)
        }
        #else
        .frame(minWidth: 760, minHeight: 540)
        .toolbar { macToolbar }
        .onReceive(NotificationCenter.default.publisher(for: LedgerCommand.notification)) { perform($0.object as? String) }
        #endif
        .tint(Palette.accent)
        .overlay(alignment: .bottom) { if DemoMode.isOn { DemoCaption(text: DemoMode.caption(page.rawValue)).padding(.bottom, 74) } }
        .task { migrateRevision(); if pendingURL == nil { openPending() } }
        .modifier(QuickBackupHost(backup: quickBackup, askPassword: $askBackupPassword, restoring: $restoring, restoreURL: restoreURL))
        .sheet(isPresented: $askName) { NameSheet() }
        .task {
            if !DemoMode.isOn, !UserDefaults.standard.bool(forKey: ProfileName.askedKey) {
                Task { try? await Task.sleep(for: .milliseconds(600)); askName = true }
            }
            FreshStartMark.migrate()
            LiveCapital.migrateIfNeeded(checkpoints)
            if let archive = Archive.bundled { LiveCapital.sync(balances(archive: archive, checkpoints: checkpoints, entries: entries), prices: prices) }
            await refreshQuotes()
        }
        .onChange(of: netWorth) { _, value in if quotesSettled { NetWorthHistory.record(value, at: .now, fresh: !QuoteSchedule.due(now: .now)) } }
        .onReceive(NotificationRouter.shared.$route) { route in
            guard let route else { return }
            page = switch route { case .charity: .charity; case .payment, .project: .loans; case .recurring: .recurring; default: .capital }
            NotificationRouter.shared.route = nil
        }
        .onChange(of: phase) { _, next in if next == .active { openPending(); Task { await refreshQuotes() } } } // only does work on a new day
        .onChange(of: pendingURL, initial: true) { _, value in
            guard let url = value else { return }
            pendingURL = nil
            // A backup file opened from «Файлы» goes straight to restore; anything else is a statement to import.
            if url.pathExtension.lowercased() == "kdfin" { restoreURL = url; restoring = true; return }
            incoming = [url]; importing = true
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            // A backup file dropped on the window opens the restore; statements go to the import.
            if let copy = urls.first(where: { $0.pathExtension.lowercased() == "kdfin" }) { restoreURL = copy; restoring = true; return true }
            incoming = urls; importing = true; return true
        }
        .sheet(isPresented: $importing, onDismiss: { incoming = [] }) {
            ImportScreen(accounts: list, incoming: incoming) { count, reviewedFiles in
                #if os(iOS)
                ShareInbox.remove(reviewedFiles)
                #endif
                importedNotice = "Сохранено операций: " + String(count); page = .operations
            }
        }
        .sheet(item: $creating, onDismiss: { transferSource = ""; transferTarget = "" }) {
            EntryForm(accounts: list, initialFlow: $0, source: transferSource, target: transferTarget)
        }
        .sheet(item: $newDebt) { section in NewDebt(isLoan: section == .loans) }
        .sheet(item: $editingEntry) { EntryForm(accounts: list, existing: $0) }
        .sheet(item: $selectedAccount) { account in
            NavigationStack {
                ScrollView {
                    let current = list.first { $0.id == account.id } ?? account
                    VStack(alignment: .leading, spacing: 16) {
                        Text(current.position.title).font(.title2.bold())
                        Text(money(current.position.amount)).font(.largeTitle.bold())
                        if hidden.contains(account.id) {
                            Button("Вернуть счёт в списки") { setHidden(account.id, false) }
                        } else if current.position.amount == 0 {
                            Button("Скрыть закрытый счёт") { setHidden(account.id, true); selectedAccount = nil }
                        }
                        Text("Операции по счёту").font(.headline)
                        let related = entries.filter { $0.accountKey == account.id || $0.destinationKey == account.id }
                        if related.isEmpty { Text("Пока нет операций").foregroundStyle(.secondary) }
                        ForEach(related) { item in
                            let cash = item.cashDelta(for: account.id)
                            let change = current.position.debt ? -cash : cash
                            LabeledContent(item.category, value: (change > 0 ? "+" : "") + money(change))
                            Text(item.date, style: .date).font(.caption)
                            Divider()
                        }
                    }.bankTile().padding()
                }.background(canvas).toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Готово") { selectedAccount = nil } }
                }
            }
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 340)
            #endif
        }
        .alert("Удалить операцию?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { entry in
            Button("Удалить", role: .destructive) {
                context.delete(entry)
                do { try context.save() } catch { context.rollback(); problem = "Не удалось удалить операцию." }
            }
            Button("Отмена", role: .cancel) {}
        } message: { Text($0.category + " · " + money($0.cents)) }
        .alert("Ошибка сохранения", isPresented: Binding(get: { !problem.isEmpty }, set: { if !$0 { problem = "" } })) { Button("ОК") {} } message: { Text(problem) }
    }

    /// iPhone: one stack with the tab bar below. Mac: a native sidebar with every section and the page on the right.
    @ViewBuilder private func mainLayout(_ list: [AccountBalance]) -> some View {
        #if os(macOS)
        NavigationSplitView {
            List(selection: Binding<BankPage?>(get: { page }, set: { if let next = $0, next != page { query = ""; page = next } })) {
                ForEach(BankPage.sidebar, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.pages) { tab in Label(tab.rawValue, systemImage: tab.icon).tag(tab) }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
        } detail: {
            pageStack(list)
        }
        #else
        pageStack(list)
        #endif
    }

    private func pageStack(_ list: [AccountBalance]) -> some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if page == .home {
                            searchBar
                            if query.isEmpty {
                                #if os(macOS)
                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .top, spacing: 20) {
                                        VStack(alignment: .leading, spacing: 15) { home(list) }.frame(minWidth: 300)
                                        capitalTrend.frame(minWidth: 280, maxWidth: 360)
                                    }
                                    VStack(alignment: .leading, spacing: 15) { home(list); capitalTrend }
                                }
                                #else
                                home(list)
                                #endif
                            } else { searchResults(list) }
                        } else {
                            #if os(iOS)
                            Text(page.rawValue).font(.largeTitle.bold())
                            #endif
                            switch page {
                            case .accounts:
                                accountsList(showHidden ? list : list.filter { !hidden.contains($0.id) })
                                if !hidden.isEmpty {
                                    Toggle("Показать скрытые счета (" + String(hidden.count) + ")", isOn: $showHidden)
                                }
                            case .operations:
                                SpendingBreakdownView(entries: entries, format: { display.format($0, prices: prices) }) { editingEntry = $0 }
                                HStack {
                                    Text("История").font(.headline)
                                    Spacer()
                                    Button("Импорт") { importing = true }.buttonStyle(.bordered)
                                    Button("Добавить") { creating = .expense }.buttonStyle(.bordered)
                                }
                                if !importedNotice.isEmpty { Text(importedNotice).font(.caption) }
                                operationRows(entries.filter { $0.cents > 0 }, accounts: list)
                            case .charity: CharityScreen(entries: entries, accounts: list)
                            case .recurring: RecurringScreen(accounts: list.filter { !hidden.contains($0.id) })
                            case .budget: BudgetScreen(entries: entries)
                            case .restore: RestoreScreen(makeBackup: makeBackup) { url in restoreURL = url; restoring = true }
                            case .earnings: IncomeScreen(entries: entries, accounts: list) { creating = .income }
                            case .investments:
                                MarketView(accounts: list)
                                LotsPanel(accounts: list).bankTile()
                            case .loans:
                                ProjectsSection(accounts: list)
                                CardPaymentsSection(cards: list.filter { $0.position.debt && !hidden.contains($0.id) })
                                debtSection(list, loans: true)
                            case .receivables: debtSection(list, loans: false)
                            case .capital:
                                PortfolioOverview(accounts: list)
                                PeriodPanel().bankTile()
                                ProfileSection()
                                NotificationsPanel().bankTile()
                                BackupPanel().bankTile()
                            case .home: EmptyView()
                            }
                        }
                    }.padding(Self.pagePadding).frame(maxWidth: 1240).frame(maxWidth: .infinity)
                }.background(canvas)
                #if os(iOS)
                .refreshable { if page == .home { await refreshQuotes(force: true) } }
                #else
                .navigationTitle(page == .home ? "Мои Финансы" : page.rawValue)
                #endif
            }.id(page)
            .overlay(alignment: .bottom) { QuickBackupBar(backup: quickBackup).animation(.snappy, value: quickBackup.phase) }
    }
    #if os(macOS)
    private static let pagePadding: CGFloat = 24
    #else
    private static let pagePadding: CGFloat = 16
    #endif

    #if os(macOS)
    /// The window toolbar: search, quotes and a new operation, the same actions as in the menu bar.
    @ToolbarContentBuilder private var macToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { perform(LedgerCommand.refreshQuotes.rawValue) } label: { Label("Обновить котировки", systemImage: "arrow.clockwise") }
                .help("Обновить котировки металлов и валют (⌘R)").disabled(quotesBusy)
            Button { perform(LedgerCommand.search.rawValue) } label: { Label("Поиск", systemImage: "magnifyingglass") }
                .help("Поиск по счетам и операциям (⌘F)")
            Menu {
                Button("Расход") { creating = .expense }
                Button("Доход") { creating = .income }
                Button("Перевод") { creating = .transfer }
                Divider()
                Button("Импорт выписки…") { importing = true }
            } label: { Label("Новая операция", systemImage: "plus") } primaryAction: { creating = .expense }
                .help("Новая операция (⌘N)")
        }
    }

    /// Commands from the menu bar (see `LedgerCommands`). Sheets are not stacked: a command that opens one
    /// waits until the current sheet is closed.
    private func perform(_ raw: String?) {
        guard let raw else { return }
        if let target = BankPage(rawValue: raw) { query = ""; page = target; return }
        guard let command = LedgerCommand(rawValue: raw) else { return }
        let sheetOpen = importing || creating != nil || editingEntry != nil || selectedAccount != nil || newDebt != nil || restoring || askBackupPassword || askName
        switch command {
        case .search:
            guard !sheetOpen else { return }
            query = ""; page = .home
            Task { @MainActor in await Task.yield(); searchFocused = true }
        case .refreshQuotes:
            page = .home
            Task { await refreshQuotes(force: true) }
        default:
            guard !sheetOpen else { return }
            switch command {
            case .newExpense: creating = .expense
            case .newIncome: creating = .income
            case .newTransfer: creating = .transfer
            case .importStatements: incoming = []; importing = true
            case .backup: makeBackup()
            case .restore: restoreURL = nil; restoring = true
            default: break
            }
        }
    }
    #endif

    private func openPending() {
        #if os(iOS)
        guard !importing, creating == nil, editingEntry == nil, selectedAccount == nil, newDebt == nil else { return }
        let all = ShareInbox.pending()
        if let copy = all.first(where: { $0.pathExtension.lowercased() == "kdfin" }) { restoreURL = copy; restoring = true; return }
        let urls = all
        if !urls.isEmpty { incoming = urls; importing = true }
        #endif
    }

    private func migrateRevision() {
        guard !legacy.isEmpty else { return }
        guard let old = try? JSONDecoder().decode(Revision.self, from: legacy) else {
            // Unreadable data would fail on every launch. Keep the bytes aside and stop retrying.
            UserDefaults.standard.set(legacy, forKey: "portfolio.reconciliation.unreadable")
            legacy = Data()
            problem = "Прежнюю сверку не удалось прочитать. Она сохранена отдельно и больше не переносится."
            return
        }
        do {
            try old.migrate(into: context)
            legacy = Data()
        } catch { context.rollback(); problem = "Не удалось перенести прежнюю сверку." }
    }

    private func tabButton(_ tab: BankPage) -> some View {
        Button {
            query = ""
            page = tab
        } label: {
            #if os(iOS)
            VStack(spacing: 4) {
                Image(systemName: tab.icon).font(.system(size: 18, weight: .semibold))
                Text(tab.rawValue).font(.caption2)
            }.frame(maxWidth: .infinity, minHeight: 44)
            #else
            Label(tab.rawValue, systemImage: tab.icon).font(.headline)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(page == tab ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12))
            #endif
        }.buttonStyle(.plain).foregroundStyle(page == tab ? Palette.accent : Palette.secondary)
        .accessibilityAddTraits(page == tab ? .isSelected : [])
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Поиск по счетам и операциям", text: $query).textFieldStyle(.plain).focused($searchFocused)
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Очистить поиск") }
        }.padding(.horizontal, 15).padding(.vertical, 11).background(.quaternary, in: Capsule())
    }

    @ViewBuilder private func home(_ list: [AccountBalance]) -> some View {
        ReminderBanners(open: { page = .capital }, backup: makeBackup)
        if entries.isEmpty && records.isEmpty && !DemoMode.isOn {
            Button { restoreURL = nil; restoring = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.counterclockwise.icloud").font(.title2).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Начинаете с нуля?").font(.headline)
                        Text("Восстановите всё из резервной копии — файла .kdfin.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }.bankTile(14)
            }.buttonStyle(.plain)
        }
        HStack(alignment: .center) {
            Text("Мои средства").font(.title2.bold())
            Spacer()
            CurrencySwitch(showsRates: false)
        }
        HStack(spacing: 6) {
            if quotesBusy { ProgressView().controlSize(.mini); Text("Обновляю котировки…") }
            else if !quotesNote.isEmpty { Image(systemName: "arrow.triangle.2.circlepath"); Text(quotesNote) }
        }.font(.caption).foregroundStyle(Palette.secondary)
        HStack(alignment: .top, spacing: 10) {
            fundsCard("Деньги на руках", amount: list.filter { liquidAccountKeys.contains($0.id) }.reduce(0) { $0 + $1.position.amount }, icon: "wallet.bifold.fill", color: .blue) { page = .accounts }
            fundsCard("Всего средств", amount: list.filter { !$0.position.debt }.reduce(0) { $0 + $1.position.amount }, icon: "chart.pie.fill", color: .indigo) { page = .capital }
        }
        netWorthCard(list)
        HStack(spacing: 2) {
            quick("Доход", "plus") { creating = .income }
            quick("Расход", "minus") { creating = .expense }
            quick("Перевод", "arrow.right") { creating = .transfer }
            quick("История", "clock.arrow.circlepath") { page = .operations }
        }.padding(.vertical, 3)
        let spent = entries.filter { !$0.income && !$0.transfer && Calendar.current.isDate($0.date, equalTo: .now, toGranularity: .month) }.reduce(Int64.zero) { $0 + $1.cents }
        feed("Операции", "Траты за месяц · " + money(spent), "arrow.left.arrow.right", .orange) { page = .operations }
        feed("Регулярные платежи", "Подписки, связь, аренда · напоминания", BankPage.recurring.icon, .purple) { page = .recurring }
        feed("Бюджет", "План на " + Charity.title(BudgetMath.next(BudgetMath.key(.now))) + " и лимиты", BankPage.budget.icon, .mint) { page = .budget }
        feed("Благотворительность", "К 15-му числу и доплаты", BankPage.charity.icon, .pink) { page = .charity }
        feed("Доходы", "Зарплата, вклады и другие источники", BankPage.earnings.icon, .green) { page = .earnings }
        let debts = list.filter { $0.position.debt && !hidden.contains($0.id) }
        feed("Кредиты", "Кредитные карты и займы · " + display.format(debts.reduce(Int64.zero) { $0 + $1.position.amount }, prices: prices),
             BankPage.loans.icon, .indigo) { page = .loans }
        feed("Инвестиции", "Металлы и криптовалюта", BankPage.investments.icon, .orange) { page = .investments }
        feed("Основные счета", nil, "wallet.bifold", .gray) { page = .accounts }
        feed("Импорт выписки", "Файлы, скриншоты и текст", "doc.viewfinder", .teal) { importing = true }
        feed("Восстановление из копии", "Загрузить файл .kdfin и вернуть все данные", BankPage.restore.icon, .blue) { page = .restore }
        let assets = list.filter { !$0.position.debt }.reduce(Int64.zero) { $0 + $1.position.amount }
        feed(display.format(assets, prices: prices), "Все активы", "chart.pie.fill", .blue) { page = .capital }
        feed("Мне должны", "Выданные займы и возвраты", BankPage.receivables.icon, .teal) { page = .receivables }
        Label("Данные на этом устройстве", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
    }

    /// Everything owned, including what others owe, minus credit cards and other liabilities.
    private func netWorthCard(_ list: [AccountBalance]) -> some View {
        // The same figures as the «Капитал» screen, so both always show one number.
        let summary = CapitalSummary(accounts: list, months: [])
        let net = summary.net
        let rows = NetWorthRows(summary: summary, accounts: list).rows
        return Button { page = .capital } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "scalemass.fill").foregroundStyle(Palette.positive)
                    Text("Чистый капитал").font(.subheadline).foregroundStyle(Palette.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                NetWorthChanges(net: net) { display.format($0, prices: prices) }
                Text(display.format(net, prices: prices)).font(.title2.bold()).monospacedDigit()
                    .foregroundStyle(net < 0 ? Palette.negative : Palette.text).lineLimit(1).minimumScaleFactor(0.55)
                    .contentTransition(.numericText()).accessibilityIdentifier("netWorth")
                ForEach(rows.filter { $0.1 != 0 }, id: \.0) { row in
                    HStack {
                        Text(row.0)
                        Spacer()
                        Text((row.1 < 0 ? "− " : "") + display.format(abs(row.1), prices: prices)).monospacedDigit()
                            .foregroundStyle(row.1 < 0 ? Palette.negative : Palette.text)
                    }.font(.caption)
                }
                Text("Всё, что у тебя есть, включая долги тебе, минус кредитки и другие обязательства.")
                    .font(.caption2).foregroundStyle(Palette.secondary)
            }.bankTile(12).hoverOutline().animation(.snappy, value: displayCode)
        }.buttonStyle(.plain)
    }

    private func fundsCard(_ title: String, amount: Int64, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.subheadline).foregroundStyle(Palette.secondary)
                Text(display.format(amount, prices: prices)).font(.headline).foregroundStyle(Palette.text).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                    .contentTransition(.numericText())
            }.bankTile(12).hoverOutline().animation(.snappy, value: displayCode)
        }.buttonStyle(.plain)
    }

    #if os(macOS)
    private var capitalTrend: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("История капитала").font(.title3.bold())
            if let months = Archive.bundled?.months, let last = months.last {
                Text(money(last.capital)).font(.title2.bold()).monospacedDigit()
                Text(last.title).font(.subheadline).foregroundStyle(.secondary)
                Chart(months.indices, id: \.self) { index in
                    BarMark(x: .value("Месяц", index), y: .value("Рубли", Double(months[index].capital) / 100))
                        .foregroundStyle(index == months.count - 1 ? Color.blue : Color.blue.opacity(0.35))
                        .cornerRadius(3)
                        .accessibilityLabel(months[index].title)
                        .accessibilityValue(money(months[index].capital))
                }.chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 115)
                HStack {
                    Text(months.first?.title ?? "")
                    Spacer()
                    Text(last.title)
                }.font(.caption).foregroundStyle(.secondary)
                Divider()
                Button("Открыть капитал и отчёты") { page = .capital }
            }
        }.bankTile(20)
    }
    #endif

    @ViewBuilder private func debtSection(_ list: [AccountBalance], loans: Bool) -> some View {
        let imported = ["excel-20260901-12", "excel-20260901-13", "excel-20260901-14"]
        let subset = list.filter { !hidden.contains($0.id) && (loans ? $0.position.debt : imported.contains($0.id) || $0.id.hasPrefix("receivable-")) }
        let total = subset.reduce(Int64.zero) { $0 + $1.position.amount }
        VStack(alignment: .leading, spacing: 10) {
            Text(loans ? "Остаток обязательств" : "К возврату").font(.subheadline)
            Text(money(total)).font(.largeTitle.bold())
            Button(loans ? "Добавить кредит" : "Добавить должника") { newDebt = loans ? .loans : .receivables }
        }.bankTile()
        ForEach(subset) { item in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(item.position.title).font(.headline)
                    Spacer()
                    Text(money(item.position.amount)).monospacedDigit()
                }
                if let line = Archive.bundled?.months.last?.lines.first(where: { $0.title == item.position.title }), !line.note.isEmpty {
                    Text("Из отчёта на 01.09.2026 · " + line.note).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("История") { selectedAccount = item }
                    Spacer()
                    Button(loans ? "Записать погашение" : "Записать возврат") {
                        transferSource = loans ? "" : item.id
                        transferTarget = loans ? item.id : ""
                        creating = .transfer
                    }
                }
            }.bankTile()
        }
    }

    private func quick(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.title3.weight(.medium)).frame(width: 48, height: 48)
                    .background(.background, in: Circle()).shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                Text(title).font(.caption)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain)
    }

    private func feed(_ title: String, _ subtitle: String?, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.subheadline.bold()).foregroundStyle(color)
                    .frame(width: 36, height: 36).background(color.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.bankTile(13).hoverOutline()
        }.buttonStyle(.plain)
        .desktopMenu {
            Button("Открыть", action: action)
            if let subtitle { Button("Копировать сумму") { Clipboard.copy(subtitle) } }
        }
    }

    @ViewBuilder private func accountsList(_ list: [AccountBalance]) -> some View {
        ForEach([false, true], id: \.self) { debt in
            let subset = list.filter { $0.position.debt == debt }
            if !subset.isEmpty {
                Text(debt ? "Обязательства" : "Счета и активы").font(.headline)
                ForEach(subset) { account in
                    feed(account.position.title, money(account.position.amount), debt ? "creditcard" : "wallet.bifold", debt ? .indigo : .blue) { selectedAccount = account }
                }
            }
        }
    }

    @ViewBuilder private func searchResults(_ list: [AccountBalance]) -> some View {
        let matched = list.filter { $0.position.title.localizedCaseInsensitiveContains(query) }
        let ids = Set(matched.map(\.id))
        let results = entries.filter { item in
            [item.category, item.note, item.kind].contains(where: { $0.localizedCaseInsensitiveContains(query) }) ||
                item.accountKey.map(ids.contains) == true || item.destinationKey.map(ids.contains) == true
        }
        if matched.isEmpty && results.isEmpty { ContentUnavailableView.search(text: query) }
        accountsList(matched)
        if !results.isEmpty { Text("Операции").font(.headline); operationRows(results, accounts: list) }
    }

    @ViewBuilder private func operationRows(_ rows: [Entry], accounts: [AccountBalance]) -> some View {
        if rows.isEmpty {
            ContentUnavailableView("Пока нет операций", systemImage: "list.bullet.rectangle", description: Text("Добавьте первый доход или расход.")).bankTile()
        } else {
            LazyVStack(spacing: 0) {
                ForEach(rows) { entry in
                    HStack {
                        Button { if entry.lotEventID == nil { editingEntry = entry } } label: {
                            HStack {
                                Image(systemName: entry.transfer ? "arrow.left.arrow.right" : entry.income ? "arrow.down.left" : "arrow.up.right")
                                    .frame(width: 34, height: 34).background(.blue.opacity(0.10), in: Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.category).font(.headline)
                                    let source = accounts.first { $0.id == entry.accountKey }?.position.title ?? "Выбрать счёт"
                                    let destination = accounts.first { $0.id == entry.destinationKey }?.position.title
                                    Text(destination.map { source + " → " + $0 } ?? source).font(.caption)
                                    Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                    if !entry.note.isEmpty { Text(entry.note).font(.caption) }
                                }
                                Spacer()
                                Text((entry.transfer ? "" : entry.income ? "+" : "−") + money(entry.cents)).font(.subheadline.bold())
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { removal = entry } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless).disabled(entry.lotEventID != nil).accessibilityLabel("Удалить операцию")
                            .help("Удалить операцию")
                    }.padding(.vertical, 9).hoverOutline(10, row: true)
                    .desktopMenu {
                        Button("Изменить…") { editingEntry = entry }.disabled(entry.lotEventID != nil)
                        Button("Копировать сумму") { Clipboard.copy(money(entry.cents)) }
                        Divider()
                        Button("Удалить…", role: .destructive) { removal = entry }.disabled(entry.lotEventID != nil)
                    }
                    Divider()
                }
            }.bankTile()
        }
    }
}

struct EntryForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var flow = Flow.expense
    @State private var amount = ""
    @State private var category = Flow.expense.categories[0]
    @State private var date = Date()
    @State private var note = ""
    @State private var failed = false
    let accounts: [AccountBalance]
    let existing: Entry?
    @State private var account: String
    @State private var destination: String
    @State private var charityMonth: Int?
    @State private var includeOverride: Bool?
    @State private var subcategory = ""
    @State private var newSubcategory = ""
    @State private var addingSubcategory = false
    let periods: [Int]
    init(accounts: [AccountBalance], existing: Entry? = nil, initialFlow: Flow = .expense, source: String = "", target: String = "", donation: CharityMonth? = nil, periods: [Int] = []) {
        self.accounts = accounts
        self.periods = periods
        _charityMonth = State(initialValue: existing?.charityMonth ?? donation?.id)
        _includeOverride = State(initialValue: existing?.charityIncluded)
        self.existing = existing
        _flow = State(initialValue: initialFlow)
        _category = State(initialValue: donation == nil ? initialFlow.categories[0] : Charity.category)
        if let donation { _amount = State(initialValue: NSDecimalNumber(decimal: Decimal(donation.remaining) / 100).stringValue) }
        _account = State(initialValue: existing?.accountKey ?? source)
        _destination = State(initialValue: existing?.destinationKey ?? target)
        if let existing {
            _flow = State(initialValue: Flow(rawValue: existing.kind) ?? .expense)
            _amount = State(initialValue: NSDecimalNumber(decimal: Decimal(existing.cents) / 100).stringValue)
            _category = State(initialValue: existing.category)
            _note = State(initialValue: existing.note)
            _date = State(initialValue: existing.date)
            let resolved = Subcategories.resolve(existing)
            _subcategory = State(initialValue: resolved == Subcategories.none ? "" : resolved)
        }
    }
    private var validAccounts: Bool {
        accounts.contains { $0.id == account } &&
        (flow != .transfer || (account != destination && accounts.contains { $0.id == destination }))
    }
    private var cents: Int64? {
        let normalized = amount.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard normalized.wholeMatch(of: /[0-9]{1,10}(\.[0-9]{1,2})?/) != nil,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        return NSDecimalNumber(decimal: value * 100).int64Value
    }
    var body: some View {
        NavigationStack {
            Form {
                if let digest = existing?.sourceDigest {
                    SourceLink(digest: digest)
                }
                if existing?.summaryStart != nil {
                    Text("Остаток банковской сводки после сверки с детализацией").font(.caption)
                }
                Picker("Тип операции", selection: $flow) {
                    ForEach(Flow.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).onChange(of: flow) { _, next in category = next.categories[0] }
                Picker(flow == .transfer ? "Откуда" : "Счёт", selection: $account) {
                    Text("Выберите счёт").tag("")
                    ForEach(accounts) { Text($0.position.title).tag($0.id) }
                }.onChange(of: account) { _, newAccount in
                    if newAccount == destination { destination = "" }
                }
                if flow == .transfer {
                    Picker("Куда", selection: $destination) {
                        Text("Выберите счёт").tag("")
                        ForEach(accounts.filter { $0.id != account }) { Text($0.position.title).tag($0.id) }
                    }
                }
                TextField("Сумма, ₽", text: $amount)
                #if os(iOS)
                    .keyboardType(.decimalPad)
                #endif
                Picker("Категория", selection: $category) {
                    ForEach(flow.categories.contains(category) ? flow.categories : flow.categories + [category], id: \.self) { Text($0) }
                }
                .onChange(of: category) { _, _ in includeOverride = nil; subcategory = ""; addingSubcategory = false }
                if flow == .expense && !Charity.isDonation(category) {
                    let options = Subcategories.list(for: category)
                    Picker("Подкатегория", selection: $subcategory) {
                        Text(Subcategories.none).tag("")
                        ForEach(options.contains(subcategory) || subcategory.isEmpty ? options : options + [subcategory], id: \.self) { Text($0).tag($0) }
                    }.disabled(addingSubcategory)
                    Toggle("Новая подкатегория", isOn: $addingSubcategory)
                    if addingSubcategory { TextField("Название подкатегории", text: $newSubcategory) }
                }
                DatePicker("Дата", selection: $date, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                if flow == .expense && Charity.isDonation(category) {
                    Picker("За какой месяц", selection: $charityMonth) {
                        Text("Без привязки").tag(nil as Int?)
                        ForEach(Charity.options(date: date, periods: periods, selected: charityMonth), id: \.self) { key in
                            Text(Charity.title(key)).tag(Optional(key))
                        }
                    }
                } else if flow != .transfer {
                    Toggle(flow == .income ? "Считать заработком для благотворительности" : "Вычесть из заработка для благотворительности", isOn: Binding(
                        get: { includeOverride ?? Charity.includes(flow, category) }, set: { includeOverride = $0 }))
                }
                TextField("Заметка", text: $note)
            }.formStyle(.grouped).navigationTitle(existing == nil ? "Новая операция" : "Изменить операцию")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить") {
                    guard let cents, validAccounts else { return }
                    let entry = existing ?? Entry(cents: cents, flow: flow, category: category, note: note, date: date)
                    entry.cents = cents
                    entry.kind = flow.rawValue
                    entry.category = category
                    entry.charityMonth = flow == .expense && Charity.isDonation(category) ? charityMonth : nil
                    entry.charityIncluded = flow == .transfer || (flow == .expense && Charity.isDonation(category)) ? nil : includeOverride
                    entry.note = note
                    entry.date = date
                    entry.accountKey = account
                    entry.destinationKey = flow == .transfer ? destination : nil
                    let created = newSubcategory.trimmingCharacters(in: .whitespacesAndNewlines)
                    if flow == .expense && addingSubcategory && !created.isEmpty {
                        Subcategories.add(created, to: category)
                        entry.subcategory = created
                    } else {
                        entry.subcategory = flow == .expense && !subcategory.isEmpty ? subcategory : nil
                    }
                    if existing == nil { context.insert(entry) }
                    do { try context.save(); dismiss() } catch { context.rollback(); failed = true }
                }.disabled(cents == nil || !validAccounts || (flow == .expense && Charity.isDonation(category) && (charityMonth ?? 0) >= Charity.key(date))) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 340)
        #endif
        .alert("Не удалось сохранить операцию", isPresented: $failed) { Button("ОК") {} }
    }
}

#if SNAPSHOTS && os(macOS)
/// Only in a screenshot build (`SWIFT_ACTIVE_COMPILATION_CONDITIONS=SNAPSHOTS`): walks the sections and saves
/// the window as PNG files into the app’s temporary folder when launched with `-snapshots YES`. Never compiled into the real app.
enum WindowSnapshots {
    @MainActor static func run() {
        guard UserDefaults.standard.bool(forKey: "snapshots") else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snapshots").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            @MainActor func main() -> NSWindow? { NSApp.windows.first { $0.frame.width >= 700 } }
            @MainActor func shot(_ name: String, _ window: NSWindow?) {
                // The window's own pixels through the system compositor (an app may read its own windows).
                typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                guard let window, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
                let capture = unsafeBitCast(symbol, to: Capture.self)
                guard let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue() else { return }
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
            for _ in 0..<60 where main() == nil { try? await Task.sleep(for: .milliseconds(500)) }
            // Visible on whichever desktop is in front, so the compositor has its pixels.
            main()?.collectionBehavior.insert(.canJoinAllSpaces)
            main()?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .seconds(2))
            if !DemoMode.isOn { shot("00-lock", main()); return }
            let pages = BankPage.sidebar.flatMap(\.pages)
            for (i, page) in pages.enumerated() {
                LedgerCommand.send(page.rawValue)
                try? await Task.sleep(for: .seconds(2))
                shot(String(format: "%02d", i + 1), main())
            }
            LedgerCommand.send(BankPage.home.rawValue)
            let before = main()
            if let menu = NSApp.mainMenu?.items.first?.submenu, let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                menu.performActionForItem(at: index)
            }
            try? await Task.sleep(for: .seconds(1))
            NSApp.windows.first { $0.isVisible && $0 !== before }?.collectionBehavior.insert(.canJoinAllSpaces)
            NSApp.windows.first { $0.isVisible && $0 !== before }?.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1))
            shot("20-settings", NSApp.windows.first { $0.isVisible && $0 !== before && $0.frame.width > 300 })
        }
    }
}
#endif
