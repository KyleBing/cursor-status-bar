import SwiftUI
import AppKit
import Charts
import ServiceManagement

// 面板顶部的一级 tab
enum PopoverTab: String, CaseIterable, Identifiable {
    case cursor
    case deepSeek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursor: return "Cursor"
        case .deepSeek: return "DeepSeek"
        }
    }
}

struct PopoverView: View {
    @EnvironmentObject var store: UsageStore
    // 记住上次停留的 tab，下次打开面板保持选择
    @AppStorage("selectedPopoverTab") private var selectedTab: PopoverTab = .cursor
    @State private var tokenDraft = ""
    @State private var showToken = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hoverBar: ChartBar?
    @State private var tokenCopiedHint = false
    // 界面语言：改动后要重启才生效，所以单独记一个待重启标记
    @State private var language = AppLanguage.current
    @State private var languageNeedsRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            tabPicker
            switch selectedTab {
            case .cursor:
                cursorTab
            case .deepSeek:
                DeepSeekView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(width: 360)
        .task {
            if let t = TokenStore.load() { tokenDraft = t }
            await store.refreshDetails()
        }
        .onChange(of: store.chartRange) { _, range in
            Task { await store.selectChart(range) }
        }
    }

    private var tabPicker: some View {
        Picker("tab", selection: $selectedTab) {
            ForEach(PopoverTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // 原来的 Cursor 面板内容
    private var cursorTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            Divider()
            chart
            Divider()
            lastList
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            settings
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Cursor usage")
                    .font(.headline)
                // 标题旁显示最近一次用量刷新的相对时间
                if store.lastUpdated != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(relativeUpdated(from: store.lastUpdated, now: context.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.isLoading {
                    ProgressView().controlSize(.small)
                }
                // 版本号来自 Info.plist，与 GitHub tag 对齐
                Text("v\(appVersion)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                githubLink
            }
            if let usage = store.usage {
                labeledPct("Auto", usage.autoRemaining)
                labeledPct("API", usage.apiRemaining)
                // On-demand 用金额代替百分比，有上限时仍保留进度条
                if let ond = usage.ondLabel {
                    HStack(spacing: 8) {
                        Text("Ond")
                            .font(.subheadline.weight(.medium))
                            .frame(width: 36, alignment: .leading)
                        Text(ond)
                            .font(.subheadline.monospacedDigit())
                            .fixedSize()
                        if let ondPct = usage.ondRemaining {
                            ProgressView(value: Double(ondPct), total: 100)
                                .tint(ondPct <= 15 ? .red : .green)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                if let reset = usage.resetLabel {
                    Text(reset)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let err = store.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Text("Refresh after saving token").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // 相对时间随系统 locale 显示
    private func relativeUpdated(from date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    // Bundle 短版本，例如 1.03
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.03"
    }

    private var githubURL: URL {
        URL(string: "https://github.com/KyleBing/cursor-status-bar")!
    }

    private var dashboardURL: URL {
        URL(string: "https://cursor.com/dashboard?tab=usage")!
    }

    // 仅显示 GitHub 图标，点击打开仓库；不抢默认键盘焦点，避免打开面板时出现高亮框
    private var githubLink: some View {
        Button {
            NSWorkspace.shared.open(githubURL)
        } label: {
            Image("GitHubMark")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .help("GitHub")
    }

    private func labeledPct(_ title: String, _ pct: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(width: 36, alignment: .leading)
            Text("\(pct)%")
                .font(.subheadline.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
            ProgressView(value: Double(pct), total: 100)
                .tint(pct <= 15 ? .red : .green)
                .frame(maxWidth: .infinity)
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Picker("range", selection: $store.chartRange) {
                    ForEach(ChartRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168, alignment: .leading)
                .layoutPriority(1)

                Spacer(minLength: 8)

                Group {
                    if store.isChartLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(TokenFormat.label(chartTokenTotal)) tokens")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            // 当前 range 独立刷新时间，与上方周期用量不同步
                            if store.chartLastUpdated != nil {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(relativeUpdated(from: store.chartLastUpdated, now: context.date))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .frame(width: 120, alignment: .trailing)
            }

            if let hoverBar {
                Text("\(hoverBar.hoverTitle)  \(hoverBar.tokensLabel) tokens")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Hover chart to view tokens")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            ZStack {
                if store.chartBars.isEmpty {
                    Color.clear
                } else {
                    tokenChart
                        .opacity(store.isChartLoading ? 0.25 : 1)
                }
                if store.isChartLoading {
                    ProgressView()
                        .controlSize(.regular)
                }
            }
            // 图表区高度约为原先的 2/3
            .frame(height: 144)
        }
        .onChange(of: store.chartRange) { _, _ in
            hoverBar = nil
        }
    }

    private var tokenChart: some View {
        VStack(spacing: 0) {
            Chart(store.chartBars) { bar in
                BarMark(
                    x: .value("t", bar.category),
                    y: .value("tokens", bar.tokens),
                    width: .ratio(2.0 / 3.0)
                )
                .cornerRadius(0)
                .foregroundStyle(barFill(bar))
            }
            .chartXScale(domain: store.chartBars.map(\.category))
            .chartYScale(domain: yDomain)
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
                    bars: store.chartBars,
                    hoverBar: hoverBar,
                    onHover: { hoverBar = $0 }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 轴标签放在图外，不挤进每个柱的格子
            HStack(spacing: 0) {
                ForEach(store.chartBars) { bar in
                    Text(bar.axisLabel.isEmpty ? " " : bar.axisLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.leading, 28)
            .padding(.top, 4)
        }
    }

    private func barFill(_ bar: ChartBar) -> Color {
        if hoverBar == nil || hoverBar?.id == bar.id {
            return Color.accentColor
        }
        return Color.accentColor.opacity(0.28)
    }

    private var labeledCategories: [String] {
        store.chartBars.filter { !$0.axisLabel.isEmpty }.map(\.category)
    }

    private var chartTokenTotal: Int {
        store.chartBars.reduce(0) { $0 + $1.tokens }
    }

    private var yDomain: ClosedRange<Double> {
        let peak = store.chartBars.map(\.tokens).max() ?? 0
        let top = max(Double(peak) * 1.18, 1)
        return 0...top
    }

    private var lastList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last usage")
                .font(.subheadline.weight(.semibold))
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if store.lastEvents.isEmpty {
                        Text("No records").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(store.lastEvents.prefix(20)) { ev in
                            // 时间、模型、用量放在同一行
                            HStack(alignment: .center, spacing: 8) {
                                Text(timeString(ev.timestamp))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                Text(ev.model)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(ev.tokensLabel)
                                    .font(.body.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .fixedSize()
                                if ev.isIncluded {
                                    Text("Inc")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.green.opacity(0.25))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Text("AccessToken")
                    .font(.subheadline.weight(.semibold))
                Button {
                    copyTokenToPasteboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Copy access token")
                if tokenCopiedHint {
                    Text("Access token copied")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Group {
                    if showToken {
                        TextField("WorkosCursorSessionToken", text: $tokenDraft)
                    } else {
                        SecureField("WorkosCursorSessionToken", text: $tokenDraft)
                    }
                }
                .textFieldStyle(.roundedBorder)
                Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("Import from Cursor") {
                        if let token = store.importTokenFromCursor() {
                            tokenDraft = token
                        }
                    }
                    .disabled(!CursorLocalToken.isCursorInstalled)
                    .help(CursorLocalToken.isCursorInstalled
                        ? String(localized: "Import session token from local Cursor SQLite")
                        : String(localized: "Cursor not detected"))
                    Button("Save") {
                        store.applyToken(tokenDraft)
                    }
                    Button("Refresh") {
                        Task { await store.refreshDetails(forceChart: true) }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Toggle("Open at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { on in
                            launchAtLogin = on
                            try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        }
                    ))
                    .toggleStyle(.checkbox)
                    Spacer(minLength: 0)
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                }
                // 三柱：左绿 Auto、中蓝 API、右橙 Demand，默认关
                Toggle("Usage bars", isOn: $store.showExtraRings)
                    .toggleStyle(.checkbox)
                    .help("Three bars: green Auto, blue API, orange On-demand")
                // 界面语言：跟随系统 / English / 简体中文，写 AppleLanguages 后重启生效
                HStack(spacing: 6) {
                    Text("Language")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Language", selection: $language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.title).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                    if languageNeedsRestart {
                        Text("Restart to apply")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("Relaunch") { AppLanguage.relaunch() }
                            .buttonStyle(.link)
                            .font(.caption2)
                    }
                    Spacer(minLength: 0)
                }
                .onChange(of: language) { _, newValue in
                    // 选择先落盘，重启后读取；提示用户可以立刻重启
                    AppLanguage.current = newValue
                    languageNeedsRestart = true
                }
                // 最后一排：打开 Cursor Dashboard 网页
                Button {
                    NSWorkspace.shared.open(dashboardURL)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "safari")
                        Text("Open Cursor Dashboard")
                    }
                }
                .buttonStyle(.link)
            }
            .controlSize(.small)
        }
    }

    // 复制当前输入框中的 AccessToken，并短暂显示已复制提示
    private func copyTokenToPasteboard() {
        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        tokenCopiedHint = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            tokenCopiedHint = false
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: date)
    }
}

struct ChartHoverOverlay: View {
    let proxy: ChartProxy
    let bars: [ChartBar]
    let hoverBar: ChartBar?
    let onHover: (ChartBar?) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let hoverBar, let frame = proxy.plotFrame, let xPos = proxy.position(forX: hoverBar.category) {
                    let plot = geo[frame]
                    Text(hoverBar.tokensLabel)
                        .font(.caption2.monospacedDigit())
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .offset(
                            x: min(max(plot.minX + xPos - 18, plot.minX + 4), plot.maxX - 48),
                            y: plot.minY + 4
                        )
                }
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard let frame = proxy.plotFrame else { return }
                            let x = point.x - geo[frame].origin.x
                            if let cat: String = proxy.value(atX: x) {
                                onHover(bars.first { $0.category == cat })
                            }
                        case .ended:
                            onHover(nil)
                        }
                    }
            }
        }
    }
}
