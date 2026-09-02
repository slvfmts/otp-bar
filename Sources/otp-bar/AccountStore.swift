import SwiftUI
import Combine
import AppKit

protocol Clipboard {
    var changeCount: Int { get }
    func clearContents()
    @discardableResult func setString(_ string: String) -> Bool
    func string() -> String?
}

struct SystemClipboard: Clipboard {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func clearContents() {
        pasteboard.clearContents()
    }

    @discardableResult
    func setString(_ string: String) -> Bool {
        pasteboard.setString(string, forType: .string)
    }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }
}

@MainActor
protocol ClipboardCleanupScheduling {
    func schedule(after delay: TimeInterval,
                  action: @escaping @MainActor @Sendable () -> Void)
}

@MainActor
struct MainClipboardCleanupScheduler: ClipboardCleanupScheduling {
    func schedule(after delay: TimeInterval,
                  action: @escaping @MainActor @Sendable () -> Void) {
        let timer = Timer(timeInterval: max(delay, 0), repeats: false) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

enum AccountStoreMutationError: Error, Equatable, LocalizedError {
    case invalidInput
    case load(VaultLoadError)
    case save(VaultSaveError)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Импорт содержит неподдерживаемые или повреждённые данные."
        case .load(let error): return error.errorDescription
        case .save(let error): return error.errorDescription
        }
    }

    var userMessage: String {
        switch self {
        case .invalidInput:
            return "Импорт содержит неподдерживаемые или повреждённые данные. Ничего не сохранено."
        case .load(let error):
            return error.userMessage + " Повторите загрузку перед импортом или удалением."
        case .save:
            return "Не удалось записать изменения в Keychain. Существующие аккаунты не изменены."
        }
    }
}

/// Holds the accounts and ticks every second so codes/countdowns refresh.
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var now: Date = Date()
    @Published private(set) var loadError: VaultLoadError?

    private let vault: any VaultStore
    private let clipboard: any Clipboard
    private let clipboardScheduler: any ClipboardCleanupScheduling
    // Swift 6 deinit is nonisolated; Timer is otherwise accessed only on MainActor.
    nonisolated(unsafe) private var timer: Timer?

    init(vault: any VaultStore = KeychainVaultStore(),
         clipboard: any Clipboard = SystemClipboard(),
         clipboardScheduler: (any ClipboardCleanupScheduling)? = nil,
         startTimer: Bool = true) {
        self.vault = vault
        self.clipboard = clipboard
        self.clipboardScheduler = clipboardScheduler ?? MainClipboardCleanupScheduler()
        reload()

        guard startTimer else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        timer?.invalidate()
    }

    @discardableResult
    func reload() -> Bool {
        switch vault.load() {
        case .success(.missing):
            accounts = []
            loadError = nil
            return true
        case .success(.loaded(let loadedAccounts)):
            accounts = loadedAccounts
            loadError = nil
            return true
        case .failure(let error):
            // Do not expose stale data as if it had been freshly loaded.
            accounts = []
            loadError = error
            return false
        }
    }

    func code(for account: Account) -> String {
        TOTP.code(for: account, at: now)
    }

    func secondsRemaining(for account: Account) -> Int {
        TOTP.secondsRemaining(period: account.period, at: now)
    }

    /// Copies only the generated code. Cleanup is guarded by both the exact value and
    /// pasteboard changeCount, so a later clipboard write is never erased.
    func copy(_ account: Account, at date: Date = Date()) {
        let code = TOTP.code(for: account, at: date)
        clipboard.clearContents()
        guard clipboard.setString(code) else { return }

        let writtenChangeCount = clipboard.changeCount
        let period = Double(max(account.period, 1))
        let timestamp = date.timeIntervalSince1970
        let nextWindow = (floor(timestamp / period) + 1) * period
        let delay = max(nextWindow - timestamp, 0)
        clipboardScheduler.schedule(after: delay) { @MainActor [weak self] in
            self?.clearClipboardIfUnchanged(value: code, changeCount: writtenChangeCount)
        }
    }

    func clearClipboardIfUnchanged(value: String, changeCount: Int) {
        guard clipboard.changeCount == changeCount,
              clipboard.string() == value else { return }
        clipboard.clearContents()
    }

    /// Итог импорта для честного отчёта пользователю.
    struct ImportResult {
        var added = 0           // новый id
        var updated = 0         // id есть, содержимое изменилось (перезаписан секрет/параметры)
        var skipped = 0         // id есть и полностью совпадает — ничего не изменилось
        var updatedNames: [String] = []   // что именно перезаписано (для прозрачности)
        var total: Int { added + updated + skipped }
    }

    /// Merge по Account.id. Любая ошибка чтения останавливает операцию до save.
    func addAccounts(_ incoming: [Account]) -> Result<ImportResult, AccountStoreMutationError> {
        guard incoming.allSatisfy({ $0.isValid }) else {
            return .failure(.invalidInput)
        }

        guard let current = loadedAccountsForMutation() else {
            guard let error = loadError else {
                return .failure(.load(.corruptPayload))
            }
            return .failure(.load(error))
        }

        if incoming.isEmpty {
            return .success(ImportResult())
        }

        var merged = current
        var result = ImportResult()
        for account in incoming {
            if let index = merged.firstIndex(where: { $0.id == account.id }) {
                if merged[index] == account {
                    result.skipped += 1
                } else {
                    merged[index] = account
                    result.updated += 1
                    result.updatedNames.append("\(account.issuer) / \(account.label)")
                }
            } else {
                merged.append(account)
                result.added += 1
            }
        }

        switch vault.save(merged) {
        case .success:
            accounts = merged
            loadError = nil
            return .success(result)
        case .failure(let error):
            return .failure(.save(error))
        }
    }

    /// Удаляет аккаунт. Любая ошибка чтения останавливает операцию до save.
    @discardableResult
    func delete(_ account: Account) -> Result<Void, AccountStoreMutationError> {
        guard var current = loadedAccountsForMutation() else {
            guard let error = loadError else {
                return .failure(.load(.corruptPayload))
            }
            return .failure(.load(error))
        }
        current.removeAll { $0.id == account.id }

        switch vault.save(current) {
        case .success:
            accounts = current
            loadError = nil
            return .success(())
        case .failure(let error):
            return .failure(.save(error))
        }
    }

    private func loadedAccountsForMutation() -> [Account]? {
        switch vault.load() {
        case .success(.missing):
            loadError = nil
            return []
        case .success(.loaded(let loadedAccounts)):
            loadError = nil
            return loadedAccounts
        case .failure(let error):
            accounts = []
            loadError = error
            return nil
        }
    }
}
