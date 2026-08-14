import Foundation

enum CursorCookie {
    // 与 cardputer buildCursorCookie 一致：WorkosCursorSessionToken
    static func headerValue(from token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("::") || trimmed.contains("%3A%3A") {
            let encoded = trimmed.replacingOccurrences(of: "::", with: "%3A%3A")
            return "WorkosCursorSessionToken=\(encoded)"
        }

        guard let sub = jwtSub(trimmed) else { return nil }
        return "WorkosCursorSessionToken=\(sub)%3A%3A\(trimmed)"
    }

    // JWT payload 里的 sub，用于拼接 Cookie
    private static func jwtSub(_ token: String) -> String? {
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
