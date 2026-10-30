import Foundation

// 旧套餐拆 Auto/API；融合套餐只有总用量百分比
enum CursorPlanKind: String, Equatable {
    case classic
    case unified
}

struct PeriodUsage: Equatable {
    var autoPercentUsed: Double = 0
    var apiPercentUsed: Double = 0
    var totalPercentUsed: Double?
    var remaining: Double?
    var limit: Double?
    var ondUsedCents: Int = 0
    var ondLimitCents: Int = 0
    var ondValid: Bool = false
    var billingCycleEnd: Date?
    // 解析接口后标记，UI 按此切换 Auto/API 或 Included
    var planKind: CursorPlanKind = .classic

    // Auto / 融合 Included 剩余百分比，给状态栏圆环用
    var autoRemaining: Int { clamp(100 - autoPercentUsed) }
    var apiRemaining: Int { clamp(100 - apiPercentUsed) }

    // On-demand 剩余百分比（有额度上限时才有意义）
    var ondRemaining: Int? {
        guard ondValid, ondLimitCents > 0 else { return nil }
        let usedPct = Double(ondUsedCents) / Double(ondLimitCents) * 100
        return clamp(100 - usedPct)
    }

    // 金额展示，例如 $2/$30；没有上限时只显示已用
    var ondLabel: String? {
        guard ondValid else { return nil }
        let used = Self.dollar(ondUsedCents)
        guard ondLimitCents > 0 else { return used }
        return "\(used)/\(Self.dollar(ondLimitCents))"
    }

    // 整美元不带小数，有分才保留两位
    private static func dollar(_ cents: Int) -> String {
        if cents % 100 == 0 {
            return "$\(cents / 100)"
        }
        return String(format: "$%.2f", Double(cents) / 100.0)
    }

    var resetLabel: String? {
        guard let end = billingCycleEnd else { return nil }
        return Self.resetText(until: end, prefix: "Reset")
    }

    static func resetText(until end: Date, prefix: String) -> String {
        let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: end).day ?? 0)
        let fmt = DateFormatter()
        fmt.dateStyle = .long
        fmt.timeStyle = .none
        let dateText = fmt.string(from: end)
        let dayWord = days == 1 ? "day" : "days"
        return "\(prefix) in \(days) \(dayWord) on \(dateText)"
    }

    private func clamp(_ value: Double) -> Int {
        Int(min(100, max(0, value)).rounded())
    }
}

// Grok Bot 周用量（DashboardService GetSandUsageStatus）；无额度时不展示
struct GrokBotUsage: Equatable {
    var percentUsed: Double
    var resetAt: Date?
    var planLabel: String?

    // 与 Auto/API 一致：进度条按剩余百分比
    var remaining: Int {
        Int(min(100, max(0, 100 - percentUsed)).rounded())
    }

    var resetLabel: String? {
        guard let end = resetAt else { return nil }
        return PeriodUsage.resetText(until: end, prefix: "Grok reset")
    }
}

struct UsageEvent: Identifiable, Equatable {
    var id: String { "\(timestamp.timeIntervalSince1970)-\(model)-\(totalTokens)" }
    var timestamp: Date
    var model: String
    var kind: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheWriteTokens: Int
    var cacheReadTokens: Int
    var totalCents: Double
    var chargedCents: Double

    var totalTokens: Int { inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens }
    // 兼容旧 kind 与 Connect 枚举名 USAGE_EVENT_KIND_INCLUDED_IN_*
    var isIncluded: Bool { kind.uppercased().contains("INCLUDED") }
    var chartCents: Double { totalCents > 0 ? totalCents : chargedCents }

    var tokensLabel: String { TokenFormat.label(totalTokens) }
}

enum TokenFormat {
    static func label(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.1fK", d / 1_000) }
        return "\(n)"
    }
}

struct ChartBar: Identifiable {
    var id: String
    var xIndex: Int
    var axisLabel: String
    var hoverTitle: String
    var tokens: Int
    var tokensLabel: String { TokenFormat.label(tokens) }
    // 分类轴用，保证柱宽 ratio 生效
    var category: String { String(format: "%03d", xIndex) }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case hours24 = "24h"
    case days7 = "7d"
    case days30 = "30d"
    var id: String { rawValue }
}
