import Foundation

/// Разбор otpauth-ссылок из QR в [Account].
///
/// Поддерживает два формата:
///   • otpauth://totp/LABEL?secret=...&issuer=...&algorithm=...&digits=...&period=...
///     — одиночный аккаунт (QR конкретного сервиса при подключении 2FA);
///   • otpauth-migration://offline?data=<base64> — экспорт Google Authenticator
///     (несколько аккаунтов; protobuf MigrationPayload).
///
/// Единый источник правды для CLI (importqr) и GUI с проверками границ буфера.
///
/// ВАЖНО: ничего из секретов (secret/base32/otpauth-URL/QR-строка) не логируется.
enum OTPAuth {

    /// Разбирает одну QR-строку. Невалидные/неподдерживаемые записи пропускаются
    /// (не бросает на «мусоре» — возвращает то, что удалось распознать).
    static func accounts(from payload: String) -> [Account] {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("otpauth-migration://") {
            return migrationAccounts(from: trimmed)
        } else if lower.hasPrefix("otpauth://") {
            if let acc = singleAccount(from: trimmed) { return [acc] }
            return []
        }
        return []
    }

    // MARK: - otpauth://totp (одиночный)

    private static func singleAccount(from urlString: String) -> Account? {
        guard let comps = URLComponents(string: urlString) else { return nil }
        // Тип: только TOTP. HOTP (otpauth://hotp/...) пропускаем.
        guard comps.host?.lowercased() == "totp" else { return nil }

        let items = comps.queryItems ?? []
        func q(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value
        }

        // secret обязателен и должен декодироваться как base32.
        guard let rawSecret = q("secret"),
              !rawSecret.isEmpty,
              TOTP.base32Decode(rawSecret) != nil else { return nil }

        // Label = path без ведущего "/", percent-decoded. Может быть "Issuer:account".
        var label = comps.path
        if label.hasPrefix("/") { label.removeFirst() }

        var issuerFromLabel = ""
        if let colon = label.firstIndex(of: ":") {
            issuerFromLabel = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
            label = String(label[label.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        // If both forms are present, the explicit query issuer takes precedence.
        let issuerFromQuery = q("issuer") ?? ""
        let issuer = !issuerFromQuery.isEmpty ? issuerFromQuery
                   : (!issuerFromLabel.isEmpty ? issuerFromLabel : label)

        let algorithm: String
        if let rawAlgorithm = q("algorithm") {
            guard let normalized = normalizeAlgorithm(rawAlgorithm) else { return nil }
            algorithm = normalized
        } else {
            algorithm = "SHA1"
        }

        guard let digits = parseDigits(q("digits")),
              let period = parsePeriod(q("period")) else { return nil }

        let account = Account(issuer: issuer, label: label, secret: rawSecret.uppercased(),
                              digits: digits, period: period, algorithm: algorithm)
        return account.isValid ? account : nil
    }

    // MARK: - otpauth-migration:// (Google Authenticator export)

    private static func migrationAccounts(from urlString: String) -> [Account] {
        guard let comps = URLComponents(string: urlString),
              let dataValue = comps.queryItems?.first(where: { $0.name == "data" })?.value
        else { return [] }

        // URLComponents уже percent-декодирует value. Восстанавливаем стандартный
        // base64 (на случай URL-safe вариаций) и добавляем padding.
        var b64 = dataValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = b64.count % 4
        if pad != 0 { b64.append(String(repeating: "=", count: 4 - pad)) }

        guard let data = Data(base64Encoded: b64) else { return [] }

        guard let payload = parsePayload([UInt8](data)) else { return [] }

        var accounts: [Account] = []
        for otp in payload {
            guard otp.type == 2 else { continue }            // только TOTP, HOTP скип
            guard !otp.secret.isEmpty else { continue }
            guard let algorithm = algoMap[otp.algorithm],
                  let normalizedAlgorithm = normalizeAlgorithm(algorithm),
                  let digits = digitsMap[otp.digits] else { continue }

            let issuer = !otp.issuer.isEmpty ? otp.issuer
                       : (!otp.name.isEmpty ? otp.name : "unknown")
            let account = Account(
                issuer: issuer,
                label: otp.name,
                secret: TOTP.base32Encode(otp.secret),
                digits: digits,
                period: 30,                                   // GA не экспортирует period
                algorithm: normalizedAlgorithm
            )
            if account.isValid {
                accounts.append(account)
            }
        }
        return accounts
    }

    private static let algoMap: [Int: String] =
        [0: "SHA1", 1: "SHA1", 2: "SHA256", 3: "SHA512", 4: "MD5"]
    private static let digitsMap: [Int: Int] = [0: 6, 1: 6, 2: 8]

    // MARK: - Минимальный protobuf-парсер (только нужные поля)

    private struct OtpParameters {
        var secret: [UInt8] = []
        var name = ""
        var issuer = ""
        var algorithm = 1
        var digits = 1
        var type = 2
    }

    /// Читает varint (до 64 бит) с защитой от выхода за границы и зацикливания.
    /// Возвращает nil при повреждённом буфере.
    private static func readVarint(_ buf: [UInt8], _ i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < buf.count {
            let b = buf[i]
            i += 1
            if shift == 63 && b > 1 { return nil }
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }                    // защита от бесконечного varint
        }
        return nil                                            // дошли до конца без терминатора
    }

    /// Читает length-varint и проверяет, что он укладывается в остаток буфера.
    /// Возврат — валидная длина в Int (без риска переполнения при Int(len)).
    private static func readLength(_ buf: [UInt8], _ i: inout Int) -> Int? {
        guard let len = readVarint(buf, &i) else { return nil }
        guard i <= buf.count else { return nil }
        guard len <= UInt64(buf.count - i) else { return nil }   // не выходит за остаток
        return Int(len)
    }

    /// Пропускает значение поля по wire type. false — невалидный/неподдерживаемый wire.
    private static func skipField(_ buf: [UInt8], _ i: inout Int, wire: Int) -> Bool {
        switch wire {
        case 0:                                               // varint
            return readVarint(buf, &i) != nil
        case 1:                                               // 64-bit
            guard i + 8 <= buf.count else { return false }
            i += 8; return true
        case 2:                                               // length-delimited
            guard let n = readLength(buf, &i) else { return false }
            i += n; return true
        case 5:                                               // 32-bit
            guard i + 4 <= buf.count else { return false }
            i += 4; return true
        default:
            return false
        }
    }

    private static func parseOtp(_ buf: [UInt8]) -> OtpParameters? {
        var out = OtpParameters()
        var i = 0
        let n = buf.count
        while i < n {
            guard let tag = readVarint(buf, &i) else { return nil }
            guard tag != 0 else { return nil }
            let field = Int(clamping: tag >> 3)
            let wire = Int(tag & 7)
            guard field > 0 else { return nil }
            if wire == 2 {
                guard let length = readLength(buf, &i) else { return nil }
                let chunk = Array(buf[i..<i + length])
                i += length
                switch field {
                case 1: out.secret = chunk
                case 2:
                    guard let name = String(bytes: chunk, encoding: .utf8) else { return nil }
                    out.name = name
                case 3:
                    guard let issuer = String(bytes: chunk, encoding: .utf8) else { return nil }
                    out.issuer = issuer
                default: break                                // unknown length-delimited
                }
            } else if wire == 0 {
                guard let val = readVarint(buf, &i) else { return nil }
                switch field {
                case 4: out.algorithm = Int(clamping: val)
                case 5: out.digits = Int(clamping: val)
                case 6: out.type = Int(clamping: val)
                default: break                                // в т.ч. 7=counter (HOTP)
                }
            } else {
                guard skipField(buf, &i, wire: wire) else { return nil }
            }
        }
        return out
    }

    /// MigrationPayload: поле 1 (length-delimited) = OtpParameters.
    private static func parsePayload(_ data: [UInt8]) -> [OtpParameters]? {
        var items: [OtpParameters] = []
        var i = 0
        let n = data.count
        while i < n {
            guard let tag = readVarint(data, &i), tag != 0 else { return nil }
            let field = Int(clamping: tag >> 3)
            let wire = Int(tag & 7)
            guard field > 0 else { return nil }
            if wire == 2 {
                guard let length = readLength(data, &i) else { return nil }
                let chunk = Array(data[i..<i + length])
                i += length
                if field == 1 {
                    guard let otp = parseOtp(chunk) else { return nil }
                    items.append(otp)
                }
            } else {
                guard skipField(data, &i, wire: wire) else { return nil }
            }
        }
        return items
    }

    // MARK: - Хелперы валидации

    /// Только реально поддерживаемые TOTP-алгоритмы. MD5/неизвестное → nil (caller → SHA1/skip).
    private static func normalizeAlgorithm(_ raw: String?) -> String? {
        switch raw?.uppercased() {
        case "SHA1": return "SHA1"
        case "SHA256": return "SHA256"
        case "SHA512": return "SHA512"
        default: return nil
        }
    }

    private static func parseDigits(_ raw: String?) -> Int? {
        guard let raw else { return 6 }
        guard let digits = Int(raw), digits == 6 || digits == 8 else { return nil }
        return digits
    }

    private static func parsePeriod(_ raw: String?) -> Int? {
        guard let raw else { return 30 }
        guard let period = Int(raw), period > 0, period <= 300 else { return nil }
        return period
    }
}
