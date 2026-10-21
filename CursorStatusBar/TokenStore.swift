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

    private static func load(forAccount account: String) -> String? {
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

    private static func save(_ value: String, forAccount account: String) {
        delete(forAccount: account)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private static func delete(forAccount account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
