import Foundation

enum CursorAPIError: LocalizedError {
    case missingToken
    case badCookie
    case http(Int)
    case decode
    case noUserId

    var errorDescription: String? {
        switch self {
        case .missingToken: return "未设置 token"
        case .badCookie: return "token 无法构成 Cookie"
        case .http(let code): return "HTTP \(code)"
        case .decode: return "JSON 解析失败"
        case .noUserId: return "no user id"
        }
    }
}

final class CursorAPI {
    private let session: URLSession
    private let host = URL(string: "https://cursor.com")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func authMe(cookie: String) async throws -> Int {
        let data = try await request(method: "GET", path: "/api/auth/me", cookie: cookie, body: nil)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let id = obj?["id"] as? Int { return id }
        if let id = obj?["id"] as? String, let n = Int(id) { return n }
        throw CursorAPIError.noUserId
    }

    func periodUsage(cookie: String) async throws -> PeriodUsage {
        do {
            let data = try await request(
                method: "POST",
                path: "/api/dashboard/get-current-period-usage",
                cookie: cookie,
                body: Data("{}".utf8)
            )
            return try parsePeriod(data)
        } catch {
            let data = try await request(method: "GET", path: "/api/usage-summary", cookie: cookie, body: nil)
            return try parsePeriod(data)
        }
    }

    func lastEvents(cookie: String, userId: Int, pageSize: Int = 20) async throws -> [UsageEvent] {
        let end = Date()
        let start = end.addingTimeInterval(-30 * 86400)
        let page = try await eventsPage(cookie: cookie, userId: userId, start: start, end: end, page: 1, pageSize: pageSize)
        return page
    }

    func allEvents(cookie: String, userId: Int, start: Date, end: Date) async throws -> [UsageEvent] {
        var page = 1
        var all: [UsageEvent] = []
        while true {
            let batch = try await eventsPage(
                cookie: cookie,
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

    private func eventsPage(
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
        let data = try await request(
            method: "POST",
            path: "/api/dashboard/get-filtered-usage-events",
            cookie: cookie,
            body: body
        )
        return parseEvents(data)
    }

    private func request(method: String, path: String, cookie: String, body: Data?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: host)?.absoluteURL else {
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

    private func parsePeriod(_ data: Data) throws -> PeriodUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorAPIError.decode
        }
        var out = PeriodUsage()
        var plan = root["planUsage"] as? [String: Any]
        if plan == nil, let individual = root["individualUsage"] as? [String: Any] {
            plan = individual["plan"] as? [String: Any]
        }
        if let plan {
            out.autoPercentUsed = doubleVal(plan["autoPercentUsed"]) ?? 0
            out.apiPercentUsed = doubleVal(plan["apiPercentUsed"]) ?? 0
            out.totalPercentUsed = doubleVal(plan["totalPercentUsed"])
            out.remaining = doubleVal(plan["remaining"])
            out.limit = doubleVal(plan["limit"])
        }
        if let slu = root["spendLimitUsage"] as? [String: Any] {
            out.ondValid = true
            let indUsed = intVal(slu["individualUsed"])
            let poolUsed = intVal(slu["pooledUsed"])
            if let indUsed, indUsed >= 0 {
                out.ondUsedCents = indUsed
                out.ondLimitCents = intVal(slu["individualLimit"]) ?? 0
            } else if let poolUsed, poolUsed >= 0 {
                out.ondUsedCents = poolUsed
                out.ondLimitCents = intVal(slu["pooledLimit"]) ?? 0
            } else {
                out.ondUsedCents = intVal(slu["totalSpend"]) ?? 0
                out.ondLimitCents = intVal(slu["individualLimit"]) ?? intVal(slu["pooledLimit"]) ?? 0
            }
        }
        if let individual = root["individualUsage"] as? [String: Any],
           let ond = individual["onDemand"] as? [String: Any] {
            let enabled = (ond["enabled"] as? Bool) ?? false
            let used = intVal(ond["used"]) ?? 0
            if enabled || used > 0 || out.ondValid {
                out.ondValid = true
                out.ondUsedCents = used
                out.ondLimitCents = intVal(ond["limit"]) ?? 0
            }
        }
        out.billingCycleEnd = parseDate(root["billingCycleEnd"])
        return out
    }

    private func parseEvents(_ data: Data) -> [UsageEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["usageEventsDisplay"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { ev in
            guard let ts = parseDate(ev["timestamp"]) else { return nil }
            let usage = ev["tokenUsage"] as? [String: Any] ?? [:]
            return UsageEvent(
                timestamp: ts,
                model: (ev["model"] as? String) ?? "-",
                kind: (ev["kind"] as? String) ?? "",
                inputTokens: intVal(usage["inputTokens"]) ?? 0,
                outputTokens: intVal(usage["outputTokens"]) ?? 0,
                cacheWriteTokens: intVal(usage["cacheWriteTokens"]) ?? 0,
                cacheReadTokens: intVal(usage["cacheReadTokens"]) ?? 0,
                totalCents: doubleVal(usage["totalCents"]) ?? 0,
                chargedCents: doubleVal(ev["chargedCents"]) ?? 0
            )
        }
    }

    private func parseDate(_ raw: Any?) -> Date? {
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
