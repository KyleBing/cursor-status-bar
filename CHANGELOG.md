# Changelog

## 1.03 — 2026-10-21

- 面板顶部新增 **Cursor / DeepSeek** 两个 tab，并记住上次停留的 tab。
- 新增 DeepSeek tab（**只读用量面板**）：`/user/balance` 余额；24h / 7d / 30d token 柱状图、按小时 / 天拆分的用量列表与 **By model** 汇总（请求数、缓存命中率、token 总量）。用量历史来自 `platform.deepseek.com` 的账号维度接口，按当前区间的粒度与模型合并成行。
- 平台用量凭证支持两种粘贴形式：`localStorage.userToken` 的 `value`，或 DevTools Network 里用量请求的 **Copy as cURL**（自动提取 `Authorization` 与 `Cookie`）；token / cookie 分别存本机 Keychain。
- **手动复制平台凭证**：在 **Paste token** 里给出完整步骤（打开 `platform.deepseek.com` → `⌥⌘I` → Console → 粘贴应用提供的脚本，token 自动进剪贴板 → Paste → Save），也支持直接粘贴 `localStorage.userToken` 的 `value` 或 DevTools 的 **Copy as cURL**（自动提取 `Authorization` 与 `Cookie`）。不再自动读取浏览器数据，因此无需「完全磁盘访问权限」。
- 未配置平台 token 时用量区显示 `Connect platform` 引导，不再用本应用本地记录兜底。
- 修复 accessory 应用无主菜单导致输入框无法 `Cmd+V` 粘贴的问题：新增标准 Edit 菜单，并在 API key / 平台 token 输入框旁提供 **Paste** 按钮。
- DeepSeek API key 单独存 Keychain（account `deepseek.apiKey`），只用于查询余额。
- 面板滚动内容左右各留 2pt，输入框的边框与焦点环不再贴到裁剪边界。
- DeepSeek 的 **Last usage** 列表改为固定高度的独立滚动区，与 Cursor tab 的列表高度一致，行数多时不再把整页撑长。
- 新增**手动切换界面语言**：设置区可选项为跟随系统 / English / 简体中文（写入 `AppleLanguages`，点 **Relaunch** 重启后生效），菜单栏右键菜单标题也随之本地化。

## 1.02 — 2026-10-16

- 面板增加 On-demand 进度条展示。
- 设置区新增打开 Cursor Dashboard 网页入口。
- 7d / 30d 图表各自保留最后刷新时间；切换时若超过缓存有效期（7d/30d 半天、24h 半小时）自动刷新。
- 菜单栏可选外圈双环（中环 API 蓝、外环 Ond 橙，内圈 Auto 绿），默认关闭；开启时加粗描边、隐藏内圈数字。
- 移除 GitHub Actions 自动发布，改由本地 `./scripts/package.sh` 打包后手动上传 Release。

## 1.01 — 2026-08-20

- 界面文案英文化，并支持系统语言本地化（含简体中文 `Localizable.xcstrings`）。
- 相对时间与日期/时间格式随系统 locale 显示。
- AccessToken 输入框旁新增一键复制按钮。
- 设置区布局调整：Import / Save / Refresh 与 Open at login / Quit 分行排列。
- 本地打包脚本 `scripts/package.sh`，输出 zip / dmg 到 `dist/`。

## 1.00 — 2026-08-14

- macOS 菜单栏常驻：圆环显示 **Auto 剩余百分比**（已用更深、数字白色），无 Dock 图标。
- 点击打开原生面板：Auto / API 进度条、Reset 日期、24h / 7d / 30d token 柱状图、最近 20 条 usage。
- 图表按 token 聚合；分段控件右侧显示当前区间合计；切模式走缓存，点「刷新」才重拉。
- 本机已安装 Cursor 时，启动自动从本地 SQLite 读取 session token；面板提供「从 Cursor 获取」一键导入。
- Token 存在 Keychain；右键菜单栏图标可退出；支持登录时打开。
- macOS 26：需在 **系统设置 → 菜单栏** 中允许本应用显示。
- 面板标题显示版本号 **v1.00**，旁侧 GitHub 图标跳转仓库。
- 推送 `v*` tag 后自动打包并上传 GitHub Release。
