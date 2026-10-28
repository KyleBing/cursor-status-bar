import Foundation
import SQLite3
import Security
import CommonCrypto

enum CursorLocalToken {
    enum ImportError: LocalizedError {
        case cursorNotInstalled
        case dbMissing
        case openFailed
        case tokenMissing
        case keychainRefused
        case decryptFailed

        var errorDescription: String? {
            switch self {
            case .cursorNotInstalled: return String(localized: "Cursor is not installed")
            case .dbMissing: return String(localized: "Cursor local database not found")
            case .openFailed: return String(localized: "Cannot read Cursor database")
            case .tokenMissing: return String(localized: "No accessToken in Cursor database; sign in to Cursor first")
            case .keychainRefused: return String(localized: "Keychain denied Cursor Safe Storage; click Always Allow and import again")
            case .decryptFailed: return String(localized: "Cannot decrypt Cursor accessToken; sign in to Cursor again")
            }
        }
    }

    // 本机 Cursor 当前登录：token + 邮箱 + 会员类型（用来区分旧套餐 / 融合）
    struct LocalProfile: Equatable {
        var token: String
        var email: String?
        var membershipType: String?
    }

    // Cursor 桌面端默认安装路径
    private static let appPath = "/Applications/Cursor.app"
    private static let tokenKey = "cursorAuth/accessToken"
    private static let emailKey = "cursorAuth/cachedEmail"
    private static let membershipKey = "cursorAuth/stripeMembershipType"
    // 新版 Cursor 开启 authTokenEncryptionAtRest 后的密封前缀
    private static let sealedPrefix = "cursor-safe-storage:v1:"
    // Electron safeStorage / Chromium OSCrypt 的 Keychain 项
    private static let keychainService = "Cursor Safe Storage"
    // Pulse 用 Cursor Key；CodexBar 文档写 Cursor，两者都试
    private static let keychainAccounts = ["Cursor Key", "Cursor"]

    static var isCursorInstalled: Bool {
        FileManager.default.fileExists(atPath: appPath)
            || FileManager.default.fileExists(atPath: dbURL.path)
    }

    static var dbURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    // SQLite 复制绑定字符串，避免 Swift 临时 CString 在 step 前被释放
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // 从本机 Cursor state.vscdb 读取 accessToken（只读；优先 immutable 避开 WAL 锁）
    static func readAccessToken() -> Result<String, ImportError> {
        guard isCursorInstalled else { return .failure(.cursorNotInstalled) }
        let path = dbURL.path
        guard FileManager.default.fileExists(atPath: path) else { return .failure(.dbMissing) }

        var db: OpaquePointer?
        // immutable 优先：Cursor 运行时 WAL 占用也不会挡住只读快照
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let openAttempts: [(String, Int32)] = [
            ("file://\(encoded)?mode=ro&immutable=1", SQLITE_OPEN_READONLY | SQLITE_OPEN_URI),
            ("file://\(encoded)?mode=ro", SQLITE_OPEN_READONLY | SQLITE_OPEN_URI),
            (path, SQLITE_OPEN_READONLY),
        ]
        var opened = false
        for (filename, flags) in openAttempts {
            if sqlite3_open_v2(filename, &db, flags, nil) == SQLITE_OK, db != nil {
                opened = true
                break
            }
            if let db { sqlite3_close(db) }
            db = nil
        }
        guard opened, let db else { return .failure(.openFailed) }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return .failure(.openFailed)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, tokenKey, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return .failure(.tokenMissing) }

        // TEXT 或 UTF-16LE BLOB（无 BOM）都能读
        guard let raw = columnText(stmt, 0) else { return .failure(.tokenMissing) }
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 {
            token = String(token.dropFirst().dropLast())
        }
        guard !token.isEmpty else { return .failure(.tokenMissing) }
        return unwrapStored(token)
    }

    // 明文 JWT/token 原样返回；cursor-safe-storage:v1: 密文用 Keychain 解封
    static func unwrapStored(_ value: String) -> Result<String, ImportError> {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(sealedPrefix) else { return .success(trimmed) }
        guard let password = safeStoragePassword() else { return .failure(.keychainRefused) }
        guard let plain = decryptSafeStorage(trimmed, password: password), !plain.isEmpty else {
            return .failure(.decryptFailed)
        }
        return .success(plain)
    }

    // MARK: - SQLite column

    private static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        let type = sqlite3_column_type(stmt, index)
        if type == SQLITE_TEXT {
            guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: cStr)
        }
        if type == SQLITE_BLOB {
            guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, index))
            let data = Data(bytes: bytes, count: count)
            // UTF-16LE（无 BOM）：ASCII 范围第二字节为 0
            if count >= 2, count.isMultiple(of: 2), data[0] != 0, data[1] == 0,
               let wide = String(data: data, encoding: .utf16LittleEndian) {
                return wide
            }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    // MARK: - Keychain + OSCrypt

    // 读 Cursor Safe Storage 主密码（触发系统授权弹窗；选「始终允许」后不再打扰）
    private static func safeStoragePassword() -> String? {
        for account in keychainAccounts {
            if let pw = readKeychainPassword(service: keychainService, account: account) {
                return pw
            }
        }
        return readKeychainPassword(service: keychainService, account: nil)
    }

    private static func readKeychainPassword(service: String, account: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // cursor-safe-storage:v1: + base64(v10 || AES-128-CBC ciphertext)
    private static func decryptSafeStorage(_ sealed: String, password: String) -> String? {
        let encoded = String(sealed.dropFirst(sealedPrefix.count))
        guard let blob = Data(base64Encoded: encoded) else { return nil }
        guard blob.count > 3, String(data: blob.prefix(3), encoding: .utf8) == "v10" else { return nil }
        let key = deriveOSCryptKey(password: password)
        guard let plain = aes128CBCDecrypt(Data(blob.dropFirst(3)), key: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    // Chromium macOS OSCrypt：PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16)
    private static func deriveOSCryptKey(password: String) -> Data {
        let salt = Array("saltysalt".utf8)
        var out = [UInt8](repeating: 0, count: 16)
        let pwBytes = Array(password.utf8)
        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            pwBytes, pwBytes.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003,
            &out, out.count
        )
        return Data(out)
    }

    // AES-128-CBC，IV = 16 个空格（0x20），PKCS7
    private static func aes128CBCDecrypt(_ ciphertext: Data, key: Data) -> Data? {
        guard !ciphertext.isEmpty, key.count == kCCKeySizeAES128 else { return nil }
        var iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var moved: size_t = 0
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            ciphertext.withUnsafeBytes { ctBytes in
                guard let keyPtr = keyBytes.baseAddress, let ctPtr = ctBytes.baseAddress else {
                    return CCCryptorStatus(kCCParamError)
                }
                return CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyPtr, key.count,
                    &iv,
                    ctPtr, ciphertext.count,
                    &out, out.count,
                    &moved
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(moved))
    }
}
