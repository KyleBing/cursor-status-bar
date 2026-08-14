import SwiftUI
import Charts
import ServiceManagement

struct PopoverView: View {
    @EnvironmentObject var store: UsageStore
    @State private var tokenDraft = ""
    @State private var showToken = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hoverBar: ChartBar?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            Divider()
            chart
            Divider()
            lastList
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            settings
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color.white)
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

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Cursor usage")
                    .font(.headline)
                Spacer()
                if store.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            if let usage = store.usage {
                labeledPct("Auto", usage.autoRemaining)
                labeledPct("API", usage.apiRemaining)
                if let reset = usage.resetLabel {
                    Text(reset)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let err = store.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Text("保存 token 后刷新").font(.caption).foregroundStyle(.secondary)
            }
        }
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
                        Text("\(TokenFormat.label(chartTokenTotal)) tokens")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
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
                Text("悬停柱状图查看 token")
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
            .frame(height: 216)
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
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.lastEvents.isEmpty {
                        Text("暂无记录").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(store.lastEvents.prefix(20)) { ev in
                            HStack(alignment: .center, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(timeString(ev.timestamp))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(ev.model)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(ev.tokensLabel)
                                    .font(.title3.monospacedDigit().weight(.bold))
                                    .foregroundStyle(.primary)
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
            Text("Token")
                .font(.subheadline.weight(.semibold))
            HStack {
                Group {
                    if showToken {
                        TextField("WorkosCursorSessionToken", text: $tokenDraft)
                    } else {
                        SecureField("WorkosCursorSessionToken", text: $tokenDraft)
                    }
                }
                .textFieldStyle(.roundedBorder)
                Button(showToken ? "隐藏" : "显示") { showToken.toggle() }
                    .controlSize(.small)
            }
            HStack {
                Button("保存") {
                    store.applyToken(tokenDraft)
                }
                Button("刷新") {
                    Task { await store.refreshDetails(forceChart: true) }
                }
                Toggle("登录时打开", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        launchAtLogin = on
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                ))
                .toggleStyle(.checkbox)
                Spacer()
                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .controlSize(.small)
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}

private struct ChartHoverOverlay: View {
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
