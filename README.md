# Cursor Status Bar

<img width="406" height="746" alt="image" src="https://github.com/user-attachments/assets/2a9ed11a-bf66-436e-8cd2-728f2d56793d" />

<img width="406" height="746" alt="image" src="https://github.com/user-attachments/assets/bb9c1b5c-0cb2-4fd3-9f8c-8c3bb030b504" />



macOS 菜单栏应用：默认用圆环显示 Cursor **Auto 剩余百分比**，也可切换成三根用量柱（Auto / API / On-demand）。点击打开面板，顶部可切换两个 tab：

- **Cursor**：Auto / API / On-demand 三个用量进度条、Reset 时间、24h / 7d / 30d token 图表和最近用量。
- **DeepSeek**：账户余额、**By model** 汇总，以及 24h / 7d / 30d 的 token 柱状图与按小时 / 天拆分的用量列表。用量历史来自 `platform.deepseek.com` 的账号维度接口，需要手动复制一次网页登录 token（或粘 DevTools 的 **Copy as cURL**）；余额来自 `/user/balance`（API key）。不含对话功能。

Cursor 数据协议与 [m5stack-cardputer-sparks](https://github.com/KyleBing/m5stack-cardputer-sparks) 的 Cursor App 相同（非官方 `cursor.com` 仪表盘接口，可能变更）。

## 菜单栏显示

菜单栏图标有两种形态，可在面板设置区勾选 **Usage bars** 切换：

| 形态 | 说明 |
|------|------|
| 圆环（默认） | 绿色扇形 + 居中数字，表示 Auto 剩余百分比（`100 - autoPercentUsed`）；未取到数据时显示 `--` |
| 三根用量柱 | 左绿 **Auto**、中蓝 **API**、右橙 **On-demand**，宽度 27×18，比圆环略宽 |

三根柱都是「淡色整柱为轨道，实色从底部向上填充剩余比例」：

- **Auto**：`100 - autoPercentUsed`。
- **API**：`100 - apiPercentUsed`。
- **On-demand**：有额度上限时按 `100 - 已用金额 / 上限` 计算；没有上限或接口未返回数据时，只显示淡色轨道。
- 某个值缺失时只画对应柱子的轨道，不影响其他柱子。

## 运行

```bash
open CursorStatusBar.xcodeproj
```

Xcode 选择 scheme **CursorStatusBar** 后 Run。应用不出现在 Dock，只在菜单栏显示图标。

或命令行：

```bash
xcodebuild -scheme CursorStatusBar -configuration Debug -derivedDataPath build
open build/Build/Products/Debug/CursorStatusBar.app
```

**macOS 26**：打开 **系统设置 → 菜单栏**，在「允许在菜单栏中显示」里打开本应用。建议用 Finder 双击 `.app`（从 Cursor / Xcode 直接 Run，系统可能把图标记到 Cursor 名下并隐藏）。

## Token

本机已安装并登录 Cursor 时，启动会自动从 `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` 读取 `cursorAuth/accessToken`。也可在面板点 **从 Cursor 获取**。

仍可手动粘贴：浏览器登录 [cursor.com](https://cursor.com)，Cookies 里复制 `WorkosCursorSessionToken`（JWT，或 `userId::jwt`），点 **保存**。只写入本机 Keychain。

### DeepSeek

DeepSeek 的凭证分两种，互不替代：

- **API key**（`sk-...`）：在 DeepSeek tab 底部粘贴后点 **Save**，只写入本机 Keychain（account `deepseek.apiKey`），仅用于通过 `/user/balance` 查余额。
- **平台登录 token / cookie**：仅用于账号维度的用量历史，见下面一段。存 Keychain `deepseek.platformToken` / `deepseek.platformCookie`。

用量历史只能用 `platform.deepseek.com` 的网页登录凭证查：DeepSeek 的公开 API 不提供账号维度用量，API key 调平台用量接口会返回 `biz_code 40003`。打开面板的 **Paste token**，按里面的步骤手动复制一次即可：在已登录的 `platform.deepseek.com` 页面按 `⌥⌘I` 打开 DevTools，切到 **Console**，点应用里的 **Copy script** 把脚本粘进去回车（token 会自动进入剪贴板），再回面板点 **Paste** → **Save**。也可以手动找：DevTools → **Application** → **Local Storage** → `https://platform.deepseek.com` → `userToken` → `Value`（值带 `{"value":"..."}` 外壳也没关系）；或直接粘贴 DevTools Network 里那条用量请求的 **Copy as cURL**——应用会自动提取 `Authorization` 与 `Cookie`。token / cookie 只存本机 Keychain（account `deepseek.platformToken` / `deepseek.platformCookie`），不再自动读取浏览器数据，因此不需要「完全磁盘访问权限」。

## DeepSeek 面板

DeepSeek tab 是只读用量面板，不含对话功能：

- **余额**：来自 `/user/balance`（API key），显示币种、总余额、赠送余额（Granted）与充值余额（Topped up）。
- **区间图表**：24h / 7d / 30d 的 token 柱状图，右侧显示区间合计；下方依次为 Requests、Prompt、Completion、Total、Cache hit、Reasoning 六项统计和缓存命中率。
- **By model**：按模型合并当前区间的请求数、缓存命中率与 token 总量，最多显示 4 个模型。
- **用量列表**：按小时（24h）或按天（7d / 30d）拆分；数据来自 `platform.deepseek.com` 的账号维度接口，未配置平台凭证时显示 **Connect platform** 引导。

## 使用

| 操作 | 说明 |
|------|------|
| 左键菜单栏图标 | 打开面板 |
| 顶部 Cursor / DeepSeek | 切换面板 tab，选择会记住 |
| Usage bars | 菜单栏在「Auto 圆环」与「三根用量柱」之间切换，默认关闭 |
| DeepSeek 的 24h / 7d / 30d | 查看该区间 token 柱状图、按小时 / 天拆分的列表与 By model 汇总 |
| DeepSeek 的 Paste token | 手动粘贴平台登录 token（内置 **Copy script** 引导，也可粘 **Copy as cURL**） |
| 右键菜单栏图标 | 退出 |
| 24h / 7d / 30d | 查看对应区间 token 柱状图；右侧为该区间合计 |
| 从 Cursor 获取 | 从本机 Cursor SQLite 导入 session token |
| 刷新 | 重新拉取摘要、列表和当前图表 |
| 登录时打开 | 开机随用户登录启动 |
| 语言 | 跟随系统 / English / 简体中文，选择后点 **Relaunch** 重启生效 |

- 菜单栏圆环：Auto 剩余百分比（`100 - autoPercentUsed`）。
- 勾选 **Usage bars** 后，菜单栏改为三根柱：绿 Auto、蓝 API、橙 On-demand，柱子填充高度即剩余百分比，详见[菜单栏显示](#菜单栏显示)。
- 周期用量每 60 秒刷新；图表按模式缓存，切换不重复请求。
- Last usage 显示最近 20 条（时间、模型、token）。

## 要求

- macOS 14+
- Cursor tab：有效的 Cursor session token
- DeepSeek tab（可选）：API key 用于查余额；平台登录 token 用于查用量历史

## 打包

本地生成 zip / dmg（输出到 `dist/`）：

```bash
./scripts/package.sh
```

产物：`dist/CursorStatusBar-<version>.zip` 与 `dist/CursorStatusBar-<version>.dmg`。

## 发布

本地打包后，手动上传到 [Releases](https://github.com/KyleBing/cursor-status-bar/releases)：

```bash
./scripts/package.sh
# 在 GitHub 创建 Release，上传 dist/CursorStatusBar-<version>.zip 或 .dmg
```

可选：打版本 tag 便于对照版本号（不再触发自动编译）：

```bash
git tag v1.01
git push origin v1.01
```

变更记录见 [CHANGELOG.md](CHANGELOG.md)。
