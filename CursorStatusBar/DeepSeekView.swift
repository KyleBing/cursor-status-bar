import SwiftUI
import AppKit
import Charts

// 面板里的 DeepSeek tab：只看账号额度与 token 用量（余额 / 24h / 7d / 30d）
struct DeepSeekView: View {
    @EnvironmentObject private var ds: DeepSeekStore

    @State private var showPlatformToken = false
    @State private var showKey = false
    @State private var hoverBar: ChartBar?
    // 「复制脚本」给了反馈后再复位
    @State private var didCopyScript = false

    private let platformUsageURL = URL(string: "https://platform.deepseek.com/usage")!
    private let platformKeysURL = URL(string: "https://platform.deepseek.com/api_keys")!
    private let balanceDocsURL = URL(string: "https://api-docs.deepseek.com/api/get-user-balance")!

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                header
                usageCard
                Divider()
                keySection
            }
            // 左右各留 2pt：输入框焦点环不会贴到滚动视图的裁剪边界上
            .padding(.horizontal, 2)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await ds.loadInitial() }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 6) {
            Text("DeepSeek usage")
                .font(.headline)
            if ds.usageLoading || ds.isBalanceLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            // 打开 DeepSeek 平台用量页
            Button {
                NSWorkspace.shared.open(platformUsageURL)
            } label: {
                Image(systemName: "chart.bar.xaxis")
            }
            .buttonStyle(.plain)
            .help("DeepSeek platform usage")
            // 同时刷新余额与当前区间的用量
            Button {
                Task {
                    await ds.refreshBalance(force: true)
                    await ds.refreshUsage(force: true)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh usage and balance")
        }
    }

    // MARK: 用量

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            balanceLine

            // 时间范围与图表汇总
            HStack(spacing: 8) {
                Picker("range", selection: Binding(
                    get: { ds.usageRange },
                    set: { ds.selectUsageRange($0) }
                )) {
                    ForEach(ChartRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150, alignment: .leading)
                .layoutPriority(1)

                Spacer(minLength: 4)

                if ds.usageLoading {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(TokenFormat.label(usageTotalTokens)) tokens")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        // 当前 range 的最后刷新时间
                        if ds.usageLastUpdated != nil {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(relativeUpdated(from: ds.usageLastUpdated, now: context.date))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            Text("Account usage")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // 悬浮时显示具体桶，平时给操作提示
            if let hoverBar {
                Text("\(hoverBar.hoverTitle)  \(hoverBar.tokensLabel) tokens")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Hover chart to view tokens")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ZStack {
                usageChart
                if ds.usageLoading {
                    ProgressView()
                }
            }
            .frame(height: 126)

            HStack(spacing: 6) {
                statCell("Requests", "\(ds.usageStats.requests)")
                statCell("Prompt", TokenFormat.label(ds.usageStats.promptTokens))
                statCell("Completion", TokenFormat.label(ds.usageStats.completionTokens))
            }
            HStack(spacing: 6) {
                statCell("Total", TokenFormat.label(ds.usageStats.totalTokens))
                statCell("Cache hit", TokenFormat.label(ds.usageStats.cacheHitTokens))
                statCell("Reasoning", TokenFormat.label(ds.usageStats.reasoningTokens))
            }

            Text(cacheHitText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            usageList
            modelSummary
            usageSource
        }
    }

    // 24h / 7d / 30d 柱状图
    private var usageChart: some View {
        VStack(spacing: 0) {
            if ds.usageBars.isEmpty {
                Text(ds.hasPlatformToken ? "No usage in this range" : "Connect platform to see usage")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(ds.usageBars) { bar in
                    BarMark(
                        x: .value("t", bar.category),
                        y: .value("tokens", bar.tokens),
                        width: .ratio(2.0 / 3.0)
                    )
                    .cornerRadius(0)
                    .foregroundStyle(barFill(bar))
                }
                .chartXScale(domain: ds.usageBars.map(\.category))
                .chartYScale(domain: usageYDomain)
                .chartXAxis {
                    AxisMarks(values: labeledCategories) { _ in
                        AxisGridLine()
                        AxisTick()
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let n = value.as(Int.self) {
                                Text(TokenFormat.label(n)).fixedSize()
                            } else if let n = value.as(Double.self) {
                                Text(TokenFormat.label(Int(n.rounded()))).fixedSize()
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    ChartHoverOverlay(
                        proxy: proxy,
                        bars: ds.usageBars,
                        hoverBar: hoverBar,
                        onHover: { hoverBar = $0 }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 轴标签放在图外，避免挤进每个柱的格子
                HStack(spacing: 0) {
                    ForEach(ds.usageBars) { bar in
                        Text(bar.axisLabel.isEmpty ? " " : bar.axisLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 3)
            }
        }
        .onChange(of: ds.usageRange) { _, _ in hoverBar = nil }
    }

    private func barFill(_ bar: ChartBar) -> Color {
        if hoverBar == nil || hoverBar?.id == bar.id {
            return Color.accentColor
        }
        return Color.accentColor.opacity(0.28)
    }

    private var labeledCategories: [String] {
        ds.usageBars.filter { !$0.axisLabel.isEmpty }.map(\.category)
    }

    private var usageTotalTokens: Int {
        ds.usageBars.reduce(0) { $0 + $1.tokens }
    }

    private var usageYDomain: ClosedRange<Double> {
        let peak = ds.usageBars.map(\.tokens).max() ?? 0
        return 0...max(Double(peak) * 1.18, 1)
    }

    // 按当前 range 的时间粒度倒序的用量列表，平台数据会按模型拆行
    // 与 Cursor 页的列表一致：固定高度 + 内部滚动，行数多也不会把整页撑长
    private var usageList: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Last usage")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if ds.usageRows.isEmpty {
                Text(ds.hasPlatformToken ? "No records" : "No data source connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 列表区单独滚动，外层页面滚动不受影响
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(ds.usageRows.prefix(30))) { row in
                            HStack(spacing: 6) {
                                Text(usageTimeText(row.date))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                Text(row.model)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if row.requests > 1 {
                                    Text("×\(row.requests)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 4)
                                Text(TokenFormat.label(row.totalTokens))
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .fixedSize()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 高度取 Cursor 页列表区的量级，面板里只占一小段
                .frame(height: 150)
                if ds.usageRows.count > 30 {
                    Text("Showing latest 30 of \(ds.usageRows.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // 当前 range 内按模型汇总，7d / 30d 时能直接看出各模型占了多少 token
    private var modelSummary: some View {
        let groups = Dictionary(grouping: ds.usageRows.filter { !$0.model.isEmpty }, by: \.model)
        let totals = groups.map { model, rows -> (model: String, requests: Int, tokens: Int, hit: Int, prompt: Int) in
            let tokens = rows.reduce(0) { $0 + $1.totalTokens }
            let requests = rows.reduce(0) { $0 + $1.requests }
            let hit = rows.reduce(0) { $0 + $1.cacheHitTokens }
            let prompt = rows.reduce(0) { $0 + $1.promptTokens }
            return (model, requests, tokens, hit, prompt)
        }
        .sorted { $0.tokens > $1.tokens }

        return Group {
            if !totals.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("By model")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(totals.prefix(4).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 6) {
                            Text(item.model)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if item.requests > 0 {
                                Text("×\(item.requests)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 4)
                            if item.prompt > 0 {
                                Text("hit \(Int(Double(item.hit) / Double(item.prompt) * 100))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(TokenFormat.label(item.tokens))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .fixedSize()
                        }
                    }
                }
            }
        }
    }

    // 数据来源说明与平台 token 入口
    private var usageSource: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(LocalizedStringKey(ds.hasPlatformToken
                     ? "Account usage from platform.deepseek.com"
                     : "Connect the platform to load account-wide usage"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                // 只做手动粘贴，展开后给出复制 token 的完整步骤
                Button(LocalizedStringKey(ds.hasPlatformToken ? "Token" : "Paste token")) {
                    showPlatformToken.toggle()
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }

            if let usageError = ds.usageError {
                Text(usageError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    // 允许换行，避免窄面板把长报错截成「HTTP 1…」
                    .fixedSize(horizontal: false, vertical: true)
            }

            // token 被平台判失效时，直接给一个能重新登录的入口，不用再去翻展开区
            if ds.platformTokenRejected {
                HStack(spacing: 6) {
                    Text("Token expired or rejected by the platform.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button(LocalizedStringKey("Sign in again")) { ds.connectPlatformFromBrowser() }
                        .controlSize(.small)
                }
            }

            if showPlatformToken {
                platformTokenEditor
            }
        }
    }

    // 手动粘贴 token：把「去哪复制」写成步骤，并提供把脚本放进剪贴板的入口
    private var platformTokenEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Paste the platform login token to load account-wide history. This is not the API key.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 复制路径一共四步，Console 脚本会把 token 直接放进剪贴板
            VStack(alignment: .leading, spacing: 3) {
                stepLine(1, "Open platform.deepseek.com and sign in.")
                stepLine(2, "Press ⌥⌘I for DevTools, then open the Console tab.")
                stepLine(3, "Click “Copy script”, paste it into the Console and press Return.")
                stepLine(4, "The token is now on the clipboard: click “Paste” below, then “Save”.")
            }

            Text("Console blocks pasting the first time: type allow pasting and press Return.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // 不想用脚本时的原始路径，值可能带 {"value":"..."} 外壳，应用会自动拆开
            Text("Or by hand: DevTools → Application → Local Storage → https://platform.deepseek.com → userToken → Value.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                SecureField("eyJ...", text: $ds.platformTokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Paste") { pastePlatformToken() }
                    .controlSize(.small)
                // 一键网页登录：自动读取 token，不用手工复制
                Button(LocalizedStringKey("Sign in")) { ds.connectPlatformFromBrowser() }
                    .controlSize(.small)
            }
            HStack(spacing: 8) {
                Button(LocalizedStringKey(didCopyScript ? "Script copied" : "Copy script")) { copyConsoleSnippet() }
                    .controlSize(.small)
                Button("Save") { ds.savePlatformToken() }
                    .controlSize(.small)
                if ds.hasPlatformToken {
                    Button("Delete") { ds.deletePlatformToken() }
                        .controlSize(.small)
                }
                // 保存过 cookie 时给个标记，方便确认 cURL 里的会话真的带上了
                if ds.hasPlatformCookie {
                    Text("cookie")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 0)
                // 打开原始请求日志，排查 token / 接口报错时用
                Button(LocalizedStringKey("Log")) {
                    if let url = DeepSeekLog.fileURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .buttonStyle(.link)
                .controlSize(.small)
                Button("Open platform usage") {
                    NSWorkspace.shared.open(platformUsageURL)
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }

            // cURL 里同时带 Authorization 和 Cookie，成功率最高
            Text("Or paste the whole “Copy as cURL” of the usage request; token and cookie are extracted automatically.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    // 带序号的说明行，窄面板里也能看清步骤顺序
    private func stepLine(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(number).")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 把 Console 脚本放进剪贴板，随后由用户粘到 DevTools 里执行
    private func copyConsoleSnippet() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(DeepSeekStore.consoleSnippet, forType: .string)
        didCopyScript = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            didCopyScript = false
        }
    }

    private func pastePlatformToken() {
        if let text = NSPasteboard.general.string(forType: .string) {
            ds.platformTokenDraft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // 余额来自 /user/balance；失败时只显示一行提示，不阻塞其他功能
    @ViewBuilder
    private var balanceLine: some View {
        if let balance = ds.balance, !balance.infos.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(balance.infos) { info in
                    HStack(spacing: 6) {
                        Text("Balance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(info.currency) \(info.totalBalance)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                        Spacer()
                        Text("Granted \(info.grantedBalance) · Topped up \(info.toppedUpBalance)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        } else if let error = ds.balanceError {
            Text("Balance: \(error)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        } else if ds.balance != nil {
            Text("Balance unavailable")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var cacheHitText: String {
        let stats = ds.usageStats
        guard stats.promptTokens > 0 else {
            return String(localized: "No requests yet")
        }
        let rate = Double(stats.cacheHitTokens) / Double(stats.promptTokens) * 100
        return String(
            format: String(localized: "Cache hit rate %.0f%% · %@ hit / %@ miss"),
            rate,
            TokenFormat.label(stats.cacheHitTokens),
            TokenFormat.label(stats.cacheMissTokens)
        )
    }

    private func statCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(LocalizedStringKey(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: 余额用的 API key

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("DeepSeek API key")
                    .font(.subheadline.weight(.semibold))
                if ds.hasKey {
                    Text("Saved")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Get key") { NSWorkspace.shared.open(platformKeysURL) }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }

            HStack(spacing: 6) {
                Group {
                    if showKey {
                        TextField("sk-...", text: $ds.apiKeyDraft)
                    } else {
                        SecureField("sk-...", text: $ds.apiKeyDraft)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                Button("Paste") { pasteAPIKey() }
                    .controlSize(.small)
                Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button("Save") { ds.saveKey() }
                    .controlSize(.small)
                if ds.hasKey {
                    Button("Delete") { ds.deleteKey() }
                        .controlSize(.small)
                }
                Spacer()
                Button("Open API docs") { NSWorkspace.shared.open(balanceDocsURL) }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }

            // 提醒：用量历史只能用平台网页 token 查，API key 只够看余额
            Text("The API key is used for the balance query only. Usage history needs the platform token above.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 直接从剪贴板填充 API key，避免无主菜单时 Cmd+V 失效
    private func pasteAPIKey() {
        if let text = NSPasteboard.general.string(forType: .string) {
            ds.apiKeyDraft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: 格式化

    // 用量列表的时间：24h 显示时分，7d/30d 的日桶显示月日
    private func usageTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        switch ds.usageRange {
        case .hours24:
            formatter.dateFormat = "HH:mm"
        case .days7, .days30:
            formatter.dateFormat = "MM-dd"
        }
        return formatter.string(from: date)
    }

    // 相对时间随系统 locale 显示
    private func relativeUpdated(from date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
