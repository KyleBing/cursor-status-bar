import AppKit
import Foundation

// 界面语言：跟随系统或强制指定。
// 实现方式是写入 UserDefaults 的 AppleLanguages，资源在启动时解析，所以要重启应用生效。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    // 语言名按各自语言显示，和 macOS 的语言列表习惯一致
    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    private static let key = "appLanguage"
    private static let appleLanguagesKey = "AppleLanguages"

    // 当前选择；system 表示没有任何覆盖
    static var current: AppLanguage {
        get {
            let raw = UserDefaults.standard.string(forKey: key) ?? ""
            return AppLanguage(rawValue: raw) ?? .system
        }
        set {
            let defaults = UserDefaults.standard
            if newValue == .system {
                // 清掉覆盖，回到系统语言
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: appleLanguagesKey)
            } else {
                defaults.set(newValue.rawValue, forKey: key)
                // AppleLanguages 只在下次启动读取，正好避免运行中切换导致文案半新半旧
                defaults.set([newValue.rawValue], forKey: appleLanguagesKey)
            }
            defaults.synchronize()
        }
    }

    // 重启自身让语言生效：先起一个延迟的 open，再退出当前进程
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
