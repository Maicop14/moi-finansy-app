import SwiftUI
import SwiftData

/// A purchase repaid to oneself: the money sits on its own account (counted in assets like any money),
/// and monthly contributions record the savings the purchase made possible. Net worth does not change.
struct SavingsProject: Codable, Identifiable, Equatable {
    static let kind = "project"
    /// Titles of projects that still have a remaining amount, for the monthly reminder.
    static let activeKey = "notify.projects"
    let id: UUID
    var title: String
    var total: Int64
    var months: Int
    /// yyyymm of the first scheduled month.
    var firstMonth: Int
    /// The account the money stays on.
    var accountKey: String

    var monthly: Int64 { months > 0 ? total / Int64(months) : total }
    var schedule: [(month: Int, planned: Int64)] {
        (0..<max(months, 0)).map { index in
            let date = Charity.calendar.date(byAdding: .month, value: index, to: Charity.start(firstMonth))!
            // The last month takes any rounding remainder.
            let planned = index == months - 1 ? total - monthly * Int64(months - 1) : monthly
            return (Charity.key(date), planned)
        }
    }
}

struct ProjectContribution: Codable, Identifiable, Equatable {
    static let kind = "projectpay"
    let id: UUID
    let project: UUID
    let date: Date
    let cents: Int64
    let note: String
}

struct ProjectProgress: Equatable {
    let saved: Int64
    let remaining: Int64
    /// What the schedule expects to be saved by the end of the current month.
    let expected: Int64
    /// Positive when ahead of the schedule, negative when behind.
    var lead: Int64 { saved - expected }
    let monthsLeft: Int
    let paidByMonth: [Int: Int64]

    init(_ project: SavingsProject, contributions: [ProjectContribution], today: Date) {
        let mine = contributions.filter { $0.project == project.id }
        saved = mine.reduce(0) { $0 + $1.cents }
        remaining = max(0, project.total - saved)
        let current = Charity.key(today)
        expected = min(project.total, project.schedule.filter { $0.month <= current }.reduce(0) { $0 + $1.planned })
        paidByMonth = mine.reduce(into: [:]) { $0[Charity.key($1.date), default: 0] += $1.cents }
        monthsLeft = remaining == 0 ? 0 : project.schedule.filter { $0.month >= current }.count
    }
}

enum ProjectStore {
    static func projects(_ records: [FinanceRecord]) -> [SavingsProject] {
        records.filter { $0.kind == SavingsProject.kind }.compactMap { try? JSONDecoder().decode(SavingsProject.self, from: $0.payload) }
    }
    static func contributions(_ records: [FinanceRecord]) -> [ProjectContribution] {
        records.filter { $0.kind == ProjectContribution.kind }.compactMap { try? JSONDecoder().decode(ProjectContribution.self, from: $0.payload) }
    }
    /// Keeps the reminder list in step with the projects that still have something left.
    static func syncReminders(_ records: [FinanceRecord], today: Date = .now) {
        let all = contributions(records)
        let active = projects(records).filter { ProjectProgress($0, contributions: all, today: today).remaining > 0 }.map(\.title)
        let defaults = UserDefaults.standard
        if defaults.stringArray(forKey: SavingsProject.activeKey) != active {
            defaults.set(active, forKey: SavingsProject.activeKey)
            Task { @MainActor in await Reminders.reschedule() }
        }
    }
}

/// Cards for every project, shown on the «Кредиты» page above bank debts.
struct ProjectsSection: View {
    let accounts: [AccountBalance]
    @Query private var records: [FinanceRecord]
    @State private var contributing: SavingsProject?
    var body: some View {
        let all = ProjectStore.contributions(records)
        Group {
            ForEach(ProjectStore.projects(records)) { project in
                ProjectCard(project: project, contributions: all, accounts: accounts) { contributing = project }
            }
        }
        .sheet(item: $contributing) { ContributionForm(project: $0) }
        .onAppear { ProjectStore.syncReminders(records) }
        .onChange(of: records.count) { _, _ in ProjectStore.syncReminders(records) }
    }
}

private struct ProjectCard: View {
    let project: SavingsProject
    let contributions: [ProjectContribution]
    let accounts: [AccountBalance]
    let contribute: () -> Void
    @State private var showSchedule = false

    var body: some View {
        let today = Date.now
        let progress = ProjectProgress(project, contributions: contributions, today: today)
        let current = Charity.key(today)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Проект: " + project.title.lowercased(), systemImage: "cup.and.saucer.fill").font(.headline)
                Spacer()
                Text("свой").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.positive.opacity(0.14), in: Capsule()).foregroundStyle(Palette.positive)
            }
            Text("Рассрочка самому себе · не банковский долг, капитал не уменьшает").font(.caption).foregroundStyle(.secondary)
            if let account = accounts.first(where: { $0.id == project.accountKey }) {
                LabeledContent("На счёте «" + account.position.title + "»", value: money(account.position.amount)).font(.subheadline)
            }
            LabeledContent("Долг проекту") { Text(money(progress.remaining)).font(.title2.bold()).monospacedDigit() }
            ProgressView(value: Double(progress.saved), total: Double(max(project.total, 1))).tint(Palette.positive)
            HStack {
                Text("Сэкономлено " + money(progress.saved) + " из " + money(project.total))
                Spacer()
                Text(progress.monthsLeft == 0 ? "Готово" : "Осталось " + ReminderPlan.months(progress.monthsLeft))
            }.font(.caption)
            if current >= project.firstMonth && progress.remaining > 0 {
                Text(progress.lead >= 0 ? "Опережение графика: " + money(progress.lead) : "Отставание от графика: " + money(-progress.lead))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(progress.lead >= 0 ? Palette.positive : Palette.negative)
            } else if progress.remaining > 0 {
                Text("Первый взнос — " + Charity.title(project.firstMonth) + ", по " + money(project.monthly) + " в месяц").font(.subheadline)
            }
            DisclosureGroup("График на " + ReminderPlan.months(project.months), isExpanded: $showSchedule) {
                ForEach(project.schedule, id: \.month) { item in
                    let paid = progress.paidByMonth[item.month] ?? 0
                    HStack {
                        Image(systemName: paid >= item.planned ? "checkmark.circle.fill" : item.month < current ? "exclamationmark.circle" : "circle")
                            .foregroundStyle(paid >= item.planned ? Palette.positive : item.month < current ? Palette.negative : .secondary)
                        Text(Charity.title(item.month))
                        Spacer()
                        Text(money(paid) + " / " + money(item.planned)).monospacedDigit()
                    }.font(.caption)
                }
            }.font(.subheadline)
            Button("Внести экономию", action: contribute).buttonStyle(.borderedProminent).disabled(progress.remaining == 0)
        }.bankTile()
    }
}

private struct ContributionForm: View {
    let project: SavingsProject
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var amount = ""
    @State private var date = Date.now
    @State private var note = ""
    @State private var failed = false
    private var cents: Int64? { IncomeMath.positive(amount) }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Сколько сэкономил, ₽", text: $amount)
                DatePicker("Дата", selection: $date, displayedComponents: .date)
                TextField("Комментарий, например «не покупал кофе навынос»", text: $note)
                Text("Экономия уменьшает долг проекту. Остатки счетов и капитал не меняются.").font(.caption)
            }.formStyle(.grouped).navigationTitle("Экономия: " + project.title.lowercased())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        guard let cents else { return }
                        do {
                            let item = ProjectContribution(id: UUID(), project: project.id, date: date, cents: cents,
                                                           note: note.trimmingCharacters(in: .whitespacesAndNewlines))
                            context.insert(try FinanceRecord(ProjectContribution.kind, item, id: item.id))
                            try context.save()
                            dismiss()
                        } catch { context.rollback(); failed = true }
                    }.disabled(cents == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 260)
        #endif
        .alert("Не удалось сохранить", isPresented: $failed) { Button("ОК") {} }
    }
}
