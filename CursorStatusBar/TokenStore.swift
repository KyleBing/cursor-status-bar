import Foundation
import Security

enum TokenStore {
    private static let service = "com.kylebing.CursorStatusBar"
    private static let account = "cursor.token"
    // DeepSeek API key 与 Cursor token 分开存放
    private static let deepSeekAccount = "deepseek.apiKey"
    // DeepSeek 开放平台网页登录 token（读平台用量接口用，不是 API key）
    private static let deepSeekPlatformAccount = "deepseek.platformToken"
    // 平台接口可能需要浏览器 cookie，随 token 一起保存（可空）
    private static let deepSeekPlatformCookieAccount = "deepseek.platformCookie"

    private static let allAccounts = [
        account,
        deepSeekAccount,
        deepSeekPlatformAccount,
        deepSeekPlatformCookieAccount
    ]

    // 进程内缓存，避免重复读盘
    private static var memory: [String: String]?

    static func load() -> String? {
        load(forAccount: account)
    }

    static func save(_ token: String) {
        save(token, forAccount: account)
    }

    static func delete() {
        delete(forAccount: account)
    }

    static func loadDeepSeekKey() -> String? {
        load(forAccount: deepSeekAccount)
    }

    static func saveDeepSeekKey(_ key: String) {
        save(key, forAccount: deepSeekAccount)
    }

    static func deleteDeepSeekKey() {
        delete(forAccount: deepSeekAccount)
    }

    // 平台会话 token 用于查询账号维度的用量历史
    static func loadDeepSeekPlatformToken() -> String? {
        load(forAccount: deepSeekPlatformAccount)
    }

    static func saveDeepSeekPlatformToken(_ token: String) {
        save(token, forAccount: deepSeekPlatformAccount)
    }

    static func deleteDeepSeekPlatformToken() {
        delete(forAccount: deepSeekPlatformAccount)
    }

    // 平台接口需要的 cookie（从 Copy as cURL 里解析出来）
    static func loadDeepSeekPlatformCookie() -> String? {
        load(forAccount: deepSeekPlatformCookieAccount)
    }

    static func saveDeepSeekPlatformCookie(_ cookie: String) {
        save(cookie, forAccount: deepSeekPlatformCookieAccount)
    }

    static func deleteDeepSeekPlatformCookie() {
        delete(forAccount: deepSeekPlatformCookieAccount)
    }

    // MARK: - 本地文件（不再走钥匙串，避免每次启动弹系统密码）

    private static func load(forAccount account: String) -> String? {
        let value = loadAll()[account]
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func save(_ value: String, forAccount account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var all = loadAll()
        if trimmed.isEmpty {
            all.removeValue(forKey: account)
        } else {
            all[account] = trimmed
        }
        persist(all)
        // 清掉旧钥匙串项，防止下次又弹 ACL 密码框
        deleteKeychain(forAccount: account)
    }

    private static func delete(forAccount account: String) {
        var all = loadAll()
        all.removeValue(forKey: account)
        persist(all)
        deleteKeychain(forAccount: account)
    }

    private static func loadAll() -> [String: String] {
        if let memory { return memory }
        if let fromFile = readFile() {
            memory = fromFile
            return fromFile
        }
        // 首次：从旧钥匙串迁出（可能弹一次密码），之后只读本地文件
        let migrated = migrateFromKeychain()
        memory = migrated
        return migrated
    }

    private static func persist(_ values: [String: String]) {
        memory = values
        writeFile(values)
    }

    private static var supportDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return root.appendingPathComponent(service, isDirectory: true)
    }

    private static var credentialsURL: URL {
        supportDirectory.appendingPathComponent("credentials.json")
    }

    private static func readFile() -> [String: String]? {
        let url = credentialsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in obj {
            if let s = value as? String, !s.isEmpty {
                out[key] = s
            }
        }
        return out
    }

    private static func writeFile(_ values: [String: String]) {
        let dir = supportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = credentialsURL
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
        // 仅当前用户可读
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    // 把旧版钥匙串凭证搬到本地文件，并删除钥匙串项
    private static func migrateFromKeychain() -> [String: String] {
        var migrated: [String: String] = [:]
        for account in allAccounts {
            if let value = loadKeychain(forAccount: account), !value.isEmpty {
                migrated[account] = value
            }
            deleteKeychain(forAccount: account)
        }
        if !migrated.isEmpty {
            writeFile(migrated)
        } else {
            // 写入空文件，标记已完成迁移，避免每次启动再扫钥匙串
            writeFile([:])
        }
        return migrated
    }

    // MARK: - 旧钥匙串（仅迁移 / 清理）

    private static func loadKeychain(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteKeychain(forAccount account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
