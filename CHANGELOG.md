# Changelog

## Unreleased

- 本机已安装 Cursor 时，启动自动从本地 SQLite 读取 session token；面板提供「从 Cursor 获取」一键导入。

## 1.00 — 2026-08-14

- macOS 菜单栏常驻：圆环显示 **Auto 剩余百分比**（已用更深、数字白色），无 Dock 图标。
- 点击打开原生面板：Auto / API 进度条、Reset 日期、24h / 7d / 30d token 柱状图、最近 20 条 usage。
- 图表按 token 聚合；分段控件右侧显示当前区间合计；切模式走缓存，点「刷新」才重拉。
- Token 存在 Keychain；右键菜单栏图标可退出；支持登录时打开。
- macOS 26：需在 **系统设置 → 菜单栏** 中允许本应用显示。
- 面板标题显示版本号 **v1.00**，旁侧 GitHub 图标跳转仓库。
- 推送 `v*` tag 后自动打包并上传 GitHub Release。
