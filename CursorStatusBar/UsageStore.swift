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
    @Published var lastUpdated: Date?

    private let api = CursorAPI()
    private var userId: Int = 0
    private var cookie: String?
    private var chartCache: [ChartRange: [ChartBar]] = [:]
    private var eventCache: [ChartRange: [UsageEvent]] = [:]
    private var timer: Timer?

    init() {
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
        // 切模式用缓存，不重复请求
        if let cached = chartCache[range] {
            chartBars = cached
            isChartLoading = false
            return
        }
        chartBars = []
        isChartLoading = true
        await refreshChart(range, force: false)
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
        if !force, let cached = chartCache[range] {
            chartBars = cached
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
            if chartRange == range {
                chartBars = bars
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        if chartRange == range {
            isChartLoading = false
        }
    }
}
