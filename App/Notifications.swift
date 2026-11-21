import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// UserDefaults keys shared by the notifications section, the banners and the scheduler.
enum ReminderKeys {
    static let enabled = "notify.enabled"
    static let backup = "notify.backup"
    static let signing = "notify.signing"
    static let charity = "notify.charity"
    /// Minutes after midnight for the backup and signing reminders.
    static let serviceTime = "notify.serviceMinutes"
    static let charityTime = "notify.charityMinutes"
    static let payments = "notify.payments"
    static let projects = "notify.projectsEnabled"
    static let recurring = "notify.recurringEnabled"
    /// Seconds since 1970 of the last successful encrypted copy (manual or automatic); 0 means never.
    static let lastBackup = "backup.lastSuccess"
}

enum ReminderRoute: String { case backup, signing, charity, payment, project, recurring }

/// A credit card deadline: the amount that keeps the grace period, and the minimum if the bank set one.
struct PaymentDue: Codable, Equatable, Identifiable {
    static let storageKey = "notify.payments.list"
    let id: String
    let title: String
    let amount: Int64
    let minimum: Int64?
    let due: Date

    static var stored: [PaymentDue] {
        UserDefaults.standard.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([PaymentDue].self, from: $0) } ?? []
    }
}

struct PlannedReminder: Equatable {
    enum When: Equatable { case date(Date), monthly(day: Int, minutes: Int) }
    let id: String
    let title: String
    let body: String
    let route: ReminderRoute
    let when: When
}

/// Scheduling rules without UserNotifications, so tests can check dates, texts and identifiers.
enum ReminderPlan {
    static let prefix = "kd."
    /// The owner asked for a backup reminder once every two weeks.
    static let backupInterval = 14
    static let backupRepeats = 4
    static let charityDays = [8, 12, 13]
    static let locale = Locale(identifier: "ru_RU")

    static func at(_ minutes: Int, on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }

    static func days(_ n: Int) -> String {
        let tail = n % 100, last = n % 10
        let word = (11...14).contains(tail) ? "дней" : last == 1 ? "день" : (2...4).contains(last) ? "дня" : "дней"
        return String(n) + " " + word
    }

    static func months(_ n: Int) -> String {
        let tail = n % 100, last = n % 10
        let word = (11...14).contains(tail) ? "месяцев" : last == 1 ? "месяц" : (2...4).contains(last) ? "месяца" : "месяцев"
        return String(n) + " " + word
    }

    static func describe(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    // MARK: Signing

    /// Two days and one day before, and on the day itself; an expiry earlier than the chosen time
    /// gets its last warning at 21:00 the evening before instead.
    static func signing(expiry: Date, now: Date, minutes: Int, calendar: Calendar) -> [PlannedReminder] {
        let day = calendar.startOfDay(for: expiry)
        func shifted(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: day) ?? day }
        var dates = [at(minutes, on: shifted(2), calendar: calendar), at(minutes, on: shifted(1), calendar: calendar)]
        let sameDay = at(minutes, on: day, calendar: calendar)
        dates.append(sameDay < expiry ? sameDay : at(21 * 60, on: shifted(1), calendar: calendar))
        let body = "Подпись приложения истекает " + describe(expiry, calendar: calendar)
            + ". Подключите iPhone к Mac и переустановите приложение — данные сохранятся."
        return Set(dates).sorted().filter { $0 > now && $0 < expiry }.enumerated().map { index, date in
            PlannedReminder(id: prefix + "signing." + String(index), title: "Продлите подпись «Мои Финансы»",
                            body: body, route: .signing, when: .date(date))
        }
    }

    static func signingSoon(expiry: Date?, now: Date) -> Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSince(now) < 3 * 86_400
    }

    // MARK: Backup

    static func backupDue(last: Date?, now: Date, calendar: Calendar) -> Date {
        guard let last else { return now }
        return calendar.date(byAdding: .day, value: backupInterval, to: last) ?? now
    }
    static func backupOverdue(last: Date?, now: Date, calendar: Calendar) -> Bool {
        now >= backupDue(last: last, now: now, calendar: calendar)
    }
    static func backupMessage(last: Date?, at date: Date, calendar: Calendar) -> String {
        guard let last else { return "Резервная копия ещё ни разу не создавалась. Сделайте копию, чтобы не потерять данные." }
        let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: date)).day ?? 0
        return "Резервной копии не было " + days(max(age, 1)) + ". Сделайте копию, чтобы не потерять данные."
    }

    /// The first reminder at the chosen time once a copy is overdue, then every two weeks while it stays overdue.
    static func backup(last: Date?, now: Date, minutes: Int, calendar: Calendar) -> [PlannedReminder] {
        let base = max(backupDue(last: last, now: now, calendar: calendar), now.addingTimeInterval(60))
        var first = at(minutes, on: base, calendar: calendar)
        if first < base { first = at(minutes, on: calendar.date(byAdding: .day, value: 1, to: base) ?? base, calendar: calendar) }
        return (0..<backupRepeats).map { week in
            let date = calendar.date(byAdding: .day, value: backupInterval * week, to: first) ?? first
            return PlannedReminder(id: prefix + "backup." + String(week), title: "Пора сделать резервную копию",
                                   body: backupMessage(last: last, at: date, calendar: calendar), route: .backup, when: .date(date))
        }
    }

    // MARK: Charity

    static func charity(minutes: Int) -> [PlannedReminder] {
        charityDays.map { day in
            PlannedReminder(id: prefix + "charity." + String(day), title: "Благотворительность",
                            body: "Проверь сумму перечисления к 15-му числу.", route: .charity, when: .monthly(day: day, minutes: minutes))
        }
    }

    // MARK: Credit cards

    /// Three days and one day before each deadline, at the chosen time.
    static func payments(_ list: [PaymentDue], now: Date, minutes: Int, calendar: Calendar) -> [PlannedReminder] {
        list.sorted { $0.due < $1.due }.flatMap { item -> [PlannedReminder] in
            let day = calendar.startOfDay(for: item.due)
            let dateText = item.due.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
            // No amounts: notifications are visible on the locked screen while the app itself is behind a PIN.
            var body = "Срок — " + dateText + ", чтобы не платить проценты."
            if item.minimum != nil { body += " Есть минимальный платёж." }
            body += " Сумма — в приложении."
            return [3, 1].compactMap { before in
                guard let shifted = calendar.date(byAdding: .day, value: -before, to: day) else { return nil }
                let date = at(minutes, on: shifted, calendar: calendar)
                guard date > now else { return nil }
                return PlannedReminder(id: prefix + "pay." + item.id + "." + String(before),
                                       title: item.title + (before == 1 ? ": платёж завтра" : ": платёж через 3 дня"),
                                       body: body, route: .payment, when: .date(date))
            }
        }
    }

    // MARK: Projects

    static func projects(_ titles: [String], minutes: Int) -> [PlannedReminder] {
        guard !titles.isEmpty else { return [] }
        let names = titles.map { "«" + $0 + "»" }.joined(separator: ", ")
        return [PlannedReminder(id: prefix + "project.monthly", title: "Запиши экономию за месяц",
                                body: "Проект " + names + ": сколько удалось сэкономить в прошлом месяце? Внеси сумму во вкладке «Кредиты».",
                                route: .project, when: .monthly(day: 1, minutes: minutes))]
    }

    // MARK: Regular payments

    /// The day before and the day of the next payment, at the chosen time.
    static func recurring(_ list: [RecurringDue], now: Date, minutes: Int, calendar: Calendar) -> [PlannedReminder] {
        list.sorted { $0.due < $1.due }.flatMap { item -> [PlannedReminder] in
            let day = calendar.startOfDay(for: item.due)
            return [1, 0].compactMap { before in
                guard let shifted = calendar.date(byAdding: .day, value: -before, to: day) else { return nil }
                let date = at(minutes, on: shifted, calendar: calendar)
                guard date > now else { return nil }
                return PlannedReminder(id: prefix + "reg." + item.id + "." + String(before),
                                       title: item.title + (before == 1 ? ": оплата завтра" : ": оплата сегодня"),
                                       body: "Отметь оплату в разделе «Регулярные платежи».", route: .recurring, when: .date(date))
            }
        }
    }

    struct Settings {
        var recurring = true
        var backup = true, signing = true, charity = false, payments = true, projects = true
        var serviceMinutes = 10 * 60, charityMinutes = 12 * 60
    }

    static func all(_ settings: Settings, lastBackup: Date?, expiry: Date?, now: Date, calendar: Calendar,
                    payments list: [PaymentDue] = [], projects titles: [String] = [], recurring regular: [RecurringDue] = []) -> [PlannedReminder] {
        var plan = [PlannedReminder]()
        if settings.recurring { plan += recurring(regular, now: now, minutes: settings.serviceMinutes, calendar: calendar) }
        if settings.payments { plan += payments(list, now: now, minutes: settings.serviceMinutes, calendar: calendar) }
        if settings.projects { plan += projects(titles, minutes: settings.serviceMinutes) }
        if settings.signing, let expiry { plan += signing(expiry: expiry, now: now, minutes: settings.serviceMinutes, calendar: calendar) }
        if settings.backup { plan += backup(last: lastBackup, now: now, minutes: settings.serviceMinutes, calendar: calendar) }
        if settings.charity { plan += charity(minutes: settings.charityMinutes) }
        return plan
    }
}

/// Expiry date of the provisioning profile the installed build was signed with (iOS only).
enum SigningProfile {
    static let expiry: Date? = {
        #if os(iOS)
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
        #else
        return nil
        #endif
    }()

    /// The profile is a CMS envelope around an XML property list.
    static func parse(_ data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }
}

enum BackupLog {
    static var last: Date? {
        let defaults = UserDefaults.standard
        let manual = defaults.double(forKey: ReminderKeys.lastBackup)
        let dates = [manual > 0 ? Date(timeIntervalSince1970: manual) : nil,
                     defaults.object(forKey: "phoneBackup.last") as? Date].compactMap { $0 }
        return dates.max()
    }
    @MainActor static func record(_ date: Date = .now) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: ReminderKeys.lastBackup)
        Task { await Reminders.reschedule() }
    }
}

/// Shows banners while the app is open and remembers which screen a tapped notification asks for.
@MainActor final class NotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    @Published var route: ReminderRoute?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo["route"] as? String
        Task { @MainActor in self.route = raw.flatMap(ReminderRoute.init) }
        completionHandler()
    }
}

@MainActor enum Reminders {
    static let legacyCharity = ReminderPlan.charityDays.map { "charity.monthly." + String($0) }
    static let testID = "notify.test"

    static var settings: ReminderPlan.Settings {
        let d = UserDefaults.standard
        var s = ReminderPlan.Settings()
        s.backup = d.object(forKey: ReminderKeys.backup) as? Bool ?? true
        s.signing = d.object(forKey: ReminderKeys.signing) as? Bool ?? true
        s.charity = d.object(forKey: ReminderKeys.charity) as? Bool ?? false
        s.payments = d.object(forKey: ReminderKeys.payments) as? Bool ?? true
        s.projects = d.object(forKey: ReminderKeys.projects) as? Bool ?? true
        s.recurring = d.object(forKey: ReminderKeys.recurring) as? Bool ?? true
        s.serviceMinutes = d.object(forKey: ReminderKeys.serviceTime) as? Int ?? 10 * 60
        s.charityMinutes = d.object(forKey: ReminderKeys.charityTime) as? Int ?? 12 * 60
        return s
    }

    static func allowed(_ status: UNAuthorizationStatus) -> Bool { status == .authorized || status == .provisional }

    /// Asks iOS for permission (the system dialog appears only the first time) and turns notifications on.
    static func enable() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        UserDefaults.standard.set(granted, forKey: ReminderKeys.enabled)
        await reschedule()
        return granted
    }

    /// Replaces every pending reminder of the app with the current plan: on launch, on return to the
    /// app, after a backup and after any change in the notifications section.
    static func reschedule(now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        let defaults = UserDefaults.standard
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        // Charity reminders made by the previous version keep working under the new switch.
        if defaults.object(forKey: ReminderKeys.charity) == nil, pending.contains(legacyCharity[0]) {
            defaults.set(true, forKey: ReminderKeys.charity)
            defaults.set(true, forKey: ReminderKeys.enabled)
        }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.hasPrefix(ReminderPlan.prefix) || legacyCharity.contains($0) })
        let status = await center.notificationSettings().authorizationStatus
        guard defaults.bool(forKey: ReminderKeys.enabled), allowed(status) else { return }
        let calendar = Calendar.autoupdatingCurrent
        let plan = ReminderPlan.all(settings, lastBackup: BackupLog.last, expiry: SigningProfile.expiry, now: now, calendar: calendar,
                                   payments: PaymentDue.stored, projects: defaults.stringArray(forKey: SavingsProject.activeKey) ?? [],
                                   recurring: defaults.data(forKey: RecurringDue.storageKey).flatMap { try? JSONDecoder().decode([RecurringDue].self, from: $0) } ?? [])
        // iOS keeps at most 64 pending requests per app; the plan is far below that, but never exceed it.
        for item in plan.prefix(60) {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.userInfo = ["route": item.route.rawValue]
            content.threadIdentifier = item.route.rawValue
            let trigger: UNNotificationTrigger
            switch item.when {
            case .date(let date):
                trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
            case .monthly(let day, let minutes):
                trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(day: day, hour: minutes / 60, minute: minutes % 60), repeats: true)
            }
            try? await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
        }
    }

    static func sendTest() async throws {
        let content = UNMutableNotificationContent()
        content.title = "Мои Финансы"
        content.body = "Тестовое уведомление: уведомления работают."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: testID, content: content, trigger: trigger))
    }

    static func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
        #endif
    }
}

/// Warnings at the top of the home screen; tapping one opens the backup and notifications section.
struct ReminderBanners: View {
    @AppStorage(ReminderKeys.lastBackup) private var lastBackup = 0.0
    @Environment(\.scenePhase) private var phase
    @State private var now = Date.now
    let open: () -> Void
    /// Tapping «Нужна резервная копия» makes a copy right away.
    var backup: (() -> Void)? = nil
    var body: some View {
        let calendar = Calendar.autoupdatingCurrent
        let last = lastBackup >= 0 ? BackupLog.last : nil
        VStack(spacing: 8) {
            if ReminderPlan.signingSoon(expiry: SigningProfile.expiry, now: now), let expiry = SigningProfile.expiry {
                banner(icon: "exclamationmark.shield.fill", color: .orange, title: expiry > now ? "Подпись скоро истекает" : "Подпись истекла",
                       text: "Действует до " + ReminderPlan.describe(expiry, calendar: calendar) + ". Подключите iPhone к Mac и переустановите приложение — данные сохранятся.")
            }
            if ReminderPlan.backupOverdue(last: last, now: now, calendar: calendar) {
                banner(icon: "externaldrive.badge.exclamationmark", color: Palette.negative, title: "Нужна резервная копия",
                       text: ReminderPlan.backupMessage(last: last, at: now, calendar: calendar) + (backup == nil ? "" : " Нажмите — копия сделается сейчас."),
                       action: backup ?? open)
            }
        }.onChange(of: phase) { _, next in if next == .active { now = .now } }
    }
    private func banner(icon: String, color: Color, title: String, text: String, action: (() -> Void)? = nil) -> some View {
        Button(action: action ?? open) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }.bankTile(14)
        }.buttonStyle(.plain)
    }
}

/// The notifications section on the «Капитал» page.
struct NotificationsPanel: View {
    @AppStorage(ReminderKeys.enabled) private var enabled = false
    @AppStorage(ReminderKeys.backup) private var backup = true
    @AppStorage(ReminderKeys.signing) private var signing = true
    @AppStorage(ReminderKeys.charity) private var charity = false
    @AppStorage(ReminderKeys.payments) private var payments = true
    @AppStorage(ReminderKeys.projects) private var projects = true
    @AppStorage(ReminderKeys.recurring) private var recurringOn = true
    @AppStorage(ReminderKeys.serviceTime) private var serviceMinutes = 10 * 60
    @AppStorage(ReminderKeys.charityTime) private var charityMinutes = 12 * 60
    @Environment(\.scenePhase) private var phase
    @State private var status = UNAuthorizationStatus.notDetermined
    @State private var upcoming = [(title: String, date: Date)]()
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Уведомления").font(.headline)
            Toggle("Уведомления от приложения", isOn: Binding(get: { enabled && Reminders.allowed(status) }, set: switchAll))
                .disabled(busy)
            statusLine
            if enabled && Reminders.allowed(status) {
                Toggle("Резервная копия раз в 2 недели", isOn: $backup)
                if let expiry = SigningProfile.expiry {
                    Toggle("Окончание подписи приложения", isOn: $signing)
                    Text("Подпись действует до " + ReminderPlan.describe(expiry, calendar: .autoupdatingCurrent)
                         + ". Напоминания придут за 2 дня, за день и в последний день.").font(.caption).foregroundStyle(.secondary)
                }
                if !PaymentDue.stored.isEmpty {
                    Toggle("Платежи по кредиткам: за 3 дня и за день", isOn: $payments)
                }
                if !(UserDefaults.standard.stringArray(forKey: SavingsProject.activeKey) ?? []).isEmpty {
                    Toggle("Проекты: записать экономию 1-го числа", isOn: $projects)
                }
                Toggle("Регулярные платежи: накануне и в день оплаты", isOn: $recurringOn)
                DatePicker("Время напоминаний", selection: clock($serviceMinutes), displayedComponents: .hourAndMinute)
                Toggle("Благотворительность: 8, 12 и 13 числа", isOn: $charity)
                if charity { DatePicker("Время для благотворительности", selection: clock($charityMinutes), displayedComponents: .hourAndMinute) }
                Button("Отправить тестовое уведомление") {
                    Task {
                        do { try await Reminders.sendTest(); message = "Уведомление придёт через 5 секунд — можно свернуть приложение." }
                        catch { message = "Не удалось отправить: " + error.localizedDescription }
                    }
                }.buttonStyle(.bordered)
                if !upcoming.isEmpty {
                    Text("Ближайшие").font(.subheadline.weight(.semibold))
                    ForEach(Array(upcoming.prefix(8).enumerated()), id: \.offset) { _, item in
                        LabeledContent(item.title, value: item.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: ReminderPlan.locale)))
                            .font(.caption)
                    }
                }
            }
            if !message.isEmpty { Text(message).font(.caption) }
        }
        .task { await refresh(reschedule: true) }
        .onChange(of: phase) { _, next in if next == .active { Task { await refresh(reschedule: false) } } }
        .onChange(of: backup) { _, _ in Task { await refresh(reschedule: true) } }
        .onChange(of: signing) { _, _ in Task { await refresh(reschedule: true) } }
        .onChange(of: charity) { _, _ in Task { await refresh(reschedule: true) } }
        .onChange(of: payments) { _, _ in Task { await refresh(reschedule: true) } }
        .onChange(of: projects) { _, _ in Task { await refresh(reschedule: true) } }
        .onChange(of: recurringOn) { _, _ in Task { await refresh(reschedule: true) } }
        .onChange(of: serviceMinutes) { _, _ in Task { await refresh(reschedule: true) } }
        .onChange(of: charityMinutes) { _, _ in Task { await refresh(reschedule: true) } }
    }

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .denied:
            Text("Уведомления запрещены в настройках системы. Разрешите их для «Мои Финансы».").font(.caption)
            Button("Открыть настройки уведомлений") { Reminders.openSystemSettings() }.buttonStyle(.bordered)
        case .notDetermined:
            Text("Включите, чтобы получать напоминания о резервной копии, подписи приложения и благотворительности. Уведомления создаются на самом устройстве и работают без интернета.")
                .font(.caption).foregroundStyle(.secondary)
        default:
            Text(enabled ? "Разрешено в настройках системы." : "Разрешено в настройках системы, но выключено здесь.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func switchAll(_ on: Bool) {
        busy = true
        Task {
            defer { busy = false }
            if on {
                if status == .denied { Reminders.openSystemSettings(); return }
                message = await Reminders.enable() ? "" : "Без разрешения уведомления не придут. Разрешите их в настройках."
            } else {
                enabled = false
                await Reminders.reschedule()
            }
            await refresh(reschedule: false)
        }
    }

    private func refresh(reschedule: Bool) async {
        let center = UNUserNotificationCenter.current()
        status = await center.notificationSettings().authorizationStatus
        if reschedule { await Reminders.reschedule() }
        let pending = await center.pendingNotificationRequests()
        upcoming = pending.compactMap { request -> (title: String, date: Date)? in
            let next = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            return next.map { (request.content.title, $0) }
        }.sorted { $0.date < $1.date }
    }

    private func clock(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: { ReminderPlan.at(minutes.wrappedValue, on: .now, calendar: .current) },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) })
    }
}

/// The switch on the charity page uses the same setting as the notifications section.
struct CharityReminders: View {
    @AppStorage(ReminderKeys.charity) private var charity = false
    @AppStorage(ReminderKeys.enabled) private var enabled = false
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Напоминать 8, 12 и 13 числа", isOn: Binding(get: { charity && enabled }, set: { on in
                charity = on
                Task {
                    if on && !enabled { message = await Reminders.enable() ? "" : "Разреши уведомления в настройках." }
                    else { await Reminders.reschedule() }
                }
            }))
            Text(message.isEmpty ? "Время меняется в разделе «Уведомления» на вкладке «Капитал»." : message).font(.caption)
        }
    }
}

/// Upcoming credit card payments on the «Кредиты» page: add new deadlines, mark paid, remove.
/// Reminders 3 days and 1 day before follow the list.
struct CardPaymentsSection: View {
    let cards: [AccountBalance]
    @AppStorage(PaymentDue.storageKey) private var stored = Data()
    @State private var adding = false
    private var list: [PaymentDue] { ((try? JSONDecoder().decode([PaymentDue].self, from: stored)) ?? []).sorted { $0.due < $1.due } }
    private func save(_ items: [PaymentDue]) {
        stored = (try? JSONEncoder().encode(items)) ?? Data()
        Task { await Reminders.reschedule() }
    }
    var body: some View {
        let today = Calendar.autoupdatingCurrent.startOfDay(for: .now)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Платежи по кредиткам", systemImage: "calendar.badge.clock").font(.headline)
                Spacer()
                Button("Добавить") { adding = true }.buttonStyle(.bordered)
            }
            if list.isEmpty {
                Text("Добавь срок и сумму из приложения банка — придут напоминания за 3 дня и за день.").font(.caption).foregroundStyle(Palette.secondary)
            }
            ForEach(list) { item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Text("до " + item.due.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month(.wide))
                             + (item.minimum.map { " · минимум " + money($0) } ?? ""))
                            .font(.caption).foregroundStyle(item.due < today ? Palette.negative : Palette.secondary)
                    }
                    Spacer()
                    Text(money(item.amount)).monospacedDigit()
                    Menu {
                        Button("Оплачено — убрать") { save(list.filter { $0.id != item.id }) }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Действия с платежом")
                }
                Divider()
            }
        }.bankTile()
        .sheet(isPresented: $adding) { CardPaymentForm(cards: cards) { save(list + [$0]) } }
    }
}

private struct CardPaymentForm: View {
    let cards: [AccountBalance]
    let add: (PaymentDue) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var amount = ""
    @State private var minimum = ""
    @State private var due = Date.now
    var body: some View {
        NavigationStack {
            Form {
                Picker("Карта", selection: $title) {
                    Text("Выберите карту").tag("")
                    ForEach(cards) { Text($0.position.title).tag($0.position.title) }
                }
                TextField("Сумма без процентов, ₽", text: $amount)
                TextField("Минимальный платёж, ₽ (необязательно)", text: $minimum)
                DatePicker("Оплатить до", selection: $due, in: Date.now..., displayedComponents: .date)
            }.formStyle(.grouped).navigationTitle("Платёж по кредитке")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        guard let cents = IncomeMath.positive(amount) else { return }
                        let noon = Calendar.autoupdatingCurrent.date(bySettingHour: 12, minute: 0, second: 0, of: due) ?? due
                        add(PaymentDue(id: UUID().uuidString, title: title, amount: cents, minimum: IncomeMath.positive(minimum), due: noon))
                        dismiss()
                    }.disabled(title.isEmpty || IncomeMath.positive(amount) == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 300)
        #endif
    }
}
