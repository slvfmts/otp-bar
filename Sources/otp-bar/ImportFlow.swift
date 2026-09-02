import AppKit
import UniformTypeIdentifiers

/// Модальные GUI-операции импорта/удаления. Вынесены из View, потому что окно
/// MenuBarExtra(.window) закрывается при потере фокуса — флоу держит ссылку на
/// `store` (он переживает закрытие popover) и выполняется синхронно в модалке.
///
/// LSUIElement(accessory)-приложение само не выводит окна на передний план, поэтому
/// вокруг каждой модалки временно переключаем activationPolicy на .regular.
@MainActor
enum ImportFlow {

    /// Защита от двойного показа: AppKit modal loop крутит main-queue, поэтому быстрый
    /// двойной клик может открыть две панели/алерта. Пускаем только одну операцию за раз.
    private static var isPresenting = false

    static func presentImportPanel(store: AccountStore) {
        guard !isPresenting else { return }
        isPresenting = true
        // Дать popover закрыться перед показом модального окна.
        DispatchQueue.main.async {
            defer { isPresenting = false }
            withForegroundApp {
                let panel = NSOpenPanel()
                panel.title = "Выберите картинку(и) с QR-кодом"
                panel.prompt = "Импортировать"
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowedContentTypes = [.image]

                guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

                var incoming: [Account] = []
                for url in panel.urls {
                    for payload in scanQRCodes(atPath: url.path) {
                        incoming.append(contentsOf: OTPAuth.accounts(from: payload))
                    }
                }

                guard !incoming.isEmpty else {
                    alert(style: .warning, title: "QR не распознан",
                          text: "В выбранных картинках не нашлось TOTP-аккаунтов.\n\n" +
                                "Проверьте, что QR-код виден целиком. HOTP-записи и " +
                                "неподдерживаемые записи пропускаются намеренно.")
                    return
                }

                let result = store.addAccounts(incoming)
                if case .failure(let error) = result {
                    alert(style: .critical, title: "Импорт не выполнен",
                          text: error.userMessage)
                    return
                }
                guard case .success(let r) = result else { return }

                var body = "Добавлено: \(r.added)\nОбновлено: \(r.updated)\nБез изменений: \(r.skipped)"
                if !r.updatedNames.isEmpty {
                    // Перезапись существующего семени видна явно — не молча.
                    body += "\n\nПерезаписаны: " + r.updatedNames.joined(separator: ", ")
                }
                body += "\n\nТеперь удалите скриншот(ы) QR — в них семена в открытом виде."

                let a = NSAlert()
                a.alertStyle = .informational
                a.messageText = "Импорт завершён"
                a.informativeText = body
                a.addButton(withTitle: "Готово")
                a.addButton(withTitle: "Показать в Finder")
                if a.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting(panel.urls)
                }
            }
        }
    }

    static func confirmDelete(_ account: Account, store: AccountStore) {
        guard !isPresenting else { return }
        isPresenting = true
        DispatchQueue.main.async {
            defer { isPresenting = false }
            withForegroundApp {
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "Удалить аккаунт?"
                a.informativeText = "\(account.issuer) / \(account.label)\n\n" +
                    "Код перестанет показываться, семя удалится из Keychain. Это необратимо."
                a.addButton(withTitle: "Удалить")
                a.addButton(withTitle: "Отмена")
                if a.runModal() == .alertFirstButtonReturn {
                    let result = store.delete(account)
                    if case .failure(let error) = result {
                        alert(style: .critical, title: "Удаление не выполнено",
                              text: error.userMessage)
                    }
                }
            }
        }
    }

    // MARK: - helpers

    /// Временно делает accessory-приложение обычным (чтобы модалка вышла на передний
    /// план), выполняет блок, возвращает .accessory обратно.
    private static func withForegroundApp(_ body: () -> Void) {
        let app = NSApp
        let previous = app?.activationPolicy() ?? .accessory
        app?.setActivationPolicy(.regular)
        app?.activate(ignoringOtherApps: true)
        defer { app?.setActivationPolicy(previous) }
        body()
    }

    private static func alert(style: NSAlert.Style, title: String, text: String) {
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
