import Foundation
import Vision
import ImageIO

func die(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

let args = CommandLine.arguments
if args.count >= 2 {
    switch args[1] {
    case "importqr":
        guard args.count >= 3 else { die("usage: otp-bar importqr image.png") }
        runImportQR(path: args[2])
        exit(0)
    case "list":
        switch KeychainVaultStore().load() {
        case .success(.missing):
            print("(пусто)")
        case .success(.loaded(let accounts)):
            if accounts.isEmpty { print("(пусто)") }
            for account in accounts {
                print("\(account.issuer) / \(account.label)  [\(account.digits)d/\(account.period)s/\(account.algorithm)]")
            }
        case .failure(let error):
            die(error.errorDescription ?? "Не удалось прочитать Keychain", code: 1)
        }
        exit(0)
    default:
        break
    }
}

OTPBarApp.main()

// MARK: - CLI commands

/// importqr: скан QR из картинки → otpauth-парсер → merge в Vault.
/// Печатаем только counts и issuer/label — НИКОГДА не печатаем секреты.
func runImportQR(path: String) {
    let payloads = scanQRCodes(atPath: path)
    if payloads.isEmpty { die("QR-код не найден на изображении: \(path)", code: 1) }

    var incoming: [Account] = []
    for payload in payloads {
        incoming.append(contentsOf: OTPAuth.accounts(from: payload))
    }
    if incoming.isEmpty {
        die("В QR не нашлось поддерживаемых TOTP-аккаунтов " +
            "(HOTP и неподдерживаемые записи пропускаются).", code: 1)
    }
    if !incoming.allSatisfy({ $0.isValid }) {
        die("В QR обнаружены неподдерживаемые или повреждённые данные.", code: 1)
    }

    let result = mergeIntoVault(incoming)
    print("Найдено TOTP-аккаунтов: \(incoming.count). " +
          "Добавлено \(result.added), обновлено \(result.updated).")
    for account in incoming {
        print("  • \(account.issuer) / \(account.label)")
    }
}

// MARK: - Shared helpers (CLI + GUI)

/// Извлекает строки всех QR-кодов из картинки через Vision. Пустой массив — не нашёл.
func scanQRCodes(atPath path: String) -> [String] {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return []
    }

    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
        try handler.perform([request])
    } catch {
        return []
    }
    return (request.results ?? []).compactMap { $0.payloadStringValue }
}

/// Merge по Account.id. Возвращает сколько добавлено/обновлено.
@discardableResult
func mergeIntoVault(_ incoming: [Account]) -> (added: Int, updated: Int) {
    let vault = KeychainVaultStore()
    var current: [Account]
    switch vault.load() {
    case .success(.missing):
        current = []
    case .success(.loaded(let accounts)):
        current = accounts
    case .failure(let error):
        die(error.errorDescription ?? "Не удалось прочитать Keychain", code: 1)
    }

    var added = 0
    var updated = 0
    for account in incoming {
        if let index = current.firstIndex(where: { $0.id == account.id }) {
            current[index] = account
            updated += 1
        } else {
            current.append(account)
            added += 1
        }
    }

    if case .failure(let error) = vault.save(current) {
        die(error.errorDescription ?? "Не удалось записать в Keychain", code: 1)
    }
    return (added, updated)
}
