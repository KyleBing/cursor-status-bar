import Foundation

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

    // Auto 剩余百分比，给状态栏圆环用
    var autoRemaining: Int { clamp(100 - autoPercentUsed) }
    var apiRemaining: Int { clamp(100 - apiPercentUsed) }

    // On-demand 剩余百分比（有额度上限时才有意义）
    var ondRemaining: Int? {
        guard ondValid, ondLimitCents > 0 else { return nil }
        let usedPct = Double(ondUsedCents) / Double(ondLimitCents) * 100
        return clamp(100 - usedPct)
    }

    var ondLabel: String? {
        guard ondValid else { return nil }
        let used = Double(ondUsedCents) / 100.0
        if ondLimitCents > 0 {
            let limit = Double(ondLimitCents) / 100.0
            return String(format: "ond $%.2f/$%.2f", used, limit)
        }
        return String(format: "ond $%.2f", used)
    }

    var resetLabel: String? {
        guard let end = billingCycleEnd else { return nil }
        let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: end).day ?? 0)
        let fmt = DateFormatter()
        fmt.dateStyle = .long
        fmt.timeStyle = .none
        let dateText = fmt.string(from: end)
        let dayWord = days == 1 ? "day" : "days"
        return "Reset in \(days) \(dayWord) on \(dateText)"
    }

    private func clamp(_ value: Double) -> Int {
        Int(min(100, max(0, value)).rounded())
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
