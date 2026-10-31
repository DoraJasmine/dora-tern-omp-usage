# Changelog

## 1.1.0 — 2026-11-01

### 新增

- **多主机数据支持**:在远程主机(如 WSL、服务器)上工作时,卡片与状态栏展示该主机自己的账户额度与当日统计。实现方式为插件在远程主机上自动开启并驻留一个数据块,全程无需配置。
- **按提供商分解的当日统计**:悬浮卡片在当日总量之下,按用量降序列出各服务的 token 与费用。
- **Z.ai 与 ZCode**:新增对应提供商的显示标签与配色预设。
- **文档**:新增实现指南(IMPLEMENTATION.md)与 Tern API 使用说明(API.md),并附第三方声明(THIRD-PARTY-NOTICES.md)。

### 改进

- 悬浮卡片支持悬停停留:鼠标移入卡片不再消失。
- 当日统计行改以主机名标注;远程主机数据不可用时如实说明,不再回退为本机数字。
- 命令面板的模型前缀匹配更稳健,可正确识别带数字的模型名(如 K3.1)。
- 术语规范化:文档统一采用"宿主端(host half)/ 窗口端(window half)"。

### 修复

- 修复启动时偶现的 "no block type ... on this host" 提示(现为目录就绪后才开块)。
- 修复 sync 数据块意外退出的问题(渲染全程容错,错误内联显示)。
- 修复打开仪表盘时可能误聚焦驻留数据块的问题。

## 1.0.0 — 2026-11-01

First stable release.

- **Usage line** above the omp composer's context bar, for **every provider omp reports**
  (Kimi, Codex, Claude, Gemini, MiniMax, Qwen, Z.ai, …): per-window bars, share left, reset
  countdowns, saved resets; provider colors (amber ≤25% left, red ≤10%); compact layout in
  narrow panes; change comets without motion for Reduce-Motion users.
- **Hover card**: per-window meters, reset times and clock times, saved-reset expiries, today's
  totals with a **per-provider breakdown**, settings shortcut; stays open while you point at it.
- **Model follow**: switches with the focused agent's provider in ~2 s (Alt+P); follows a viewed
  subagent's model.
- **Per-host data**: panes on remote hosts (WSL, servers) show that host's accounts and stats.
  Handled with a tiny sync block the plugin opens and parks on each remote host automatically —
  no tabs, no omp configuration.
- **Today's tokens & API-price cost** in the status bar, per the focused pane's host.
- **Dashboard block**: 7 days of usage history, today/week/month API-price costs (`r` refreshes).
- **Settings** (Ctrl+Alt+U, status-bar `usage`, palette): show mode (current / all / selected),
  provider order, per-provider colors, thresholds, refresh intervals, status-bar toggles,
  language (English / 简体中文).
- **One-line install**, zero omp configuration: `tern plugin install github.com/DoraJasmine/dora-tern-omp-usage`

Requirements: Tern 0.8+ (tested on 0.9.8, Windows & WSL), omp 18.9+ (tested on 18.14.1).

Credits and third-party notices: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)
