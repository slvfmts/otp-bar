import Foundation
import Security
import XCTest
@testable import otp_bar

@MainActor
final class OtpBarTests: XCTestCase {
    func testRFC6238VectorsForSHA1SHA256AndSHA512() {
        let timestamps: [TimeInterval] = [
            59, 1_111_111_109, 1_111_111_111, 1_234_567_890, 2_000_000_000, 20_000_000_000
        ]
        let vectors: [(algorithm: String, secret: String, expected: [String])] = [
            (
                "SHA1",
                "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
                ["94287082", "07081804", "14050471", "89005924", "69279037", "65353130"]
            ),
            (
                "SHA256",
                TOTP.base32Encode(Array("12345678901234567890123456789012".utf8)),
                ["46119246", "68084774", "67062674", "91819424", "90698825", "77737706"]
            ),
            (
                "SHA512",
                TOTP.base32Encode(Array("1234567890123456789012345678901234567890123456789012345678901234".utf8)),
                ["90693936", "25091201", "99943326", "93441116", "38618901", "47863826"]
            )
        ]

        for vector in vectors {
            for (timestamp, expected) in zip(timestamps, vector.expected) {
                let account = Account(
                    issuer: "RFC",
                    label: vector.algorithm,
                    secret: vector.secret,
                    digits: 8,
                    period: 30,
                    algorithm: vector.algorithm
                )
                XCTAssertEqual(
                    TOTP.code(for: account, at: Date(timeIntervalSince1970: timestamp)),
                    expected,
                    "\(vector.algorithm) at \(timestamp)"
                )
            }
        }

        let sixDigitAccount = Account(
            issuer: "RFC",
            label: "six-digit",
            secret: vectors[0].secret,
            digits: 6,
            period: 30,
            algorithm: "SHA1"
        )
        XCTAssertEqual(
            TOTP.code(for: sixDigitAccount, at: Date(timeIntervalSince1970: 59)),
            "287082"
        )
    }

    func testBase32KnownVectorsAndTolerance() {
        let vectors = [
            ("", ""),
            ("f", "MY======"),
            ("fo", "MZXQ===="),
            ("foo", "MZXW6==="),
            ("foob", "MZXW6YQ="),
            ("fooba", "MZXW6YTB"),
            ("foobar", "MZXW6YTBOI======")
        ]

        for (plain, encoded) in vectors where !plain.isEmpty {
            XCTAssertEqual(TOTP.base32Encode(Array(plain.utf8)), encoded.replacingOccurrences(of: "=", with: ""))
            XCTAssertEqual(TOTP.base32Decode(encoded), Data(plain.utf8))
        }

        XCTAssertEqual(
            TOTP.base32Decode(" m z x w 6 - y t b o i = = = = = = "),
            Data("foobar".utf8)
        )
        XCTAssertNil(TOTP.base32Decode(""))
        XCTAssertNil(TOTP.base32Decode("   "))
        XCTAssertNil(TOTP.base32Decode("MZXW6YTB!"))
        XCTAssertNil(TOTP.base32Decode("MZ")) // non-zero unused padding bits
        XCTAssertNil(TOTP.base32Decode("M=Y"))
        XCTAssertNil(TOTP.base32Decode("MZXW6YTB=")) // invalid padding length
    }

    func testStandardOTPAuthParsing() {
        let payload = "otpauth://totp/Example%3Aalice%2Fadmin" +
            "?secret=JBSWY3DPEHPK3PXP&issuer=Example%20Inc&algorithm=SHA256&digits=8&period=45"
        let accounts = OTPAuth.accounts(from: payload)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].issuer, "Example Inc")
        XCTAssertEqual(accounts[0].label, "alice/admin")
        XCTAssertEqual(accounts[0].secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(accounts[0].algorithm, "SHA256")
        XCTAssertEqual(accounts[0].digits, 8)
        XCTAssertEqual(accounts[0].period, 45)

        XCTAssertEqual(
            OTPAuth.accounts(from: "otpauth://hotp/Example:alice?secret=JBSWY3DPEHPK3PXP"),
            []
        )
        XCTAssertEqual(
            OTPAuth.accounts(from: "otpauth://totp/Example:alice?secret=not-base32"),
            []
        )
        XCTAssertEqual(
            OTPAuth.accounts(from: "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&algorithm=MD5"),
            []
        )
        XCTAssertEqual(
            OTPAuth.accounts(from: "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&digits=7"),
            []
        )
        XCTAssertEqual(
            OTPAuth.accounts(from: "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&period=0"),
            []
        )
    }

    func testAccountIDIsStructuralAndColonIdentitiesDoNotCollide() {
        let first = testAccount(issuer: "a:b", label: "c", secret: "JBSWY3DPEHPK3PXP")
        let second = testAccount(issuer: "a", label: "b:c", secret: "MZXW6YTB")
        XCTAssertNotEqual(first.id, second.id)

        let vault = FakeVaultStore(loadResult: .success(.loaded([first, second])))
        let store = AccountStore(vault: vault, startTimer: false)
        XCTAssertEqual(Set(store.accounts.map { $0.id }).count, 2)

        guard case .success = store.delete(first) else {
            return XCTFail("deleting the first structural identity should succeed")
        }
        XCTAssertEqual(store.accounts, [second])
    }

    func testOTPAuthDecodesComponentsExactlyOnce() {
        let ordinary = OTPAuth.accounts(
            from: "otpauth://totp/Issuer%3Aaccount%2Fname" +
                "?secret=JBSWY3DPEHPK3PXP&issuer=Issuer%20Name"
        )
        XCTAssertEqual(ordinary.count, 1)
        XCTAssertEqual(ordinary[0].issuer, "Issuer Name")
        XCTAssertEqual(ordinary[0].label, "account/name")

        let intentionallyDoubleEncoded = OTPAuth.accounts(
            from: "otpauth://totp/Issuer%253Aaccount%252Fname" +
                "?secret=JBSWY3DPEHPK3PXP&issuer=Issuer%2520Literal"
        )
        XCTAssertEqual(intentionallyDoubleEncoded.count, 1)
        XCTAssertEqual(intentionallyDoubleEncoded[0].issuer, "Issuer%20Literal")
        XCTAssertEqual(intentionallyDoubleEncoded[0].label, "Issuer%3Aaccount%2Fname")
    }

    func testAccountValidationRejectsInvalidStoredSemanticsAndTOTPIsDefensive() {
        let valid = testAccount()
        XCTAssertTrue(valid.isValid)
        XCTAssertTrue(testAccount(issuer: "", label: "display").isValid)
        XCTAssertTrue(testAccount(issuer: "display", label: "").isValid)

        let invalidAccounts = [
            testAccount(issuer: "", label: ""),
            testAccount(issuer: " ", label: "\n"),
            testAccount(secret: ""),
            testAccount(secret: "MZ"),
            Account(issuer: "Synthetic", label: "digits", secret: valid.secret, digits: 5),
            Account(issuer: "Synthetic", label: "digits", secret: valid.secret, digits: 9),
            Account(issuer: "Synthetic", label: "period", secret: valid.secret, period: 0),
            Account(issuer: "Synthetic", label: "period", secret: valid.secret, period: 301),
            Account(issuer: "Synthetic", label: "algorithm", secret: valid.secret, algorithm: "MD5"),
            Account(issuer: "Synthetic", label: "algorithm", secret: valid.secret, algorithm: "unknown")
        ]

        for account in invalidAccounts {
            XCTAssertFalse(account.isValid, "invalid account unexpectedly passed validation")
            XCTAssertEqual(
                TOTP.code(for: account, at: Date(timeIntervalSince1970: 59)),
                "------"
            )
        }

        let encoded = try! JSONEncoder().encode([valid])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(#""id""#))
        XCTAssertEqual(try? JSONDecoder().decode([Account].self, from: encoded), [valid])

        let client = FakeKeychainClient(copyStatus: errSecSuccess, data: try! JSONEncoder().encode([invalidAccounts[2]]))
        let store = KeychainVaultStore(
            service: uniqueTestService(),
            account: "vault",
            client: client
        )
        XCTAssertEqual(tryResult(store.load()), .failure(.corruptPayload))
    }

    func testGoogleAuthenticatorMigrationUsesSyntheticSecretsAndIdentities() {
        let firstSecret: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x01]
        let secondSecret: [UInt8] = [0x89, 0xab, 0xcd, 0xef, 0x02]
        let thirdSecret: [UInt8] = [0x10, 0x20, 0x30, 0x40, 0x03]
        let payload = migrationURL([
            migrationOTP(secret: firstSecret, name: "alice-example.test", issuer: "Example", algorithm: 1, digits: 1, type: 2),
            migrationOTP(secret: secondSecret, name: "crypto-account", issuer: "Wallet", algorithm: 2, digits: 2, type: 2),
            migrationOTP(secret: thirdSecret, name: "hotp-user", issuer: "Example", algorithm: 1, digits: 1, type: 1),
            migrationOTP(secret: [0x04], name: "md5-user", issuer: "Example", algorithm: 4, digits: 1, type: 2),
            migrationOTP(secret: [0x05], name: "unknown-digits", issuer: "Example", algorithm: 1, digits: 9, type: 2)
        ])

        let accounts = OTPAuth.accounts(from: payload)
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts[0].issuer, "Example")
        XCTAssertEqual(accounts[0].label, "alice-example.test")
        XCTAssertEqual(accounts[0].secret, TOTP.base32Encode(firstSecret))
        XCTAssertEqual(accounts[0].algorithm, "SHA1")
        XCTAssertEqual(accounts[1].issuer, "Wallet")
        XCTAssertEqual(accounts[1].label, "crypto-account")
        XCTAssertEqual(accounts[1].algorithm, "SHA256")
        XCTAssertEqual(accounts[1].digits, 8)
    }

    func testMigrationUnknownFieldsAndMalformedPayloadsFailSafely() {
        let otp = migrationOTP(
            secret: [0x21, 0x22, 0x23],
            name: "synthetic",
            issuer: "Example",
            algorithm: 3,
            digits: 1,
            type: 2,
            unknownFields: field(99, bytes: [0xde, 0xad]) + field(100, varint: 7)
        )
        let withUnknownTopLevelField = field(2, varint: 123) + field(1, bytes: otp)
        XCTAssertEqual(OTPAuth.accounts(from: migrationURLData(withUnknownTopLevelField)).count, 1)

        let truncatedOuter = Array(withUnknownTopLevelField.dropLast())
        XCTAssertEqual(OTPAuth.accounts(from: migrationURLData(truncatedOuter)), [])

        let malformedNested = field(1, bytes: [0x0a, 0x05, 0x01])
        XCTAssertEqual(OTPAuth.accounts(from: migrationURLData(malformedNested)), [])
        XCTAssertEqual(
            OTPAuth.accounts(from: "otpauth-migration://offline?data=not-base64"),
            []
        )
    }

    func testKeychainLoadOutcomesAreDistinctAndPayloadNeverAppearsInErrors() {
        let missingClient = FakeKeychainClient(copyStatus: errSecItemNotFound)
        let missingStore = KeychainVaultStore(
            service: uniqueTestService(),
            account: "vault",
            client: missingClient
        )
        XCTAssertEqual(tryResult(missingStore.load()), .success(.missing))

        for status in [errSecAuthFailed, OSStatus(-12345)] {
            let client = FakeKeychainClient(copyStatus: status)
            let store = KeychainVaultStore(
                service: uniqueTestService(),
                account: "vault",
                client: client
            )
            XCTAssertEqual(tryResult(store.load()), .failure(.keychain(status)))
        }

        let account = testAccount(label: "valid")
        let validData = try! JSONEncoder().encode([account])
        let validClient = FakeKeychainClient(copyStatus: errSecSuccess, data: validData)
        let validStore = KeychainVaultStore(
            service: uniqueTestService(),
            account: "vault",
            client: validClient
        )
        XCTAssertEqual(tryResult(validStore.load()), .success(.loaded([account])))

        let corruptClient = FakeKeychainClient(copyStatus: errSecSuccess, data: Data("not-json".utf8))
        let corruptStore = KeychainVaultStore(
            service: uniqueTestService(),
            account: "vault",
            client: corruptClient
        )
        XCTAssertEqual(tryResult(corruptStore.load()), .failure(.corruptPayload))
        XCTAssertFalse(VaultLoadError.corruptPayload.localizedDescription.contains("not-json"))
    }

    func testKeychainSavePreservesUpdateFirstBehavior() {
        let updateClient = FakeKeychainClient(copyStatus: errSecSuccess)
        updateClient.updateStatus = errSecSuccess
        let updateStore = KeychainVaultStore(
            service: uniqueTestService(),
            account: "vault",
            client: updateClient
        )
        guard case .success = updateStore.save([testAccount()]) else {
            return XCTFail("update-first save should succeed")
        }
        XCTAssertEqual(updateClient.updateCalls, 1)
        XCTAssertEqual(updateClient.addCalls, 0)

        let addClient = FakeKeychainClient(copyStatus: errSecSuccess)
        addClient.updateStatus = errSecItemNotFound
        addClient.addStatus = errSecSuccess
        let addStore = KeychainVaultStore(
            service: uniqueTestService(),
            account: "vault",
            client: addClient
        )
        guard case .success = addStore.save([testAccount()]) else {
            return XCTFail("add fallback save should succeed")
        }
        XCTAssertEqual(addClient.updateCalls, 1)
        XCTAssertEqual(addClient.addCalls, 1)

        let invalidClient = FakeKeychainClient(copyStatus: errSecSuccess)
        invalidClient.updateStatus = errSecSuccess
        invalidClient.addStatus = errSecSuccess
        let invalidStore = KeychainVaultStore(
            service: uniqueTestService(),
            account: "vault",
            client: invalidClient
        )
        let invalidResult = invalidStore.save([testAccount(digits: 7)])
        guard case .failure(.invalidPayload) = invalidResult else {
            return XCTFail("invalid payload should be rejected before Keychain writes")
        }
        XCTAssertEqual(invalidClient.updateCalls, 0)
        XCTAssertEqual(invalidClient.addCalls, 0)
    }

    func testReadAndDecodeErrorsBlockAllMutationsBeforeSave() {
        let statuses = [errSecAuthFailed, OSStatus(-23456)]
        for status in statuses {
            let vault = FakeVaultStore(loadResult: .failure(.keychain(status)))
            let store = AccountStore(vault: vault, startTimer: false)
            XCTAssertFalse(store.reload())
            XCTAssertTrue(store.loadError == .keychain(status))
            XCTAssertFailure(store.addAccounts([testAccount()]))
            XCTAssertFailure(store.delete(testAccount()))
            XCTAssertEqual(vault.saveCalls, 0)
        }

        let corruptVault = FakeVaultStore(loadResult: .failure(.corruptPayload))
        let corruptStore = AccountStore(vault: corruptVault, startTimer: false)
        XCTAssertFailure(corruptStore.addAccounts([testAccount()]))
        XCTAssertFailure(corruptStore.delete(testAccount()))
        XCTAssertEqual(corruptVault.saveCalls, 0)

        let invalidInputVault = FakeVaultStore(loadResult: .success(.loaded([])))
        let invalidInputStore = AccountStore(vault: invalidInputVault, startTimer: false)
        let invalid = Account(issuer: "Synthetic", label: "invalid", secret: "MZ")
        guard case .failure(.invalidInput) = invalidInputStore.addAccounts([invalid]) else {
            return XCTFail("invalid imported accounts must be rejected before save")
        }
        XCTAssertEqual(invalidInputVault.saveCalls, 0)
    }

    func testMissingVaultIsUsableAndImportMergesAddedUpdatedUnchangedAndDuplicates() {
        let vault = FakeVaultStore(loadResult: .success(.missing))
        let store = AccountStore(vault: vault, startTimer: false)
        XCTAssertNil(store.loadError)
        XCTAssertTrue(store.accounts.isEmpty)

        let existing = testAccount(label: "existing", secret: "JBSWY3DPEHPK3PXP")
        let unchanged = testAccount(label: "unchanged", secret: "MZXW6YTB")
        vault.loadResult = .success(.loaded([existing, unchanged]))

        let updated = testAccount(label: "existing", secret: "MZXW6YTBOI")
        let duplicateFirst = testAccount(label: "duplicate", secret: "MY")
        let duplicateSecond = testAccount(label: "duplicate", secret: "MZXQ")
        let newAccount = testAccount(label: "new", secret: "MZXW6YTB")

        let result = store.addAccounts([updated, unchanged, duplicateFirst, duplicateSecond, newAccount])
        guard case .success(let importResult) = result else {
            return XCTFail("synthetic merge should succeed")
        }
        XCTAssertEqual(importResult.added, 2)
        XCTAssertEqual(importResult.updated, 2)
        XCTAssertEqual(importResult.skipped, 1)
        XCTAssertEqual(vault.saveCalls, 1)
        XCTAssertEqual(store.accounts.first(where: { $0.id == updated.id })?.secret, updated.secret)
        XCTAssertEqual(store.accounts.first(where: { $0.id == duplicateSecond.id })?.secret, duplicateSecond.secret)
        XCTAssertEqual(store.accounts.first(where: { $0.id == newAccount.id })?.secret, newAccount.secret)
    }

    func testSyntheticVaultCanReloadAndDeleteWithoutRealKeychain() {
        let vault = FakeVaultStore(loadResult: .success(.missing))
        let account = testAccount(label: "reload-delete")
        let store = AccountStore(vault: vault, startTimer: false)

        guard case .success = store.addAccounts([account]) else {
            return XCTFail("synthetic import should succeed")
        }
        let reloaded = AccountStore(vault: vault, startTimer: false)
        XCTAssertEqual(reloaded.accounts, [account])

        guard case .success = reloaded.delete(account) else {
            return XCTFail("synthetic delete should succeed")
        }
        let empty = AccountStore(vault: vault, startTimer: false)
        XCTAssertTrue(empty.accounts.isEmpty)
        XCTAssertNil(empty.loadError)
    }

    func testClipboardCleanupRequiresSameChangeCountAndExactValue() {
        let clipboard = FakeClipboard()
        let scheduler = ManualClipboardScheduler()
        let store = AccountStore(
            vault: FakeVaultStore(loadResult: .success(.missing)),
            clipboard: clipboard,
            clipboardScheduler: scheduler,
            startTimer: false
        )
        let account = testAccount(label: "clipboard")
        let date = Date(timeIntervalSince1970: 59)

        store.copy(account, at: date)
        let code = TOTP.code(for: account, at: date)
        XCTAssertEqual(clipboard.value, code)
        XCTAssertNotEqual(clipboard.value, account.secret)
        XCTAssertEqual(scheduler.delays.count, 1)
        XCTAssertTrue(abs(scheduler.delays[0] - 1.0) < 0.001)

        clipboard.setString(code) // Same text, but a newer clipboard write.
        scheduler.runNext()
        XCTAssertEqual(clipboard.value, code)

        store.copy(account, at: date)
        clipboard.setString("user clipboard content")
        scheduler.runNext()
        XCTAssertEqual(clipboard.value, "user clipboard content")

        store.copy(account, at: date)
        scheduler.runNext()
        XCTAssertNil(clipboard.value)
    }

    // MARK: - Synthetic fixtures

    private func testAccount(
        issuer: String = "Synthetic",
        label: String = "test",
        secret: String = "JBSWY3DPEHPK3PXP",
        digits: Int = 6
    ) -> Account {
        Account(issuer: issuer, label: label, secret: secret, digits: digits)
    }

    private func uniqueTestService() -> String {
        "otp-bar-test-\(UUID().uuidString)"
    }

    private func tryResult(
        _ result: Result<VaultLoadResult, VaultLoadError>
    ) -> Result<VaultLoadResult, VaultLoadError> {
        result
    }

    private func trySaveResult(
        _ result: Result<Void, VaultSaveError>
    ) -> Result<Void, VaultSaveError> {
        result
    }

    private func migrationURL(_ messages: [[UInt8]]) -> String {
        migrationURLData(messages.reduce(into: [UInt8]()) { $0 += field(1, bytes: $1) })
    }

    private func migrationURLData(_ data: [UInt8]) -> String {
        let base64URL = Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "otpauth-migration://offline?data=\(base64URL)"
    }

    private func migrationOTP(
        secret: [UInt8],
        name: String,
        issuer: String,
        algorithm: UInt64,
        digits: UInt64,
        type: UInt64,
        unknownFields: [UInt8] = []
    ) -> [UInt8] {
        field(1, bytes: secret) +
            field(2, bytes: Array(name.utf8)) +
            field(3, bytes: Array(issuer.utf8)) +
            field(4, varint: algorithm) +
            field(5, varint: digits) +
            field(6, varint: type) +
            unknownFields
    }

    private func field(_ number: UInt64, bytes: [UInt8]) -> [UInt8] {
        var result = varint((number << 3) | 2)
        result += varint(UInt64(bytes.count))
        result += bytes
        return result
    }

    private func field(_ number: UInt64, varint value: UInt64) -> [UInt8] {
        var result = varint(number << 3)
        result += varint(value)
        return result
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var result: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            result.append(byte)
        } while value != 0
        return result
    }
}

private final class FakeVaultStore: VaultStore {
    var loadResult: Result<VaultLoadResult, VaultLoadError>
    var saveCalls = 0
    var savedAccounts: [Account]?

    init(loadResult: Result<VaultLoadResult, VaultLoadError>) {
        self.loadResult = loadResult
    }

    func load() -> Result<VaultLoadResult, VaultLoadError> {
        loadResult
    }

    func save(_ accounts: [Account]) -> Result<Void, VaultSaveError> {
        saveCalls += 1
        savedAccounts = accounts
        loadResult = .success(.loaded(accounts))
        return .success(())
    }
}

private final class FakeKeychainClient: KeychainClient {
    let copyStatus: OSStatus
    let data: Data?
    var updateStatus: OSStatus = errSecItemNotFound
    var addStatus: OSStatus = errSecSuccess
    var updateCalls = 0
    var addCalls = 0

    init(copyStatus: OSStatus, data: Data? = nil) {
        self.copyStatus = copyStatus
        self.data = data
    }

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>
    ) -> OSStatus {
        if let data {
            result.pointee = data as CFData
        }
        return copyStatus
    }

    func update(_ query: CFDictionary, attributesToUpdate: CFDictionary) -> OSStatus {
        updateCalls += 1
        return updateStatus
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        addCalls += 1
        return addStatus
    }
}

private final class FakeClipboard: Clipboard {
    var value: String?
    private(set) var changeCount = 0

    func clearContents() {
        value = nil
        changeCount += 1
    }

    @discardableResult
    func setString(_ string: String) -> Bool {
        value = string
        changeCount += 1
        return true
    }

    func string() -> String? {
        value
    }
}

@MainActor
private final class ManualClipboardScheduler: ClipboardCleanupScheduling {
    var delays: [TimeInterval] = []
    private var actions: [@MainActor @Sendable () -> Void] = []

    func schedule(after delay: TimeInterval,
                  action: @escaping @MainActor @Sendable () -> Void) {
        delays.append(delay)
        actions.append(action)
    }

    func runNext() {
        guard !actions.isEmpty else { return }
        actions.removeFirst()()
    }
}

private func XCTAssertFailure<T, E: Error>(
    _ result: Result<T, E>,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if case .success = result {
        XCTFail("expected failure", file: file, line: line)
    }
}
