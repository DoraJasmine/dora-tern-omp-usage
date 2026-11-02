# Changelog

## 1.3.2 — 2026-11-02

### 新增

- **刷新间隔可配置**:设置菜单新增「用量刷新间隔…」(60–600 秒,默认 90)与「当日统计刷新间隔…」
  (60–3600 秒,默认 300),输入保存后下一轮取数即生效,无需重启。

### 修复

- 修复诊断命令中 `stale` 的重复声明(Luau shadow 警告)。

## 1.3.1 — 2026-11-01

### 修复

- 修复启动时 "window_start failed: attempt to call a nil value" 的作用域错误:启动钩子的注册
  移至 `check_updates` 定义之后,启动提醒与首帧绘制恢复正常。

## 1.3.0 — 2026-11-01

### 新增

- **更新提醒强化**:有新版本期间,每次启动 Tern 都会提醒一次(此前每版本仅提醒一次,容易错过);状态栏的「⬆ Update」段常驻高亮,点击一键更新,完成后自动热重载,无需重启。
- **更新检查开关**:设置菜单新增「检查更新」开关,可完全关闭自动检查。
- **ssh 主机支持**:连接 ssh 主机后,其额度与当日统计按主机穿透获取(远端只需 omp 可用)。

### 改进

- 诊断命令显示焦点主机与数据源、各源数据年龄、窗口内存占用(Lua 堆与 kv 体积)。
- 文档更新:实现指南与 API 使用说明与多源数据架构同步。

### 修复

- 修复打开仪表盘时可能误聚焦同名数据块的问题。

## 1.2.2 — 2026-11-01

### 新增

- **更新检查**:每日查询 GitHub Releases(releases.atom 源,无 API 配额限制);发现新版本时,状态栏出现高亮的「⬆ Update」段(点击一键更新),并弹出一次提示。一键更新完成后插件自动热重载,无需重启 Tern。

## 1.2.0 — 2026-11-01

### 新增

- **多主机数据源架构**:数据总线从"常驻数据块"重构为按源直取——本机源之外,WSL 发行版经
  wsl.exe 穿透取数,ssh 主机经 ssh 穿透取数(远端只需 omp 与登录 shell 可用)。数据、账本与
  仪表盘费用均按源分键,窗口按焦点窗格所属主机选用。
- **诊断命令增强**:显示焦点主机与数据源、各源的 usage/today 更新时间、窗口 VM 的 Lua 堆
  (`collectgarbage`)与 kv.json 体积。

### 改进

- 当日金额与 token 计数统一显示精度(金额两位小数,token 千/百万级一位小数)。
- 按提供商的当日统计改用连续差分账本,并与当日总量逐轮对账:跨零点、统计库滚动与
  漏取均自愈,总量永远精确。
- 模型切换即时生效:重绘缓存数据的同时,对焦点数据源强制刷新一次。
- 文档全面更新:实现指南与 API 使用说明改为按源架构,需求与架构文档同步。

### 修复

- 修复数据块退役后遗留的浮窗卡片("Could not start the block")。
- 修复多轮重构遗留的系列运行时错误(丢失的 host 映射、未导出的取数函数、invalidate
  参数错序)。
- 移除常驻浮窗数据块,一并消除其在驻留甲板中的卡片显示。

### 说明

- 本版本的数据架构不依赖任何常驻块窗格;远程主机侧无需安装本插件(WSL 经 wsl.exe、
  ssh 主机经 ssh 直连取数)。

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
