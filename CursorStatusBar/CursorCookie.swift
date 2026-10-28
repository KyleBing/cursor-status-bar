import Foundation

// Cursor 鉴权：桌面端 accessToken 走 api2 Bearer；浏览器 WorkosCookie 走 cursor.com Cookie
enum CursorAuth: Equatable {
    case bearer(String)
    case cookie(String)
}

enum CursorCookie {
    // 解析用户粘贴 / 本地导入的 token，选 Bearer 或 Cookie
    static func resolve(_ raw: String) -> CursorAuth? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 密封串须先经 CursorLocalToken.unwrapStored，不能直接当凭证
        guard !trimmed.hasPrefix("cursor-safe-storage:v1:") else { return nil }

        // 已是完整 Cookie 头
        if trimmed.lowercased().hasPrefix("workoscursorsessiontoken=") {
            return .cookie(trimmed)
        }

        // 浏览器复制的 userId::jwt / userId%3A%3Ajwt → cursor.com Cookie
        if trimmed.contains("::") || trimmed.contains("%3A%3A") {
            let encoded = trimmed.replacingOccurrences(of: "::", with: "%3A%3A")
            return .cookie("WorkosCursorSessionToken=\(encoded)")
        }

        // 本机 Cursor accessToken（含新格式）以及普通 JWT：优先 api2 Bearer
        // 旧版 JWT 若需要 Cookie，可由 jwt 再拼；新 token 非 JWT，只能 Bearer
        return .bearer(trimmed)
    }

    // 兼容旧调用：仅当能构成 Workos Cookie 时返回
    static func headerValue(from token: String) -> String? {
        switch resolve(token) {
        case .cookie(let cookie):
            return cookie
        case .bearer(let bearer):
            // 旧 JWT：仍可拼成 Cookie，供 cursor.com 回退
            guard let sub = jwtSub(bearer) else { return nil }
            return "WorkosCursorSessionToken=\(sub)%3A%3A\(bearer)"
        case .none:
            return nil
        }
    }

    // JWT payload 里的 sub，用于拼接 Cookie
    static func jwtSub(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String,
              !sub.isEmpty
        else { return nil }
        return sub
    }
}
