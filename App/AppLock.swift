import SwiftUI
import LocalAuthentication
import Security
import CommonCrypto
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct PINRecord: Codable {
    let salt: Data
    let verifier: Data
    var biometricState: Data?
    var length: Int? = 4
    var failures = 0
    var retryAfter = Date.distantPast

    static func valid(_ pin: String, length: Int = 4) -> Bool {
        [4, 6].contains(length) && pin.utf8.count == length && pin.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func create(_ pin: String, domain: Data?) throws -> Self {
        guard valid(pin) else { throw LockError.storage }
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else { throw LockError.storage }
        return try Self(salt: Data(salt), verifier: derive(pin, salt: Data(salt)), biometricState: domain)
    }

    private static func derive(_ pin: String, salt: Data) throws -> Data {
        var result = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pin, pin.utf8.count,
                                 bytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &result, result.count)
        }
        guard status == kCCSuccess else { throw LockError.storage }
        return Data(result)
    }

    mutating func verify(_ pin: String, at now: Date) throws -> Bool {
        guard failures >= 0, failures <= 12, salt.count == 16, verifier.count == 32 else { throw LockError.storage }
        guard now >= retryAfter else { throw LockError.wait(retryAfter) }
        guard Self.valid(pin, length: length ?? 6) else { return false }
        let candidate = try Self.derive(pin, salt: salt)
        var difference: UInt8 = 0
        for (a, b) in zip(candidate, verifier) { difference |= a ^ b }
        if difference == 0 {
            failures = 0
            retryAfter = .distantPast
            return true
        }
        failures = min(12, failures + 1)
        if failures >= 5 {
            retryAfter = now.addingTimeInterval(TimeInterval(min(3600, 30 << (failures - 5))))
        }
        return false
    }
}

private enum LockError: Error { case storage, wait(Date) }

private enum LockKeychain {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "local.balance.personalledger") + ".entry-lock.v1",
         kSecAttrAccount as String: "device-pin"]
    }
    static func load() throws -> PINRecord? {
        var request = query
        request[kSecReturnData as String] = true
        var output: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &output)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = output as? Data else { throw LockError.storage }
        return try JSONDecoder().decode(PINRecord.self, from: data)
    }
    static func write(_ record: PINRecord, new: Bool) throws {
        let attributes = [kSecValueData as String: try JSONEncoder().encode(record)]
        let status: OSStatus
        if new {
            var item = query.merging(attributes) { _, b in b }
            #if os(iOS)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            #endif
            status = SecItemAdd(item as CFDictionary, nil)
        } else {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else { throw LockError.storage }
    }
}

@MainActor final class AppLock: ObservableObject {
    enum Screen { case loading, setup, replaceLegacy, locked, open, unavailable }
    @Published private(set) var screen = Screen.loading
    @Published private(set) var length = 4
    @Published private(set) var busy = false
    @Published var message = ""
    private var context: LAContext?
    private var generation = UUID()
    private var grantOnActivation = false
    /// Not cleared by lock(): two PIN checks must never read the same failure counter.
    private var verifying = false

    /// The keychain read is synchronous, so the first frame already shows the PIN form instead of a spinner.
    init() { if DemoMode.isOn { screen = .open } else { refresh() } }

    func refresh() {
        guard !DemoMode.isOn, screen == .loading || screen == .unavailable else { return }
        do {
            let record = try LockKeychain.load()
            length = record.map { $0.length ?? 6 } ?? 4
            screen = record == nil ? .setup : .locked
            message = ""
        }
        catch { unavailable() }
    }
    private func unavailable() {
        screen = .unavailable
        message = "Не удалось открыть связку ключей. Разблокируй устройство и повтори попытку."
    }
    func lock() {
        if DemoMode.isOn { return }
        generation = UUID()
        context?.invalidate()
        context = nil
        grantOnActivation = false
        busy = false
        message = ""
        if screen == .replaceLegacy { length = 6 }
        if screen == .open || screen == .replaceLegacy { screen = .locked }
    }
    func activate() {
        if grantOnActivation { grantOnActivation = false; finishAuthentication() }
        else { refresh() }
    }
    private func finishAuthentication() {
        if length == 6 { length = 4; screen = .replaceLegacy } else { screen = .open }
    }
    private func grant() {
        #if os(macOS)
        let active = NSApp.isActive
        #else
        let active = UIApplication.shared.applicationState == .active
        #endif
        if active { finishAuthentication() } else { grantOnActivation = true }
    }
    private func biometrics(_ ctx: LAContext) -> Data? {
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return ctx.evaluatedPolicyDomainState
    }
    var biometricLabel: String? {
        let ctx = LAContext()
        guard let current = biometrics(ctx), let record = try? LockKeychain.load(),
              record.biometricState == current else { return nil }
        switch ctx.biometryType {
        case .faceID: return "Войти с Face ID"
        case .touchID: return "Войти с Touch ID"
        default: return nil
        }
    }
    func submit(_ pin: String, confirmation: String) async {
        guard !busy, screen == .setup || screen == .replaceLegacy || screen == .locked else { return }
        guard PINRecord.valid(pin, length: length) else { message = "Введи PIN целиком."; return }
        let ticket = generation
        busy = true; message = ""
        defer { if ticket == generation { busy = false; context = nil } }
        do {
            if screen == .setup || screen == .replaceLegacy {
                guard pin == confirmation else { message = "Коды не совпали."; return }
                let ctx = LAContext()
                context = ctx
                // Ask for the device owner's password or biometrics whenever the device has any,
                // so a person holding an unlocked device cannot set the first PIN.
                if screen == .setup, ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
                    guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Подтверди настройку PIN для «Мои Финансы».") else { return }
                }
                guard ticket == generation else { return }
                let domain = biometrics(LAContext())
                // 600 000 PBKDF2 rounds take about a second: keep them off the main thread.
                let record = try await Task.detached { try PINRecord.create(pin, domain: domain) }.value
                guard ticket == generation else { return }
                try LockKeychain.write(record, new: screen == .setup)
            } else {
                guard !verifying else { return }
                verifying = true
                defer { verifying = false }
                guard let stored = try LockKeychain.load() else { unavailable(); return }
                let now = Date.now
                let result = try await Task.detached { () throws -> (Bool, PINRecord) in
                    var copy = stored
                    let ok = try copy.verify(pin, at: now)
                    return (ok, copy)
                }.value
                let ok = result.0
                var record = result.1
                if ok { record.biometricState = biometrics(LAContext()) }
                try LockKeychain.write(record, new: false)
                // The failure counter is written above even if the app was locked meanwhile.
                guard ticket == generation else { return }
                guard ok else {
                    message = record.retryAfter > Date.now ? delayMessage(record.retryAfter) : "Неверный PIN."
                    return
                }
            }
            grant()
        } catch LockError.wait(let date) { message = delayMessage(date) }
        catch let error as LAError { if ticket == generation { message = "Подтверждение устройства не выполнено (\(error.code.rawValue))." } }
        catch { if ticket == generation { unavailable() } }
    }
    private func delayMessage(_ date: Date) -> String {
        "Слишком много попыток. Повтори после " + date.formatted(.dateTime.hour().minute().second()) + "."
    }
    func authenticate() async {
        guard !busy, screen == .locked else { return }
        let ctx = LAContext()
        let ticket = generation
        ctx.localizedFallbackTitle = ""
        ctx.localizedCancelTitle = "Ввести PIN"
        context = ctx
        busy = true; message = ""
        defer { if ticket == generation { context = nil; busy = false } }
        do {
            guard var record = try LockKeychain.load(), let state = biometrics(ctx),
                  state == record.biometricState else { message = "Для входа введи PIN."; return }
            guard try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Открой «Мои Финансы»."), ticket == generation else { return }
            record.failures = 0; record.retryAfter = .distantPast
            try LockKeychain.write(record, new: false)
            grant()
        } catch let error as LAError {
            if ticket == generation { message = error.code == .biometryLockout ? "Биометрия заблокирована. Введи PIN." : "Для входа введи PIN." }
        } catch { if ticket == generation { unavailable() } }
    }
}

enum DayPart: String, CaseIterable {
    case morning, day, night

    /// The same boundaries as the greeting: утро → morning, день → day, вечер and ночь → night.
    static func at(hour: Int) -> Self {
        switch hour {
        case 6..<11: .morning
        case 11..<18: .day
        default: .night
        }
    }
    static func at(_ date: Date) -> Self { at(hour: Calendar.autoupdatingCurrent.component(.hour, from: date)) }

    /// The owner's own photos in `App/ArchiveResources/Splash/`: splash-morning-01.jpg, splash-day-01.jpg,
    /// splash-night-01.jpg… Without them the splash is a neutral gradient.
    var photos: [String] { SplashPhotos.names(DemoMode.isOn ? [] : SplashPhotos.available).filter { $0.hasPrefix("splash-" + rawValue + "-") } }
}

enum SplashPhotos {
    static var folder: URL? { Archive.resources.resourceURL?.appendingPathComponent("ArchiveResources/Splash") }
    static let available: [String] = {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return files.filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) }
    }()
    static func names(_ all: [String]) -> [String] { all.filter { $0.hasPrefix("splash-") }.sorted() }

    #if os(macOS)
    typealias Platform = NSImage
    #else
    typealias Platform = UIImage
    #endif
    private nonisolated(unsafe) static let cache = NSCache<NSString, Platform>()
    /// Read synchronously so the photo is there on the first frame; decoded once per name.
    static func image(_ name: String) -> Image? {
        if let hit = cache.object(forKey: name as NSString) { return wrap(hit) }
        guard let url = folder?.appendingPathComponent(name + ".jpg"), let image = Platform(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return wrap(image)
    }
    private static func wrap(_ image: Platform) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }
}

/// One photo per part of the day, drawn at launch and again only when the app leaves the screen,
/// so the Face ID curtain, the lock screen and the splash after unlocking show the same picture.
@MainActor final class Backdrop: ObservableObject {
    static let shared = Backdrop()
    @Published private(set) var picks: [DayPart: String]
    private init() { picks = Self.draw() }
    func reshuffle() { picks = Self.draw() }
    /// nil when no photos are installed: the backdrop then shows a gradient.
    func photo(at date: Date) -> String? { picks[DayPart.at(date)] }
    private static func draw() -> [DayPart: String] {
        DayPart.allCases.reduce(into: [:]) { result, part in result[part] = part.photos.randomElement() }
    }
}

/// The photo fills the screen; dark gradients at the top and bottom keep white text readable on any picture.
private struct BackdropPhoto: View {
    let name: String?
    let size: CGSize
    var body: some View {
        Group {
            // Without the owner's photos (a clean copy of the code, or demo mode): a neutral background.
            if let name, let image = SplashPhotos.image(name) { image.resizable().scaledToFill() }
            else {
                LinearGradient(colors: [Color(red: 0.13, green: 0.34, blue: 0.84), Color(red: 0.06, green: 0.17, blue: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
            .frame(width: size.width, height: size.height).clipped()
            .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.58), location: 0),
                                            .init(color: .black.opacity(0.08), location: 0.42),
                                            .init(color: .black.opacity(0.10), location: 0.6),
                                            .init(color: .black.opacity(0.52), location: 1)],
                                    startPoint: .top, endPoint: .bottom))
            .accessibilityHidden(true)
    }
}

private struct LockForm: View {
    @ObservedObject var gate: AppLock
    @State private var digits = ""
    @State private var first: String?
    @State private var sending = false
    @ObservedObject private var backdrop = Backdrop.shared
    @Environment(\.scenePhase) private var phase
    private var creating: Bool { gate.screen == .setup || gate.screen == .replaceLegacy }
    private var prompt: String {
        if first != nil { return "Повторите новый PIN" }
        if creating { return "Придумайте PIN из 4 цифр" }
        return gate.length == 6 ? "Введите прежний PIN из 6 цифр" : "Введите PIN"
    }

    private func press(_ number: Int) {
        guard !sending, !gate.busy, digits.count < gate.length else { return }
        gate.message = ""
        digits += String(number)
        guard digits.count == gate.length else { return }
        let code = digits
        digits = ""
        if creating && first == nil { first = code; return }
        let original = first ?? code
        first = nil
        sending = true
        Task { await gate.submit(original, confirmation: code); sending = false }
    }

    private func digit(_ n: Int) -> some View {
        Button { press(n) } label: {
            Text(String(n)).font(.system(size: 32, weight: .medium)).monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: LockColumn.keyHeight)
                .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 17))
                .foregroundStyle(Color(red: 0.04, green: 0.13, blue: 0.21))
        }.buttonStyle(.plain).accessibilityIdentifier("pinKey" + String(n))
        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: [])
    }

    var body: some View {
        ZStack {
            GeometryReader { bounds in
                TimelineView(.everyMinute) { tick in
                    BackdropPhoto(name: backdrop.photo(at: tick.date), size: bounds.size)
                }
            }.ignoresSafeArea().accessibilityHidden(true).allowsHitTesting(false)
            GeometryReader { area in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(LocalProfile.initials).font(.headline.bold()).padding(10)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.45)))
                        TimelineView(.everyMinute) { tick in
                            Text(WelcomeScene.title(hour: Calendar.autoupdatingCurrent.component(.hour, from: tick.date)))
                                .font(.largeTitle.bold()).accessibilityIdentifier("lockGreeting")
                                .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                        }
                        if creating || gate.screen == .locked {
                            Text(prompt).font(.headline).accessibilityIdentifier("pinPrompt")
                            HStack(spacing: 5) {
                                ForEach(0..<gate.length, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.76))
                                        .frame(width: 32, height: 36)
                                        .overlay { if i < digits.count { Circle().fill(.black).frame(width: 10, height: 10) } }
                                }
                            }.accessibilityElement(children: .ignore).accessibilityLabel("Введено цифр: \(digits.count) из \(gate.length)")
                            if !gate.message.isEmpty { Text(gate.message).font(.callout) }
                            Spacer(minLength: 24)
                            Grid(horizontalSpacing: 7, verticalSpacing: 7) {
                                ForEach(0..<3) { row in
                                    GridRow { ForEach(1...3, id: \.self) { column in digit(row * 3 + column) } }
                                }
                                GridRow {
                                    Button { if !digits.isEmpty { digits.removeLast() } } label: {
                                        Image(systemName: "delete.left").frame(maxWidth: .infinity, minHeight: LockColumn.keyHeight)
                                    }.accessibilityLabel("Стереть цифру").keyboardShortcut(.delete, modifiers: [])
                                    digit(0)
                                    if gate.screen == .locked, let label = gate.biometricLabel {
                                        Button { Task { await gate.authenticate() } } label: {
                                            Image(systemName: label.contains("Face") ? "faceid" : "touchid").font(.title)
                                                .frame(maxWidth: .infinity, minHeight: LockColumn.keyHeight)
                                        }.accessibilityLabel(label)
                                    } else { Color.clear.frame(height: 1).accessibilityHidden(true) }
                                }
                            }.buttonStyle(.plain).disabled(sending || gate.busy)
                        } else if gate.screen == .unavailable {
                            Text(gate.message)
                            Button("Повторить") { gate.refresh() }
                        } else { ProgressView() }
                    }.modifier(LockColumn(height: area.size.height))
                }.scrollBounceBehavior(.basedOnSize)
            }
        }.foregroundStyle(.white)
        .background(Color(red: 0.06, green: 0.17, blue: 0.25))
        .onChange(of: phase) { _, next in if next == .background { digits = ""; first = nil } }
        .onChange(of: gate.screen) { _, _ in digits = ""; first = nil }
        #if os(macOS)
        // On a Mac with Touch ID the system prompt opens right away; «Ввести PIN» closes it.
        .task(id: gate.screen) {
            guard gate.screen == .locked, gate.biometricLabel != nil else { return }
            try? await Task.sleep(for: .milliseconds(450))
            if gate.screen == .locked, NSApp.isActive { await gate.authenticate() }
        }
        #endif
    }
}

/// The PIN column: full width on iPhone; on the Mac a frosted panel in the middle of the photo,
/// whatever the window size.
private struct LockColumn: ViewModifier {
    let height: CGFloat
    #if os(macOS)
    static let keyHeight: CGFloat = 44
    func body(content: Content) -> some View {
        content.fixedSize(horizontal: false, vertical: true).padding(28).frame(width: 360)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.2)))
            .environment(\.colorScheme, .dark)
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: height)
    }
    #else
    static let keyHeight: CGFloat = 52
    func body(content: Content) -> some View {
        content.padding(24).frame(maxWidth: 440).frame(minHeight: min(height, 700)).frame(maxWidth: .infinity)
    }
    #endif
}

/// Initials for the splash badge (and an optional default name), in `App/ArchiveResources/profile.json`.
struct LocalProfile: Decodable {
    var name: String?
    var initials: String?
    static let current: LocalProfile = {
        guard let url = Archive.resources.resourceURL?.appendingPathComponent("ArchiveResources/profile.json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(LocalProfile.self, from: data) else { return LocalProfile() }
        return value
    }()
    static var initials: String { DemoMode.isOn ? "МФ" : (current.initials?.isEmpty == false ? current.initials! : "МФ") }
}

/// The name used in the greeting, chosen by the owner on first launch or later in «Капитал»; stored on the device
/// and carried by backups.
enum ProfileName {
    static let key = "profile.name"
    static let askedKey = "profile.asked"
    static var current: String? {
        let chosen = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let chosen, !chosen.isEmpty { return chosen }
        return LocalProfile.current.name
    }
    static func set(_ name: String, defaults: UserDefaults = .standard) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if clean.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(clean, forKey: key) }
        defaults.set(true, forKey: askedKey)
    }
}

struct WelcomeScene {
    let greeting: String

    static func at(hour: Int) -> Self {
        switch hour {
        case 6..<11: Self(greeting: "Доброе утро")
        case 11..<18: Self(greeting: "Добрый день")
        case 18..<22: Self(greeting: "Добрый вечер")
        default: Self(greeting: "Доброй ночи")
        }
    }

    static var now: Self { at(hour: Calendar.autoupdatingCurrent.component(.hour, from: Date())) }

    /// The name the owner chose («Как к вам обращаться?»); without one the greeting is just «Добрый день».
    /// Demo mode never shows it.
    static var name: String? { DemoMode.isOn ? nil : ProfileName.current }
    /// The same greeting on the lock screen and on the welcome screen after unlocking.
    static func title(hour: Int, name: String? = WelcomeScene.name) -> String {
        guard let name, !name.isEmpty else { return at(hour: hour).greeting }
        return at(hour: hour).greeting + ", " + name
    }
    var title: String {
        guard let name = Self.name, !name.isEmpty else { return greeting }
        return greeting + ", " + name
    }
}

struct WelcomeScreen: View {
    let scene: WelcomeScene
    var photo: String? = Backdrop.shared.photo(at: .now)
    var body: some View {
        GeometryReader { size in
            ZStack {
                BackdropPhoto(name: photo, size: size.size)
                #if os(macOS)
                // A wide window: the greeting in the middle, sized to the window.
                VStack(spacing: 16) {
                    Text(LocalProfile.initials).font(.title2.bold()).padding(12)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.6)))
                        .accessibilityHidden(true)
                    Text(scene.title).font(.system(size: min(52, max(30, size.size.width / 22)), weight: .semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("welcomeGreeting")
                }.foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                    .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                #else
                VStack(alignment: .leading, spacing: 14) {
                    Spacer().frame(height: size.size.height * 0.13)
                    Text(LocalProfile.initials).font(.headline.bold()).padding(10)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.6)))
                        .accessibilityHidden(true)
                    Text(scene.title).font(.largeTitle.weight(.semibold))
                        .accessibilityIdentifier("welcomeGreeting")
                    Spacer()
                }.foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    .padding(.horizontal, 22)
                #endif
            }
        }.ignoresSafeArea().background(Color(red: 0.06, green: 0.17, blue: 0.25))
    }
}

struct LockedRoot: View {
    @ObservedObject var gate: AppLock
    @Environment(\.scenePhase) private var phase
    @State private var pendingURL: URL?
    var body: some View {
        Group {
            if gate.screen == .open {
                RestoredLedger(pendingURL: $pendingURL)
            } else { LockForm(gate: gate) }
        }
        .task { gate.refresh(); await Reminders.reschedule() }
        .onOpenURL { if $0.isFileURL { pendingURL = $0 } }
        // Leaving the app keeps it where it was: the owner asked for the PIN / Face ID only when the app starts
        // afresh — after it was closed, unloaded by the system, or the device restarted (a new process starts locked).
        .onChange(of: phase) { _, next in
            if next == .active { gate.activate(); Task { await Reminders.reschedule() } }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in gate.activate() }
        // A closed main window locks the app even if another window (Настройки) keeps it running.
        .onDisappear { gate.lock() }
        #else
        // The app switcher snapshot still shows the splash, never the amounts.
        .background(PrivacyCover())
        #endif
    }
}

#if os(iOS)
// Above sheets and Quick Look, before UIKit snapshots the scene for the switcher.
private struct PrivacyCover: UIViewRepresentable {
    final class Observer: UIView {
        /// The same welcome screen as after unlocking, greeting included, so the Face ID prompt
        /// and the app switcher never show a picture without text.
        private var curtain: UIView?
        override init(frame: CGRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(self, selector: #selector(hideContent), name: UIScene.willDeactivateNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(showContent), name: UIScene.didActivateNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(nextPhoto), name: UIScene.didEnterBackgroundNotification, object: nil)
        }
        required init?(coder: NSCoder) { nil }
        /// A new photo for the next visit, drawn before the switcher snapshot so the snapshot, the lock
        /// screen and the splash after unlocking all match. The Face ID prompt only deactivates the
        /// scene, so it keeps the photo the lock screen already shows.
        @objc func nextPhoto(_ note: Notification) {
            guard let window, let scene = note.object as? UIScene, scene === window.windowScene else { return }
            Backdrop.shared.reshuffle()
            if curtain != nil { hideContent(note) }
        }
        @objc func hideContent(_ note: Notification) {
            guard let window, let scene = note.object as? UIScene, scene === window.windowScene else { return }
            curtain?.removeFromSuperview()
            let host = UIHostingController(rootView: WelcomeScreen(scene: .now))
            let cover = host.view!
            cover.backgroundColor = UIColor(red: 0.06, green: 0.17, blue: 0.25, alpha: 1)
            cover.isUserInteractionEnabled = false
            cover.accessibilityLabel = "Мои Финансы"
            cover.frame = window.bounds
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(cover)
            // Lay out now: the system takes its snapshot right after this notification.
            cover.layoutIfNeeded()
            curtain = cover
        }
        @objc func showContent(_ note: Notification) {
            guard let scene = note.object as? UIScene, scene === window?.windowScene else { return }
            curtain?.removeFromSuperview()
            curtain = nil
        }
        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil { curtain?.removeFromSuperview(); curtain = nil }
            super.willMove(toWindow: newWindow)
        }
    }
    func makeUIView(context: Context) -> Observer { Observer() }
    func updateUIView(_ view: Observer, context: Context) {}
}
#endif
