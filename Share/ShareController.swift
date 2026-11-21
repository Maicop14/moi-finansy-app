import UIKit
import UniformTypeIdentifiers

@MainActor final class ShareController: UIViewController {
    private let status = UILabel()
    private let close = UIButton(type: .system)
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.numberOfLines = 0; status.textAlignment = .center
        status.text = "Копирование в «Мои Финансы»…"
        close.setTitle("Готово", for: .normal)
        close.addTarget(self, action: #selector(done), for: .touchUpInside)
        close.isHidden = true
        let stack = UIStackView(arrangedSubviews: [status, close])
        stack.axis = .vertical; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: view.centerYAnchor), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)])
        Task { await collect() }
    }
    @objc private func done() { extensionContext?.completeRequest(returningItems: nil) }

    private func collect() async {
        let fm = FileManager.default
        guard let root = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.local.balance.personalledger.imports") else {
            status.text = "Папка импорта недоступна."; close.isHidden = false; return
        }
        let key = UUID().uuidString
        let staging = root.appendingPathComponent(key)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            var count = 0
            var skipped = 0
            var bytesRemaining = BankFileInput.batchLimit
            for p in items.flatMap({ $0.attachments ?? [] }) {
                let types = p.registeredTypeIdentifiers.compactMap { UTType($0) }
                let supported = types.first { $0.conforms(to: .image) || $0.conforms(to: .pdf) || $0.conforms(to: .text) || $0.conforms(to: .spreadsheet) || $0.conforms(to: .json) }
                guard let type = supported ?? types.first(where: { $0 == .fileURL || $0 == .data }) else { continue }
                // Keep the first files that fit instead of rejecting the whole batch.
                guard count < BankFileInput.fileCount else { skipped += 1; continue }
                let limit = min(BankFileInput.perFileLimit, bytesRemaining)
                let prefix = String(count) + "-"
                let suggested = p.suggestedName
                let copied = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                    let copy: @Sendable (URL?, Error?) -> Void = { url, error in
                        do {
                            if let error { throw error }
                            guard let url, url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let filename = ((suggested ?? url.lastPathComponent) as NSString).lastPathComponent
                            let safe = filename.isEmpty || filename == "." || filename == ".." ? "Документ" : filename
                            let ext = url.pathExtension.isEmpty ? type.preferredFilenameExtension ?? "txt" : url.pathExtension
                            let name = (safe as NSString).pathExtension.isEmpty ? safe + "." + ext : safe
                            let data = try BankFileInput.bytes(at: url, limit: limit)
                            try data.write(to: staging.appendingPathComponent(prefix + name), options: [.atomic, .completeFileProtection])
                            continuation.resume(returning: data.count)
                        } catch { continuation.resume(throwing: error) }
                    }
                    if type == .fileURL {
                        p.loadItem(forTypeIdentifier: type.identifier) { value, error in copy(value as? URL, error) }
                    } else {
                        _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier, completionHandler: copy)
                    }
                }
                count += 1
                bytesRemaining -= copied
            }
            guard count > 0 else { throw CocoaError(.fileReadUnsupportedScheme) }
            let inbox = root.appendingPathComponent("Pending")
            try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: inbox.appendingPathComponent(key))
            status.text = "Передано файлов: " + String(count) + (skipped > 0 ? ", не вошло: " + String(skipped) + " (за раз до " + String(BankFileInput.fileCount) + ")" : "") + ". Откройте «Мои Финансы», чтобы проверить операции."
        } catch {
            try? fm.removeItem(at: staging)
            status.text = "Не удалось передать файл. " + error.localizedDescription
        }
        close.isHidden = false
    }
}
