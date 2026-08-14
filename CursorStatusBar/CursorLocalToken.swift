import Foundation
import SQLite3

enum CursorLocalToken {
    enum ImportError: LocalizedError {
        case cursorNotInstalled
        case dbMissing
        case openFailed
        case tokenMissing

        var errorDescription: String? {
            switch self {
            case .cursorNotInstalled: return "未检测到已安装的 Cursor"
            case .dbMissing: return "未找到 Cursor 本地数据库"
            case .openFailed: return "无法读取 Cursor 数据库"
            case .tokenMissing: return "Cursor 数据库中没有 accessToken，请先在 Cursor 里登录"
            }
        }
    }

    // Cursor 桌面端默认安装路径
    private static let appPath = "/Applications/Cursor.app"
    private static let tokenKey = "cursorAuth/accessToken"

    static var isCursorInstalled: Bool {
        FileManager.default.fileExists(atPath: appPath)
            || FileManager.default.fileExists(atPath: dbURL.path)
    }

    static var dbURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    // SQLite 复制绑定字符串，避免 Swift 临时 CString 在 step 前被释放
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // 从本机 Cursor state.vscdb 读取 JWT（只读，不复制大库）
    static func readAccessToken() -> Result<String, ImportError> {
        guard isCursorInstalled else { return .failure(.cursorNotInstalled) }
        let path = dbURL.path
        guard FileManager.default.fileExists(atPath: path) else { return .failure(.dbMissing) }

        var db: OpaquePointer?
        // 先按普通路径只读打开；失败再走 URI（含 immutable，避开 Cursor 占用 WAL）
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let openAttempts: [(String, Int32)] = [
            (path, SQLITE_OPEN_READONLY),
            ("file://\(encoded)?mode=ro", SQLITE_OPEN_READONLY | SQLITE_OPEN_URI),
            ("file://\(encoded)?mode=ro&immutable=1", SQLITE_OPEN_READONLY | SQLITE_OPEN_URI),
        ]
        var opened = false
        for (filename, flags) in openAttempts {
            if sqlite3_open_v2(filename, &db, flags, nil) == SQLITE_OK, db != nil {
                opened = true
                break
            }
            if let db { sqlite3_close(db) }
            db = nil
        }
        guard opened, let db else { return .failure(.openFailed) }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return .failure(.openFailed)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, tokenKey, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return .failure(.tokenMissing) }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return .failure(.tokenMissing) }

        var token = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 {
            token = String(token.dropFirst().dropLast())
        }
        guard !token.isEmpty else { return .failure(.tokenMissing) }
        return .success(token)
    }
}
