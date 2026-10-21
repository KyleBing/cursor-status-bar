import Foundation
import Combine

// MARK: - 统计

// 当前区间内的用量汇总
struct DeepSeekUsageTotals: Equatable {
    var requests = 0
    var promptTokens = 0
    var completionTokens = 0
    var totalTokens = 0
    var cacheHitTokens = 0
    var cacheMissTokens = 0
    var reasoningTokens = 0
}

// 图表、列表和按模型汇总共用的行数据，来自平台用量接口按时间桶聚合
struct DeepSeekUsageRow: Identifiable, Equatable {
    var id: String
    var date: Date
    var model: String
    var requests: Int
    var promptTokens: Int
    var completionTokens: Int
    var cacheHitTokens: Int
    var reasoningTokens: Int
    var totalTokens: Int
}

// MARK: - Store

// 只负责“看用量”：余额 + 平台账号的 token 使用历史
@MainActor
final class DeepSeekStore: ObservableObject {
    @Published var apiKeyDraft: String
    @Published var hasKey: Bool
    @Published var balance: DeepSeekBalance?
    @Published var balanceError: String?
    @Published var isBalanceLoading = false

    // 平台网页登录 token（可选）：配置后可看账号维度的真实用量历史
    @Published var platformTokenDraft: String
    @Published var hasPlatformToken: Bool
    // 平台明确判定 token 失效（40003），界面据此给出「重新登录」入口
    @Published var platformTokenRejected = false
    // 是否同时保存了浏览器 cookie（从 Copy as cURL 解析出来）
    @Published var hasPlatformCookie: Bool
    @Published var usageRange: ChartRange
    @Published var usageBars: [ChartBar] = []
    @Published var usageRows: [DeepSeekUsageRow] = []
    @Published var usageStats = DeepSeekUsageTotals()
    @Published var usageLoading = false
    @Published var usageError: String?
    @Published var usageLastUpdated: Date?

    private let api = DeepSeekAPI()
    private let defaults = UserDefaults.standard
    // 余额最短刷新间隔，避免来回切 tab 反复请求
    private var lastBalanceRefresh: Date?
    // 各 range 的平台用量缓存与刷新时间
    private var platformCache: [ChartRange: [DeepSeekPlatformBucket]] = [:]
    private var platformUpdatedAt: [ChartRange: Date] = [:]

    private static let usageRangeKey = "deepSeekUsageRange"

    init() {
        let key = TokenStore.loadDeepSeekKey() ?? ""
        apiKeyDraft = key
        hasKey = !key.isEmpty
        let platform = TokenStore.loadDeepSeekPlatformToken() ?? ""
        platformTokenDraft = platform
        hasPlatformToken = !platform.isEmpty
        hasPlatformCookie = !(TokenStore.loadDeepSeekPlatformCookie() ?? "").isEmpty
        usageRange = Self.loadUsageRange()
    }

    // 面板打开时调用：同步 Keychain、刷新余额与用量
    func loadInitial() async {
        if apiKeyDraft.isEmpty, let key = TokenStore.loadDeepSeekKey(), !key.isEmpty {
            apiKeyDraft = key
            hasKey = true
        }
        if platformTokenDraft.isEmpty, let token = TokenStore.loadDeepSeekPlatformToken(), !token.isEmpty {
            platformTokenDraft = token
            hasPlatformToken = true
        }
        hasPlatformCookie = !(TokenStore.loadDeepSeekPlatformCookie() ?? "").isEmpty
        if hasKey {
            await refreshBalance()
        }
        await refreshUsage()
    }

    // MARK: 平台用量

    // 拉取当前 range 的账号用量；没有平台 token 时清空图表等待配置
    func refreshUsage(force: Bool = false) async {
        guard hasPlatformToken,
              let token = TokenStore.loadDeepSeekPlatformToken(),
              !token.isEmpty
        else {
            usageBars = []
            usageRows = []
            usageStats = DeepSeekUsageTotals()
            usageLastUpdated = nil
            return
        }
        let range = usageRange
        if !force,
           let cached = platformCache[range],
           let updated = platformUpdatedAt[range],
           Date().timeIntervalSince(updated) < 60 {
            applyPlatform(cached, range: range)
            return
        }
        usageLoading = true
        defer { usageLoading = false }
        do {
            let (start, end) = ChartAggregator.window(for: range)
            let cookie = TokenStore.loadDeepSeekPlatformCookie() ?? ""
            let buckets = try await api.platformUsage(
                token: token,
                cookie: cookie,
                start: start,
                end: end
            )
            platformCache[range] = buckets
            platformUpdatedAt[range] = Date()
            if usageRange == range {
                applyPlatform(buckets, range: range)
                usageLastUpdated = Date()
                usageError = nil
                platformTokenRejected = false
            }
        } catch {
            usageError = error.localizedDescription
            platformTokenRejected = Self.isRejectedToken(error)
            if usageRange == range {
                usageBars = []
                usageRows = []
                usageStats = DeepSeekUsageTotals()
            }
        }
    }

    // 切换 24h / 7d / 30d，并记住选择
    func selectUsageRange(_ range: ChartRange) {
        guard range != usageRange else { return }
        usageRange = range
        defaults.set(range.rawValue, forKey: Self.usageRangeKey)
        usageBars = []
        usageRows = []
        usageStats = DeepSeekUsageTotals()
        Task { await refreshUsage() }
    }

    // 先验证 token 再写入 Keychain，避免保存无效 token
    // 输入支持三种形式：localStorage 的 userToken、裸 token、浏览器 Copy as cURL（含 Authorization / Cookie）
    func savePlatformToken() {
        let credential = Self.parsePlatformCredential(platformTokenDraft)
        guard !credential.token.isEmpty else {
            usageError = String(localized: "Platform token not set")
            return
        }
        // 平台 token 是网页登录态（JWT，通常以 eyJ 开头）；sk- 开头的是 API key，填进来只会得到 40003
        guard !credential.token.hasPrefix("sk-") else {
            platformTokenRejected = false
            usageError = String(localized: "That is an API key, not the platform token. Open platform.deepseek.com, sign in, then copy userToken from DevTools → Application → Local Storage.")
            return
        }
        platformTokenDraft = credential.token
        Task {
            _ = await connectPlatform(token: credential.token, cookie: credential.cookie)
        }
    }

    // 内置网页登录：登录后自动读取平台 token，省掉手工去 DevTools 复制
    func connectPlatformFromBrowser() {
        usageError = nil
        // 传入已保存的旧 token：登录窗据此跳过「还没重新登录」时的同一个旧值，
        // 并在校验失败时保持窗口打开，而不是拿失效 token 反复报错
        DeepSeekLoginWindow.shared.present(
            previousToken: TokenStore.loadDeepSeekPlatformToken() ?? ""
        ) { [weak self] token, cookie in
            guard let self else { return false }
            return await self.connectPlatform(token: token, cookie: cookie)
        }
    }

    // 手动粘贴用的 Console 脚本：在 platform.deepseek.com 的 DevTools Console 里执行，
    // 会把登录 token（含 {"value":"..."} 外壳时自动取 value）直接放进剪贴板
    static var consoleSnippet: String {
        #"var t = localStorage.getItem("userToken") || ""; try { t = JSON.parse(t).value || t } catch (e) {} copy(t)"#
    }

    // 验证 token 能取到用量后再落 Keychain，避免保存无效凭证
    @discardableResult
    private func connectPlatform(token: String, cookie: String) async -> Bool {
        usageLoading = true
        defer { usageLoading = false }
        do {
            let range = usageRange
            let (start, end) = ChartAggregator.window(for: range)
            let buckets = try await api.platformUsage(
                token: token,
                cookie: cookie,
                start: start,
                end: end
            )
            TokenStore.saveDeepSeekPlatformToken(token)
            // 空 cookie 会把已存的那份清掉，避免残留旧的会话
            TokenStore.saveDeepSeekPlatformCookie(cookie)
            // 成功后才回填输入框，失败时保留用户粘贴的内容便于修改
            platformTokenDraft = token
            hasPlatformToken = true
            platformTokenRejected = false
            hasPlatformCookie = !cookie.isEmpty
            platformCache = [range: buckets]
            platformUpdatedAt = [range: Date()]
            applyPlatform(buckets, range: range)
            usageLastUpdated = Date()
            usageError = nil
            return true
        } catch {
            usageError = error.localizedDescription
            platformTokenRejected = Self.isRejectedToken(error)
            return false
        }
    }

    // 平台用 40003 表示登录态失效，这类错误值得给出「重新登录」入口
    private static func isRejectedToken(_ error: Error) -> Bool {
        guard let apiError = error as? DeepSeekAPIError else { return false }
        if case .invalidPlatformToken = apiError { return true }
        return false
    }

    func deletePlatformToken() {
        TokenStore.deleteDeepSeekPlatformToken()
        TokenStore.deleteDeepSeekPlatformCookie()
        platformTokenDraft = ""
        hasPlatformToken = false
        hasPlatformCookie = false
        platformTokenRejected = false
        platformCache = [:]
        platformUpdatedAt = [:]
        usageError = nil
        usageBars = []
        usageRows = []
        usageStats = DeepSeekUsageTotals()
        usageLastUpdated = nil
    }

    // 把平台返回的时间桶按当前 range 的粒度（小时 / 天）与模型合并成行
    private func applyPlatform(_ buckets: [DeepSeekPlatformBucket], range: ChartRange) {
        usageRows = Self.rows(from: buckets, range: range)
        usageBars = ChartAggregator.bars(events: Self.events(buckets), range: range)
        usageStats = Self.stats(rows: usageRows)
    }

    private static func rows(from buckets: [DeepSeekPlatformBucket], range: ChartRange) -> [DeepSeekUsageRow] {
        let cal = Calendar.current
        struct RowKey: Hashable {
            let period: Date
            let model: String
        }
        var grouped: [RowKey: DeepSeekUsageRow] = [:]
        for bucket in buckets where bucket.timestamp > 0 {
            // 24h 按小时合并，7d/30d 按天合并，避免列表里全是小时桶
            let period: Date
            switch range {
            case .hours24:
                period = cal.dateInterval(of: .hour, for: bucket.date)?.start ?? bucket.date
            case .days7, .days30:
                period = cal.startOfDay(for: bucket.date)
            }
            let key = RowKey(period: period, model: bucket.model)
            var row = grouped[key] ?? DeepSeekUsageRow(
                id: "\(period.timeIntervalSince1970)-\(bucket.model)",
                date: period,
                model: bucket.model,
                requests: 0,
                promptTokens: 0,
                completionTokens: 0,
                cacheHitTokens: 0,
                reasoningTokens: 0,
                totalTokens: 0
            )
            row.requests += bucket.requests
            row.promptTokens += bucket.promptTokens
            row.completionTokens += bucket.responseTokens
            row.cacheHitTokens += bucket.cacheHitTokens
            row.totalTokens += bucket.totalTokens
            grouped[key] = row
        }
        return grouped.values.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.totalTokens > $1.totalTokens
        }
    }

    private static func events(_ buckets: [DeepSeekPlatformBucket]) -> [UsageEvent] {
        buckets.map { bucket in
            UsageEvent(
                timestamp: bucket.date,
                model: bucket.model,
                kind: "API",
                inputTokens: bucket.promptTokens,
                outputTokens: bucket.responseTokens,
                cacheWriteTokens: 0,
                cacheReadTokens: 0,
                totalCents: 0,
                chargedCents: 0
            )
        }
    }

    private static func stats(rows: [DeepSeekUsageRow]) -> DeepSeekUsageTotals {
        var totals = DeepSeekUsageTotals()
        for row in rows {
            totals.requests += row.requests
            totals.promptTokens += row.promptTokens
            totals.completionTokens += row.completionTokens
            totals.totalTokens += row.totalTokens
            totals.cacheHitTokens += row.cacheHitTokens
            totals.cacheMissTokens += max(0, row.promptTokens - row.cacheHitTokens)
            totals.reasoningTokens += row.reasoningTokens
        }
        return totals
    }

    // MARK: 凭证解析

    // 解析平台凭证，支持三种输入：
    // 1) localStorage 里 userToken 的 value（可能带 {"value":"...","version":"0"} 外壳）
    // 2) 裸 token 或 "Bearer xxx"
    // 3) 浏览器 DevTools 的 Copy as cURL（从 Authorization / Cookie 头里取）
    static func parsePlatformCredential(_ raw: String) -> (token: String, cookie: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ("", "") }

        if text.lowercased().hasPrefix("curl") {
            let token = Self.firstMatch(
                in: text,
                pattern: #"(?i)authorization\s*:\s*bearer\s+([^\s'"\\]+)"#
            )
            let cookie = Self.firstMatch(in: text, pattern: #"(?i)\bcookie\s*:\s*([^'"\\\n]+)"#)
            return (Self.normalizePlatformToken(token), cookie.trimmingCharacters(in: .whitespaces))
        }
        return (Self.normalizePlatformToken(text), "")
    }

    // 取第一个正则分组，取不到返回空串
    private static func firstMatch(in text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text)
        else { return "" }
        return String(text[valueRange])
    }

    // userToken 可能被复制成 {"value":"eyJ...","version":"0"}，这里取出 value
    private static func normalizePlatformToken(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{"),
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["value"] as? String {
            text = value
        }
        if text.lowercased().hasPrefix("bearer ") {
            text = String(text.dropFirst(7))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 余额

    func saveKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            balanceError = String(localized: "DeepSeek API key not set")
            return
        }
        TokenStore.saveDeepSeekKey(key)
        apiKeyDraft = key
        hasKey = true
        balanceError = nil
        Task { await refreshBalance(force: true) }
    }

    func deleteKey() {
        TokenStore.deleteDeepSeekKey()
        apiKeyDraft = ""
        hasKey = false
        balance = nil
        balanceError = nil
    }

    // 余额来自 /user/balance，需要 API key（不是平台网页 token）
    func refreshBalance(force: Bool = false) async {
        guard let key = TokenStore.loadDeepSeekKey(), !key.isEmpty else { return }
        if !force, let last = lastBalanceRefresh, Date().timeIntervalSince(last) < 60 {
            return
        }
        isBalanceLoading = true
        defer { isBalanceLoading = false }
        do {
            balance = try await api.balance(apiKey: key)
            balanceError = nil
            lastBalanceRefresh = Date()
        } catch {
            balanceError = error.localizedDescription
        }
    }

    // MARK: 持久化读取

    // 记住上次选择的图表范围
    private static func loadUsageRange() -> ChartRange {
        guard let raw = UserDefaults.standard.string(forKey: usageRangeKey),
              let range = ChartRange(rawValue: raw)
        else { return .hours24 }
        return range
    }
}
