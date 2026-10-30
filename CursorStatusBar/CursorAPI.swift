import Foundation

enum CursorAPIError: LocalizedError {
    case missingToken
    case badCookie
    case http(Int)
    case decode
    case noUserId

    var errorDescription: String? {
        switch self {
        case .missingToken: return String(localized: "Token not set")
        case .badCookie: return String(localized: "Token cannot form Cookie")
        case .http(let code): return "HTTP \(code)"
        case .decode: return String(localized: "JSON decode failed")
        case .noUserId: return "no user id"
        }
    }
}

final class CursorAPI {
    private let session: URLSession
    private let webHost = URL(string: "https://cursor.com")!
    // 桌面端同一套 DashboardService（Connect JSON）
    private let apiHost = URL(string: "https://api2.cursor.sh")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public

    func authMe(auth: CursorAuth) async throws -> Int {
        switch auth {
        case .bearer(let token):
            return try await connectGetMe(token: token)
        case .cookie(let cookie):
            return try await webAuthMe(cookie: cookie)
        }
    }

    func periodUsage(auth: CursorAuth) async throws -> PeriodUsage {
        switch auth {
        case .bearer(let token):
            // 新套餐 / Unified：桌面端只走 api2 GetCurrentPeriodUsage
            return try await connectPeriodUsage(token: token)
        case .cookie(let cookie):
            do {
                let data = try await webRequest(
                    method: "POST",
                    path: "/api/dashboard/get-current-period-usage",
                    cookie: cookie,
                    body: Data("{}".utf8)
                )
                return try parsePeriod(data)
            } catch {
                let data = try await webRequest(method: "GET", path: "/api/usage-summary", cookie: cookie, body: nil)
                return try parsePeriod(data)
            }
        }
    }

    // Grok Bot 周用量；账号未开通或无额度时返回 nil，失败也当没有
    func grokBotUsage(auth: CursorAuth) async -> GrokBotUsage? {
        do {
            switch auth {
            case .bearer(let token):
                let data = try await connectRequest(
                    method: "GetSandUsageStatus",
                    token: token,
                    body: Data("{}".utf8)
                )
                return parseGrokBotUsage(data)
            case .cookie(let cookie):
                // 与周期用量同一套 dashboard 路径命名；没有该接口时吞掉错误
                let data = try await webRequest(
                    method: "POST",
                    path: "/api/dashboard/get-sand-usage-status",
                    cookie: cookie,
                    body: Data("{}".utf8)
                )
                return parseGrokBotUsage(data)
            }
        } catch {
            return nil
        }
    }

    func lastEvents(auth: CursorAuth, userId: Int, pageSize: Int = 20) async throws -> [UsageEvent] {
        let end = Date()
        let start = end.addingTimeInterval(-30 * 86400)
        return try await eventsPage(auth: auth, userId: userId, start: start, end: end, page: 1, pageSize: pageSize)
    }

    func allEvents(auth: CursorAuth, userId: Int, start: Date, end: Date) async throws -> [UsageEvent] {
        var page = 1
        var all: [UsageEvent] = []
        while true {
            let batch = try await eventsPage(
                auth: auth,
                userId: userId,
                start: start,
                end: end,
                page: page,
                pageSize: 200
            )
            if batch.isEmpty { break }
            all.append(contentsOf: batch)
            if batch.count < 200 { break }
            page += 1
            if page > 50 { break }
        }
        return all
    }

    // MARK: - api2 Connect (Bearer)

    private func connectGetMe(token: String) async throws -> Int {
        let data = try await connectRequest(
            method: "GetMe",
            token: token,
            body: Data("{}".utf8)
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorAPIError.decode
        }
        // Connect JSON：userId / user_id
        if let id = intVal(root["userId"]) ?? intVal(root["user_id"]) {
            return id
        }
        throw CursorAPIError.noUserId
    }

    private func connectPeriodUsage(token: String) async throws -> PeriodUsage {
        let data = try await connectRequest(
            method: "GetCurrentPeriodUsage",
            token: token,
            body: Data("{}".utf8)
        )
        return try parsePeriod(data)
    }

    private func connectEventsPage(
        token: String,
        userId: Int,
        start: Date,
        end: Date,
        page: Int,
        pageSize: Int
    ) async throws -> [UsageEvent] {
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let endMs = Int64(end.timeIntervalSince1970 * 1000)
        var bodyDict: [String: Any] = [
            "teamId": 0,
            "startDate": "\(startMs)",
            "endDate": "\(endMs)",
            "page": page,
            "pageSize": pageSize
        ]
        // userId 可选；有值时带上，过滤个人记录
        if userId > 0 {
            bodyDict["userId"] = userId
        }
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        let data = try await connectRequest(
            method: "GetFilteredUsageEvents",
            token: token,
            body: body
        )
        return parseEvents(data)
    }

    private func connectRequest(method: String, token: String, body: Data) async throws -> Data {
        let path = "/aiserver.v1.DashboardService/\(method)"
        guard let url = URL(string: path, relativeTo: apiHost)?.absoluteURL else {
            throw CursorAPIError.decode
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue("CursorStatusBar/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw CursorAPIError.http(code) }
        return data
    }

    // MARK: - cursor.com Cookie（浏览器粘贴 Workos token）

    private func webAuthMe(cookie: String) async throws -> Int {
        let data = try await webRequest(method: "GET", path: "/api/auth/me", cookie: cookie, body: nil)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let id = obj?["id"] as? Int { return id }
        if let id = obj?["id"] as? String, let n = Int(id) { return n }
        throw CursorAPIError.noUserId
    }

    private func webEventsPage(
        cookie: String,
        userId: Int,
        start: Date,
        end: Date,
        page: Int,
        pageSize: Int
    ) async throws -> [UsageEvent] {
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let endMs = Int64(end.timeIntervalSince1970 * 1000)
        let bodyDict: [String: Any] = [
            "teamId": 0,
            "startDate": "\(startMs)",
            "endDate": "\(endMs)",
            "userId": userId,
            "page": page,
            "pageSize": pageSize
        ]
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        let data = try await webRequest(
            method: "POST",
            path: "/api/dashboard/get-filtered-usage-events",
            cookie: cookie,
            body: body
        )
        return parseEvents(data)
    }

    private func eventsPage(
        auth: CursorAuth,
        userId: Int,
        start: Date,
        end: Date,
        page: Int,
        pageSize: Int
    ) async throws -> [UsageEvent] {
        switch auth {
        case .bearer(let token):
            return try await connectEventsPage(
                token: token,
                userId: userId,
                start: start,
                end: end,
                page: page,
                pageSize: pageSize
            )
        case .cookie(let cookie):
            return try await webEventsPage(
                cookie: cookie,
                userId: userId,
                start: start,
                end: end,
                page: page,
                pageSize: pageSize
            )
        }
    }

    private func webRequest(method: String, path: String, cookie: String, body: Data?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: webHost)?.absoluteURL else {
            throw CursorAPIError.decode
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("CursorStatusBar/1.0", forHTTPHeaderField: "User-Agent")
        if method == "POST" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            req.httpBody = body ?? Data("{}".utf8)
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw CursorAPIError.http(code) }
        return data
    }

    // MARK: - Parsing

    private func parsePeriod(_ data: Data) throws -> PeriodUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorAPIError.decode
        }
        var out = PeriodUsage()
        // planUsage / plan_usage；或 usage-summary 的 individualUsage.plan
        var plan = dictVal(root, "planUsage") ?? dictVal(root, "plan_usage")
        if plan == nil, let individual = dictVal(root, "individualUsage") ?? dictVal(root, "individual_usage") {
            plan = dictVal(individual, "plan")
        }
        if let plan {
            let auto = doubleVal(plan["autoPercentUsed"]) ?? doubleVal(plan["auto_percent_used"]) ?? 0
            let api = doubleVal(plan["apiPercentUsed"]) ?? doubleVal(plan["api_percent_used"]) ?? 0
            let total = doubleVal(plan["totalPercentUsed"]) ?? doubleVal(plan["total_percent_used"])
            out.remaining = doubleVal(plan["remaining"])
            out.limit = doubleVal(plan["limit"])
            out.totalPercentUsed = total
            // 无 Auto/API 拆分、只有 total → 融合套餐；圆环用 total 填 Auto 槽位
            if auto == 0, api == 0, let total {
                out.planKind = .unified
                out.autoPercentUsed = total
                out.apiPercentUsed = 0
            } else {
                out.planKind = .classic
                out.autoPercentUsed = auto
                out.apiPercentUsed = api
            }
        }
        if let slu = dictVal(root, "spendLimitUsage") ?? dictVal(root, "spend_limit_usage") {
            out.ondValid = true
            let indUsed = intVal(slu["individualUsed"]) ?? intVal(slu["individual_used"])
            let poolUsed = intVal(slu["pooledUsed"]) ?? intVal(slu["pooled_used"])
            if let indUsed, indUsed >= 0 {
                out.ondUsedCents = indUsed
                out.ondLimitCents = intVal(slu["individualLimit"]) ?? intVal(slu["individual_limit"]) ?? 0
            } else if let poolUsed, poolUsed >= 0 {
                out.ondUsedCents = poolUsed
                out.ondLimitCents = intVal(slu["pooledLimit"]) ?? intVal(slu["pooled_limit"]) ?? 0
            } else {
                out.ondUsedCents = intVal(slu["totalSpend"]) ?? intVal(slu["total_spend"]) ?? 0
                out.ondLimitCents = intVal(slu["individualLimit"])
                    ?? intVal(slu["individual_limit"])
                    ?? intVal(slu["pooledLimit"])
                    ?? intVal(slu["pooled_limit"])
                    ?? 0
            }
        }
        if let individual = dictVal(root, "individualUsage") ?? dictVal(root, "individual_usage"),
           let ond = dictVal(individual, "onDemand") ?? dictVal(individual, "on_demand") {
            let enabled = (ond["enabled"] as? Bool) ?? false
            let used = intVal(ond["used"]) ?? 0
            if enabled || used > 0 || out.ondValid {
                out.ondValid = true
                out.ondUsedCents = used
                out.ondLimitCents = intVal(ond["limit"]) ?? 0
            }
        }
        out.billingCycleEnd = parseDate(root["billingCycleEnd"] ?? root["billing_cycle_end"])
        return out
    }

    // GetSandUsageStatus：有非零 included 额度且带回 usage_percent 才展示
    private func parseGrokBotUsage(_ data: Data) -> GrokBotUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let includedZero = (root["includedLimitZero"] as? Bool)
            ?? (root["included_limit_zero"] as? Bool)
            ?? false
        let hasLimit = (root["hasNonZeroIncludedLimit"] as? Bool)
            ?? (root["has_non_zero_included_limit"] as? Bool)
            ?? !includedZero
        guard hasLimit, !includedZero else { return nil }
        guard let used = doubleVal(root["usagePercent"] ?? root["usage_percent"]) else {
            return nil
        }
        let reset = parseDate(root["nextResetTimestampUtc"] ?? root["next_reset_timestamp_utc"])
        let label = (root["grokPlanLabel"] as? String) ?? (root["grok_plan_label"] as? String)
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GrokBotUsage(
            percentUsed: used,
            resetAt: reset,
            planLabel: (trimmed?.isEmpty == false) ? trimmed : nil
        )
    }

    private func parseEvents(_ data: Data) -> [UsageEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        // Connect：usageEventsDisplay；旧接口同名字段
        let list = (root["usageEventsDisplay"] as? [[String: Any]])
            ?? (root["usage_events_display"] as? [[String: Any]])
            ?? []
        return list.compactMap { ev in
            guard let ts = parseDate(ev["timestamp"]) else { return nil }
            let usage = dictVal(ev, "tokenUsage") ?? dictVal(ev, "token_usage") ?? [:]
            let kindRaw = ev["kind"]
            let kind: String
            if let s = kindRaw as? String {
                kind = s
            } else if let n = intVal(kindRaw) {
                kind = "\(n)"
            } else {
                kind = ""
            }
            // Connect 可能用 requestsCosts / cursorTokenFee，旧字段 chargedCents
            let charged = doubleVal(ev["chargedCents"])
                ?? doubleVal(ev["charged_cents"])
                ?? doubleVal(ev["requestsCosts"])
                ?? doubleVal(ev["requests_costs"])
                ?? doubleVal(ev["cursorTokenFee"])
                ?? doubleVal(ev["cursor_token_fee"])
                ?? 0
            return UsageEvent(
                timestamp: ts,
                model: (ev["model"] as? String) ?? "-",
                kind: kind,
                inputTokens: intVal(usage["inputTokens"]) ?? intVal(usage["input_tokens"]) ?? 0,
                outputTokens: intVal(usage["outputTokens"]) ?? intVal(usage["output_tokens"]) ?? 0,
                cacheWriteTokens: intVal(usage["cacheWriteTokens"]) ?? intVal(usage["cache_write_tokens"]) ?? 0,
                cacheReadTokens: intVal(usage["cacheReadTokens"]) ?? intVal(usage["cache_read_tokens"]) ?? 0,
                totalCents: doubleVal(usage["totalCents"]) ?? doubleVal(usage["total_cents"]) ?? 0,
                chargedCents: charged
            )
        }
    }

    private func dictVal(_ root: [String: Any], _ key: String) -> [String: Any]? {
        root[key] as? [String: Any]
    }

    private func parseDate(_ raw: Any?) -> Date? {
        // protobuf Timestamp JSON：{ "seconds": "...", "nanos": 0 }
        if let dict = raw as? [String: Any] {
            if let sec = intVal(dict["seconds"]) {
                let nanos = doubleVal(dict["nanos"]) ?? 0
                return Date(timeIntervalSince1970: TimeInterval(sec) + nanos / 1_000_000_000)
            }
        }
        if let s = raw as? String {
            if let ms = Int64(s), ms > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            }
            if let n = Double(s), n > 1_000_000_000 {
                return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let n = raw as? Int64 {
            let divisor: TimeInterval = n > 1_000_000_000_000 ? 1000 : 1
            return Date(timeIntervalSince1970: TimeInterval(n) / divisor)
        }
        if let n = raw as? Int {
            let v = Int64(n)
            return Date(timeIntervalSince1970: TimeInterval(v) / (v > 1_000_000_000_000 ? 1000 : 1))
        }
        if let n = raw as? Double {
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        return nil
    }

    private func doubleVal(_ raw: Any?) -> Double? {
        if let n = raw as? Double { return n }
        if let n = raw as? Int { return Double(n) }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    private func intVal(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? Double { return Int(n) }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }
}

enum ChartAggregator {
    static func bars(events: [UsageEvent], range: ChartRange, now: Date = Date()) -> [ChartBar] {
        let cal = Calendar.current
        switch range {
        case .hours24:
            return (0..<24).map { hour in
                let tokens = events.reduce(0) { acc, ev in
                    let h = cal.component(.hour, from: ev.timestamp)
                    let sameDay = cal.isDate(ev.timestamp, inSameDayAs: now)
                    return acc + (sameDay && h == hour ? ev.totalTokens : 0)
                }
                // 横坐标只标 0 / 6 / 12 / 18（24 用坐标轴额外刻度）
                let axis = [0, 6, 12, 18].contains(hour) ? "\(hour)" : ""
                return ChartBar(
                    id: "h\(hour)",
                    xIndex: hour,
                    axisLabel: axis,
                    hoverTitle: String(format: "%02d:00", hour),
                    tokens: tokens
                )
            }
        case .days7, .days30:
            let days = range == .days7 ? 7 : 30
            let startDay = cal.startOfDay(for: now)
            let md = DateFormatter()
            md.dateFormat = "MM-dd"
            let wd = DateFormatter()
            wd.dateFormat = "EE"
            return (0..<days).reversed().enumerated().map { idx, ago in
                let day = cal.date(byAdding: .day, value: -ago, to: startDay) ?? startDay
                let tokens = events.reduce(0) { acc, ev in
                    acc + (cal.isDate(ev.timestamp, inSameDayAs: day) ? ev.totalTokens : 0)
                }
                let dom = cal.component(.day, from: day)
                let axis: String
                if range == .days7 {
                    axis = wd.string(from: day)
                } else {
                    // 30d：月初(1) 与 5 的倍数
                    axis = (dom == 1 || dom % 5 == 0) ? "\(dom)" : ""
                }
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withFullDate]
                return ChartBar(
                    id: iso.string(from: day),
                    xIndex: idx,
                    axisLabel: axis,
                    hoverTitle: md.string(from: day),
                    tokens: tokens
                )
            }
        }
    }

    static func window(for range: ChartRange, now: Date = Date()) -> (Date, Date) {
        let cal = Calendar.current
        switch range {
        case .hours24:
            return (cal.startOfDay(for: now), now)
        case .days7:
            let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)) ?? now
            return (start, now)
        case .days30:
            let start = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now)) ?? now
            return (start, now)
        }
    }
}
