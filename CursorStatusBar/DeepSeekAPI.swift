import Foundation

// MARK: - 错误

enum DeepSeekAPIError: LocalizedError {
    case missingKey
    case http(code: Int, message: String)
    case decode(String)
    // 平台网页 token 失效（平台返回 40003），需要重新复制
    case invalidPlatformToken
    // API key 被删除或填错（/user/balance 返回 401）
    case invalidAPIKey
    // 触发限流或 WAF，稍后再试
    case rateLimited
    // 被 platform.deepseek.com 前面的 WAF 拦截（403），不是 token 失效
    case wafBlocked

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return String(localized: "DeepSeek API key not set")
        case .http(let code, let message):
            return message.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(message)"
        case .decode(let message):
            return "JSON decode failed: \(message)"
        case .invalidPlatformToken:
            return String(localized: "Platform token invalid or expired. Click “Sign in again” to reload it from platform.deepseek.com.")
        case .invalidAPIKey:
            return String(localized: "API key invalid or deleted. Check platform.deepseek.com/api_keys.")
        case .rateLimited:
            return String(localized: "Too many requests. Try again later.")
        case .wafBlocked:
            return String(localized: "Blocked by the platform firewall. Sign in at platform.deepseek.com in a browser, then retry.")
        }
    }
}

// MARK: - 余额

struct DeepSeekBalanceInfo: Decodable, Equatable, Identifiable {
    var currency: String
    var totalBalance: String
    var grantedBalance: String
    var toppedUpBalance: String

    var id: String { currency }

    private enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}

struct DeepSeekBalance: Decodable, Equatable {
    var isAvailable = false
    var infos: [DeepSeekBalanceInfo] = []

    private enum Keys: String, CodingKey {
        case isAvailable = "is_available"
        case infos = "balance_infos"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? false
        infos = try container.decodeIfPresent([DeepSeekBalanceInfo].self, forKey: .infos) ?? []
    }
}

// MARK: - 平台用量

// platform.deepseek.com/api/v0/usage/by_api_key/amount 返回的单个时间桶
// 需要网页登录 token（localStorage.userToken），API key 无法访问该接口
struct DeepSeekPlatformBucket: Equatable, Identifiable {
    var id = UUID().uuidString
    var timestamp: Int
    var model: String
    var requests: Int
    var cacheHitTokens: Int
    var cacheMissTokens: Int
    var responseTokens: Int

    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
    var promptTokens: Int { cacheHitTokens + cacheMissTokens }
    var totalTokens: Int { promptTokens + responseTokens }
}

// MARK: - 平台响应的宽容解析

// 平台接口的字段类型并不稳定：biz_data.bucket 是数字（86400）而不是字符串，
// series 里还带 api_key / models 等额外字段，计数可能是数字、字符串或 {"value": ...}。
// 用 Decodable 严格匹配时，任何一个字段类型不符都会让整包失败（界面只显示「格式不正确」），
// 所以这里改用 JSONSerialization 按结构取数，单个字段类型不符时只跳过它。
private enum PlatformPayload {
    struct Meta {
        // 顶层业务码与错误文案
        var code = 0
        var bizCode = 0
        var message = ""
        // biz_data，接口报错时通常为 null
        var body: [String: Any]?
        // 原始 JSON，仅用于把字段结构写进日志
        var root: [String: Any] = [:]
    }

    // 解析顶层 code / biz_code / biz_msg；返回 nil 表示响应根本不是 JSON
    static func meta(from data: Data) -> Meta? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }

        var meta = Meta()
        meta.root = root
        meta.code = int(root["code"]) ?? 0
        let payload = root["data"] as? [String: Any]
        meta.bizCode = int(payload?["biz_code"]) ?? 0
        // msg 与 biz_msg 常有一个是空串，取第一个非空文案
        meta.message = [root["msg"], payload?["biz_msg"]]
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        meta.body = payload?["biz_data"] as? [String: Any]
        return meta
    }

    // 从 biz_data 里找出所有时间桶；series 可能按 api_key 再嵌套一层，递归即可覆盖
    static func buckets(from body: [String: Any]?) -> [DeepSeekPlatformBucket] {
        guard let body else { return [] }
        var result: [DeepSeekPlatformBucket] = []
        collect(in: body, model: "", into: &result)
        return result
    }

    // 把 JSON 结构压成一行（数组只看第一个元素、最多 4 层），不含具体数值，便于核对接口字段
    static func structure(_ value: Any, depth: Int = 0) -> String {
        guard depth < 4 else { return "…" }
        if let dict = value as? [String: Any] {
            let parts = dict.keys.sorted().map { key in
                "\(key):\(structure(dict[key] as Any, depth: depth + 1))"
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
        if let array = value as? [Any] {
            return array.isEmpty ? "[]" : "[\(structure(array[0], depth: depth + 1))]"
        }
        if value is String { return "string" }
        if value is NSNumber { return "number" }
        if value is NSNull { return "null" }
        return "unknown"
    }

    // MARK: 内部

    private static func collect(in node: [String: Any], model: String, into result: inout [DeepSeekPlatformBucket]) {
        // 模型名可能在 series 层，也可能在单个时间桶里
        let model = node["model"] as? String ?? model
        if let items = node["buckets"] as? [Any] {
            for item in items {
                guard let bucket = item as? [String: Any],
                      let timestamp = int(bucket["time"])
                else { continue }
                let bucketModel = bucket["model"] as? String ?? model
                result.append(makeBucket(bucket, timestamp: timestamp, model: bucketModel))
            }
            return
        }
        // 已知可能的嵌套键；结构变化时多覆盖几个名字，取不到就自然返回空
        for key in ["series", "usage_by_model", "buckets_by_model", "sub_series", "list"] {
            guard let items = node[key] as? [Any] else { continue }
            for item in items {
                if let child = item as? [String: Any] {
                    collect(in: child, model: model, into: &result)
                }
            }
        }
    }

    private static func makeBucket(
        _ bucket: [String: Any],
        timestamp: Int,
        model: String
    ) -> DeepSeekPlatformBucket {
        let usage = usageMap(bucket["usage"])
        let hit = int(usage["PROMPT_CACHE_HIT_TOKEN"]) ?? 0
        var miss = int(usage["PROMPT_CACHE_MISS_TOKEN"]) ?? 0
        // 旧接口只有 PROMPT_TOKEN，没有命中 / 未命中拆分
        let prompt = int(usage["PROMPT_TOKEN"]) ?? 0
        if hit + miss == 0, prompt > 0 { miss = prompt }
        return DeepSeekPlatformBucket(
            id: "\(timestamp)-\(model)-\(hit)-\(miss)",
            timestamp: timestamp,
            model: model,
            requests: int(usage["REQUEST"]) ?? int(usage["REQUEST_COUNT"]) ?? 0,
            cacheHitTokens: hit,
            cacheMissTokens: miss,
            responseTokens: int(usage["RESPONSE_TOKEN"]) ?? int(usage["COMPLETION_TOKEN"]) ?? 0
        )
    }

    // usage 可能是字典，也可能是 [{"name": "REQUEST", "value": 1}] 这样的数组
    private static func usageMap(_ value: Any?) -> [String: Any] {
        if let dict = value as? [String: Any] { return dict }
        guard let list = value as? [Any] else { return [:] }
        var result: [String: Any] = [:]
        for item in list {
            guard let entry = item as? [String: Any],
                  let name = entry["name"] as? String
            else { continue }
            result[name] = entry["value"]
        }
        return result
    }

    // 兼容数字、数字字符串与 {"value": ...} 三种计数写法
    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let text = value as? String {
            return Int(text) ?? Int(Double(text) ?? 0)
        }
        if let dict = value as? [String: Any] {
            return int(dict["value"])
        }
        return nil
    }
}

// MARK: - 调试日志

// 把平台返回的原始状态与响应片段写到 ~/Library/Logs/CursorStatusBar/deepseek.log。
// 只记状态码和响应正文，不记 token / cookie，出问题时可据此定位真实错误。
enum DeepSeekLog {
    static func write(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(text)\n"
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        else { return }
        let dir = library.appendingPathComponent("Logs/CursorStatusBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("deepseek.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    static var fileURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/CursorStatusBar/deepseek.log")
    }
}

// MARK: - API

final class DeepSeekAPI {
    private let session: URLSession
    private let decoder = JSONDecoder()

    private let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    // 平台网页内部用量接口，按 API key + 模型拆分时间桶
    private let platformUsageURL = URL(string: "https://platform.deepseek.com/api/v0/usage/by_api_key/amount")!

    // 传入 session 便于测试；默认使用放宽超时的会话
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // 查询账户余额
    func balance(apiKey: String) async throws -> DeepSeekBalance {
        guard !apiKey.isEmpty else { throw DeepSeekAPIError.missingKey }
        var request = URLRequest(url: balanceURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        // 记下原始响应，便于对照界面上被截断的错误
        DeepSeekLog.write("balance status=\(code) body=\(Self.bodyPreview(data))")
        guard (200..<300).contains(code) else {
            // 401/403 说明 key 无效；429 是限流，都不必把原始错误码抛给界面
            if code == 401 || code == 403 { throw DeepSeekAPIError.invalidAPIKey }
            if code == 429 { throw DeepSeekAPIError.rateLimited }
            throw Self.apiError(status: code, body: data)
        }
        do {
            return try decoder.decode(DeepSeekBalance.self, from: data)
        } catch {
            throw DeepSeekAPIError.decode(error.localizedDescription)
        }
    }

    // MARK: 平台用量

    // 查询账号维度的用量历史。token 为 platform.deepseek.com 的网页登录 token。
    // cookie 可为空；从浏览器 Copy as cURL 里解析出来时一并带上，兼容需要会话 cookie 的情况。
    // 注意：API key 调用该接口会返回 200 + code 40003，这里统一转成可读错误。
    func platformUsage(
        token: String,
        cookie: String = "",
        start: Date,
        end: Date
    ) async throws -> [DeepSeekPlatformBucket] {
        guard !token.isEmpty else {
            throw DeepSeekAPIError.http(code: 401, message: "Platform token not set")
        }
        var startSeconds = Int(start.timeIntervalSince1970)
        var endSeconds = Int(end.timeIntervalSince1970)
        if startSeconds > endSeconds { swap(&startSeconds, &endSeconds) }
        // tz 为本地时区偏移秒数，平台按该时区切日/小时桶
        let tz = TimeZone.current.secondsFromGMT(for: start)
        // 平台只接受按天对齐的区间：start 为起始日当地 00:00，end 为结束日次日的当地 00:00。
        // 直接传 now 这类时间点会返回 biz_code=1 INVALID_PARAM（这也是界面上只有「HTTP 1」的原因）。
        startSeconds = Self.localDayStart(seconds: startSeconds, tz: tz)
        endSeconds = Self.localDayStart(seconds: endSeconds, tz: tz) + 86_400
        // 左闭右开区间，兜底保证 end 晚于 start
        if endSeconds <= startSeconds { endSeconds = startSeconds + 86_400 }

        var components = URLComponents(url: platformUsageURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "start", value: "\(startSeconds)"),
            URLQueryItem(name: "end", value: "\(endSeconds)"),
            URLQueryItem(name: "tz", value: "\(tz)")
        ]
        guard let url = components?.url else {
            throw DeepSeekAPIError.http(code: -1, message: "Invalid usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web", forHTTPHeaderField: "x-client-platform")
        request.setValue("1.0.0", forHTTPHeaderField: "x-app-version")
        // 平台前面有 WAF，按网页端的实际请求补上 Origin / Referer，降低被拦概率
        request.setValue("https://platform.deepseek.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.deepseek.com/usage", forHTTPHeaderField: "Referer")
        // 有 cookie 时补上，网页端接口在部分账号上需要
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        // 先把原始返回落盘：token 失效、WAF 拦截、参数错误都会在这里露出真实文案。
        // token 只记长度与是否带 cookie，既能区分「换了凭证」又不泄露内容。
        DeepSeekLog.write(
            "usage status=\(status) start=\(startSeconds) end=\(endSeconds) tz=\(tz)"
                + " tokenLen=\(token.count) cookie=\(cookie.isEmpty ? "no" : "yes")"
                + " body=\(Self.bodyPreview(data))"
        )
        guard (200..<300).contains(status) else {
            // 403 是平台前面的 WAF（不是登录失效），401 才是 token 失效，429 是限流
            if status == 401 { throw DeepSeekAPIError.invalidPlatformToken }
            if status == 403 { throw DeepSeekAPIError.wafBlocked }
            if status == 429 { throw DeepSeekAPIError.rateLimited }
            throw Self.apiError(status: status, body: data)
        }

        guard let meta = PlatformPayload.meta(from: data) else {
            DeepSeekLog.write("usage decode failed (not JSON) body=\(Self.bodyPreview(data))")
            throw DeepSeekAPIError.decode(String(localized: "Response is not valid JSON"))
        }
        // 只记字段结构，不记具体数值；接口字段一变就能在日志里对照出来
        DeepSeekLog.write("usage structure=\(PlatformPayload.structure(meta.body ?? meta.root))")

        let appCode = meta.code
        let bizCode = meta.bizCode
        guard appCode == 0, bizCode == 0 else {
            let message = meta.message.isEmpty ? "Request failed" : meta.message
            DeepSeekLog.write("usage failed code=\(appCode) bizCode=\(bizCode) msg=\(message)")
            // 40003 是平台明确的「token 无效」，直接给出可操作提示，不显示原始错误码
            if appCode == 40003 || bizCode == 40003 {
                throw DeepSeekAPIError.invalidPlatformToken
            }
            throw DeepSeekAPIError.http(code: appCode != 0 ? appCode : bizCode, message: message)
        }

        let result = PlatformPayload.buckets(from: meta.body)
        // 解析出 0 条时也留一条日志，便于区分「真的没用量」和「字段结构又变了」
        DeepSeekLog.write(
            "usage parsed buckets=\(result.count) models=\(Set(result.map(\.model)).sorted().joined(separator: ","))"
        )
        return result
    }

    // MARK: 辅助

    // 把时间戳折算成「当地 00:00」对应的 UTC 秒；平台的时间边界都按 tz 对齐
    private static func localDayStart(seconds: Int, tz: Int) -> Int {
        let shifted = seconds + tz
        let remainder = ((shifted % 86_400) + 86_400) % 86_400
        return shifted - remainder - tz
    }

    // 响应正文片段，压缩换行并截断，日志里一眼能看清服务端说了什么
    private static func bodyPreview(_ data: Data, limit: Int = 400) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > limit ? String(single.prefix(limit)) + "…" : single
    }

    // 优先取 error.message，取不到再用响应文本
    private static func apiError(status: Int, body: Data) -> DeepSeekAPIError {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? ""
            let type = (error["type"] as? String) ?? ""
            let text = message.isEmpty ? type : message
            return .http(code: status, message: text)
        }
        let text = String(data: body, encoding: .utf8) ?? ""
        return .http(code: status, message: String(text.prefix(300)))
    }
}
