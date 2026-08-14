# Cursor Status Bar

macOS 菜单栏应用：用圆环显示 Cursor **Auto 剩余百分比**。点击打开面板，查看 API 余量、Reset 时间、24h / 7d / 30d token 图表和最近用量。

数据协议与 [m5stack-cardputer-sparks](https://github.com/KyleBing/m5stack-cardputer-sparks) 的 Cursor App 相同（非官方 `cursor.com` 仪表盘接口，可能变更）。

## 运行

```bash
open CursorStatusBar.xcodeproj
```

Xcode 选择 scheme **CursorStatusBar** 后 Run。应用不出现在 Dock，只在菜单栏显示圆环。

或命令行：

```bash
xcodebuild -scheme CursorStatusBar -configuration Debug -derivedDataPath build
open build/Build/Products/Debug/CursorStatusBar.app
```

**macOS 26**：打开 **系统设置 → 菜单栏**，在「允许在菜单栏中显示」里打开本应用。建议用 Finder 双击 `.app`（从 Cursor / Xcode 直接 Run，系统可能把图标记到 Cursor 名下并隐藏）。

## Token

本机已安装并登录 Cursor 时，启动会自动从 `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` 读取 `cursorAuth/accessToken`。也可在面板点 **从 Cursor 获取**。

仍可手动粘贴：浏览器登录 [cursor.com](https://cursor.com)，Cookies 里复制 `WorkosCursorSessionToken`（JWT，或 `userId::jwt`），点 **保存**。只写入本机 Keychain。

## 使用

| 操作 | 说明 |
|------|------|
| 左键圆环 | 打开面板 |
| 右键圆环 | 退出 |
| 24h / 7d / 30d | 查看对应区间 token 柱状图；右侧为该区间合计 |
| 从 Cursor 获取 | 从本机 Cursor SQLite 导入 session token |
| 刷新 | 重新拉取摘要、列表和当前图表 |
| 登录时打开 | 开机随用户登录启动 |

- 菜单栏圆环：Auto 剩余百分比（`100 - autoPercentUsed`）。
- 周期用量每 60 秒刷新；图表按模式缓存，切换不重复请求。
- Last usage 显示最近 20 条（时间、模型、token）。

## 要求

- macOS 14+
- 有效的 Cursor session token

## 发布

推送版本 tag（如 `v1.00`）后，GitHub Actions 会自动打包 `CursorStatusBar.app` 并上传到 [Releases](https://github.com/KyleBing/cursor-status-bar/releases)：

```bash
git tag v1.00
git push origin v1.00
```

变更记录见 [CHANGELOG.md](CHANGELOG.md)。
