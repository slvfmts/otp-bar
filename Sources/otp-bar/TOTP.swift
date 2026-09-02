import Foundation
import CryptoKit

struct AccountID: Hashable {
    let issuer: String
    let label: String
}

/// One TOTP account, as stored in the Keychain vault.
struct Account: Codable, Identifiable, Equatable {
    var id: AccountID { AccountID(issuer: issuer, label: label) }
    var issuer: String          // service name
    var label: String           // account name
    var secret: String          // base32-encoded seed
    var digits: Int             // usually 6
    var period: Int             // usually 30
    var algorithm: String       // "SHA1" | "SHA256" | "SHA512"

    init(issuer: String, label: String, secret: String,
         digits: Int = 6, period: Int = 30, algorithm: String = "SHA1") {
        self.issuer = issuer
        self.label = label
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    var hasDisplayIdentity: Bool {
        !issuer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isValid: Bool {
        hasDisplayIdentity &&
            TOTP.base32Decode(secret) != nil &&
            (digits == 6 || digits == 8) &&
            (1...300).contains(period) &&
            ["SHA1", "SHA256", "SHA512"].contains(algorithm.uppercased())
    }
}

enum TOTP {
    /// Current code for an account at the given absolute time.
    static func code(for account: Account, at date: Date = Date()) -> String {
        guard account.isValid, let key = base32Decode(account.secret) else { return "------" }
        let counter = UInt64(date.timeIntervalSince1970) / UInt64(max(account.period, 1))
        var bigEndian = counter.bigEndian
        let counterData = Data(bytes: &bigEndian, count: 8)

        let digest: [UInt8]
        switch account.algorithm.uppercased() {
        case "SHA256":
            digest = Array(HMAC<SHA256>.authenticationCode(for: counterData, using: SymmetricKey(data: key)))
        case "SHA512":
            digest = Array(HMAC<SHA512>.authenticationCode(for: counterData, using: SymmetricKey(data: key)))
        case "SHA1":
            digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: SymmetricKey(data: key)))
        default:
            return "------"
        }

        let offset = Int(digest[digest.count - 1] & 0x0f)
        let binary = (UInt32(digest[offset] & 0x7f) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])
        let mod: UInt32 = account.digits == 8 ? 100_000_000 : 1_000_000
        let number = binary % mod
        return String(format: "%0\(account.digits)d", number)
    }

    /// Seconds remaining in the current TOTP window.
    static func secondsRemaining(period: Int, at date: Date = Date()) -> Int {
        let p = max(period, 1)
        return p - (Int(date.timeIntervalSince1970) % p)
    }

    /// RFC 4648 base32 encode, uppercase, БЕЗ padding "=" (формат otpauth-секретов).
    /// После каждого символа маскируем `value` до накопленных `bits` — иначе на длинных
    /// семенах буфер растёт без границ и переполняет Int (trap в debug).
    static func base32Encode(_ bytes: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var bits = 0
        var value = 0
        for b in bytes {
            value = (value << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(value >> bits) & 0x1f])
            }
            value &= (1 << bits) - 1
        }
        if bits > 0 {
            output.append(alphabet[(value << (5 - bits)) & 0x1f])
        }
        return output
    }

    /// RFC 4648 base32 decode (case-insensitive, tolerates separators and "=" padding).
    static func base32Decode(_ input: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var lookup = [Character: UInt8]()
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt8(i) }

        var cleaned = ""
        var paddingCount = 0
        var sawPadding = false
        for character in input.uppercased() {
            if character.isWhitespace || character == "-" {
                continue
            }
            if character == "=" {
                sawPadding = true
                paddingCount += 1
                continue
            }
            guard !sawPadding, lookup[character] != nil else { return nil }
            cleaned.append(character)
        }
        guard !cleaned.isEmpty else { return nil }
        let remainder = cleaned.count % 8
        guard ![1, 3, 6].contains(remainder) else { return nil }
        if paddingCount > 0 && paddingCount != (8 - remainder) % 8 {
            return nil
        }

        var bits = 0
        var value = 0
        var output = [UInt8]()
        for c in cleaned {
            guard let v = lookup[c] else { return nil }
            value = (value << 5) | Int(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((value >> bits) & 0xff))
                value &= (1 << bits) - 1   // не копим биты сверх нужного — защита от переполнения Int
            }
        }

        // RFC 4648 requires unused padding bits to be zero. Rejecting them avoids
        // silently accepting malformed secrets that decode to a different seed.
        if bits > 0 && value != 0 { return nil }
        return output.isEmpty ? nil : Data(output)
    }
}
