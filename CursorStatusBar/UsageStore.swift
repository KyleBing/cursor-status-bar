import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published var usage: PeriodUsage?
    @Published var lastEvents: [UsageEvent] = []
    @Published var chartBars: [ChartBar] = []
    @Published var chartRange: ChartRange = .hours24
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var isChartLoading = false
    @Published var hasToken: Bool = TokenStore.load()?.isEmpty == false
    // 周期用量（Auto/API/ond）最后刷新时间，与图表无关
    @Published var lastUpdated: Date?
    // 当前选中图表 range 的最后刷新时间（7d/30d 各自独立）
    @Published var chartLastUpdated: Date?
    // 菜单栏外圈 API / Ond 环，默认关闭
    @Published var showExtraRings: Bool = false {
        didSet { UserDefaults.standard.set(showExtraRings, forKey: Self.extraRingsKey) }
    }

    private static let extraRingsKey = "showExtraStatusRings"

    private let api = CursorAPI()
    private var userId: Int = 0
    private var cookie: String?
    private var chartCache: [ChartRange: [ChartBar]] = [:]
    private var eventCache: [ChartRange: [UsageEvent]] = [:]
    // 各图表 range 独立的最后刷新时间
    private var chartUpdatedAt: [ChartRange: Date] = [:]
    private var timer: Timer?

    // 7d/30d 缓存超过半天视为过期；24h 更短，半小时
    private func chartStaleInterval(for range: ChartRange) -> TimeInterval {
        switch range {
        case .hours24: return 30 * 60
        case .days7, .days30: return 12 * 60 * 60
        }
    }

    init() {
        showExtraRings = UserDefaults.standard.bool(forKey: Self.extraRingsKey)
        // 未保存过 token 且本机有 Cursor 时，从 SQLite 自动导入
        importFromCursorIfNeeded()
        // 启动即拉一次，之后每分钟刷新周期用量
        Task { await refreshPeriod(forceAuth: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshPeriod()
            }
        }
    }

    // 无 Keychain token 时尝试读取 Cursor 本地库
    func importFromCursorIfNeeded() {
        guard TokenStore.load()?.isEmpty != false else { return }
        if case .success(let token) = CursorLocalToken.readAccessToken() {
            TokenStore.save(token)
            hasToken = true
        }
    }

    // 一键从 Cursor SQLite 取 token 并保存
    func importTokenFromCursor() -> String? {
        switch CursorLocalToken.readAccessToken() {
        case .success(let token):
            applyToken(token)
            return token
        case .failure(let err):
            errorMessage = err.localizedDescription
            return nil
        }
    }

    func applyToken(_ raw: String) {
        TokenStore.save(raw)
        hasToken = TokenStore.load()?.isEmpty == false
        userId = 0
        cookie = nil
        chartCache.removeAll()
        eventCache.removeAll()
        chartUpdatedAt.removeAll()
        chartLastUpdated = nil
        Task { await refreshPeriod(forceAuth: true) }
    }

    func refreshPeriod(forceAuth: Bool = false) async {
        guard let token = TokenStore.load(), !token.isEmpty else {
            hasToken = false
            usage = nil
            errorMessage = CursorAPIError.missingToken.localizedDescription
            return
        }
        hasToken = true
        guard let cookie = CursorCookie.headerValue(from: token) else {
            errorMessage = CursorAPIError.badCookie.localizedDescription
            return
        }
        self.cookie = cookie
        isLoading = true
        defer { isLoading = false }
        do {
            if forceAuth || userId == 0 {
                userId = try await api.authMe(cookie: cookie)
            }
            usage = try await api.periodUsage(cookie: cookie)
            errorMessage = nil
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshDetails(forceChart: Bool = false) async {
        await refreshPeriod()
        await refreshLast()
        await refreshChart(chartRange, force: forceChart)
    }

    func selectChart(_ range: ChartRange) async {
        chartRange = range
        chartLastUpdated = chartUpdatedAt[range]
        // 有缓存先展示，过期则后台再拉
        if let cached = chartCache[range] {
            chartBars = cached
            isChartLoading = false
            if isChartStale(range) {
                await refreshChart(range, force: true)
            }
            return
        }
        chartBars = []
        isChartLoading = true
        await refreshChart(range, force: false)
    }

    // 该 range 是否超过独立缓存有效期
    private func isChartStale(_ range: ChartRange) -> Bool {
        guard let updated = chartUpdatedAt[range] else { return true }
        return Date().timeIntervalSince(updated) >= chartStaleInterval(for: range)
    }

    func refreshLast() async {
        guard let cookie, userId > 0 else { return }
        do {
            lastEvents = try await api.lastEvents(cookie: cookie, userId: userId, pageSize: 20)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshChart(_ range: ChartRange, force: Bool) async {
        if !force, let cached = chartCache[range], !isChartStale(range) {
            chartBars = cached
            chartLastUpdated = chartUpdatedAt[range]
            isChartLoading = false
            return
        }
        guard let cookie, userId > 0 else { return }
        isChartLoading = true
        let (start, end) = ChartAggregator.window(for: range)
        do {
            let events = try await api.allEvents(cookie: cookie, userId: userId, start: start, end: end)
            eventCache[range] = events
            let bars = ChartAggregator.bars(events: events, range: range)
            chartCache[range] = bars
            let now = Date()
            chartUpdatedAt[range] = now
            if chartRange == range {
                chartBars = bars
                chartLastUpdated = now
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        if chartRange == range {
            isChartLoading = false
        }
    }
}
