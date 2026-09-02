import Foundation
import Security

/// The result of loading the vault. A missing Keychain item is a valid empty vault;
/// it is intentionally distinct from a failed or corrupt read.
enum VaultLoadResult: Equatable {
    case missing
    case loaded([Account])
}

enum VaultLoadError: Error, Equatable, LocalizedError {
    case keychain(OSStatus)
    case corruptPayload

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Не удалось прочитать Keychain (OSStatus \(status))."
        case .corruptPayload:
            return "Данные хранилища повреждены или имеют неподдерживаемый формат."
        }
    }

    var userMessage: String {
        switch self {
        case .keychain(let status):
            return "Не удалось прочитать хранилище Keychain (код ошибки \(status)). " +
                "Данные не изменены. Нажмите «Обновить» после проверки доступа к Keychain."
        case .corruptPayload:
            return "Данные хранилища повреждены или имеют неподдерживаемый формат. " +
                "Они не были заменены или удалены."
        }
    }
}

enum VaultSaveError: Error, Equatable, LocalizedError {
    case invalidPayload
    case encoding
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Не удалось записать невалидные данные в Keychain."
        case .encoding:
            return "Не удалось подготовить данные для Keychain."
        case .keychain(let status):
            return "Не удалось записать Keychain (OSStatus \(status))."
        }
    }
}

/// Abstract vault storage used by AccountStore. Production uses KeychainVaultStore;
/// tests inject a fake and never need to address the user's real item.
protocol VaultStore {
    func load() -> Result<VaultLoadResult, VaultLoadError>
    func save(_ accounts: [Account]) -> Result<Void, VaultSaveError>
}

/// Small abstraction around Security.framework so Keychain status handling can be
/// tested without calling the real Keychain service/account.
protocol KeychainClient {
    func copyMatching(_ query: CFDictionary,
                      result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
    func update(_ query: CFDictionary, attributesToUpdate: CFDictionary) -> OSStatus
    func add(_ attributes: CFDictionary) -> OSStatus
}

struct SystemKeychainClient: KeychainClient {
    func copyMatching(_ query: CFDictionary,
                      result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func update(_ query: CFDictionary, attributesToUpdate: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributesToUpdate)
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        SecItemAdd(attributes, nil)
    }
}

/// Stores the whole account list as a single Keychain item.
/// service = "otp-bar", account = "vault", data = JSON([Account]).
struct KeychainVaultStore: VaultStore {
    static let service = "otp-bar"
    static let account = "vault"

    private let service: String
    private let account: String
    private let client: any KeychainClient

    init(service: String = KeychainVaultStore.service,
         account: String = KeychainVaultStore.account,
         client: any KeychainClient = SystemKeychainClient()) {
        self.service = service
        self.account = account
        self.client = client
    }

    func load() -> Result<VaultLoadResult, VaultLoadError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = client.copyMatching(query as CFDictionary, result: &item)
        switch status {
        case errSecItemNotFound:
            return .success(.missing)
        case errSecSuccess:
            guard let data = item as? Data else {
                return .failure(.corruptPayload)
            }
            do {
                let accounts = try JSONDecoder().decode([Account].self, from: data)
                guard accounts.allSatisfy({ $0.isValid }) else {
                    return .failure(.corruptPayload)
                }
                return .success(.loaded(accounts))
            } catch {
                // Never include the payload or decoder details: they can reveal vault data.
                return .failure(.corruptPayload)
            }
        default:
            return .failure(.keychain(status))
        }
    }

    /// Update first, then add only when the item is absent. This preserves the existing
    /// atomic-ish behavior and avoids delete-then-add data loss on write failures.
    func save(_ accounts: [Account]) -> Result<Void, VaultSaveError> {
        guard accounts.allSatisfy({ $0.isValid }) else {
            return .failure(.invalidPayload)
        }

        guard let data = try? JSONEncoder().encode(accounts) else {
            return .failure(.encoding)
        }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update = client.update(
            base as CFDictionary,
            attributesToUpdate: [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess {
            return .success(())
        }
        guard update == errSecItemNotFound else {
            return .failure(.keychain(update))
        }

        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let add = client.add(attributes as CFDictionary)
        return add == errSecSuccess ? .success(()) : .failure(.keychain(add))
    }
}
