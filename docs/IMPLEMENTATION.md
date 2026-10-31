# 实现指南

本文面向后续维护,介绍插件的代码组织、数据流转,以及常见修改的落点与开发过程中积累的经验教训。
背景与设计取舍见[需求文档](REQUIREMENTS.md)与[架构文档](ARCHITECTURE.md),各 Tern API 的逐条说明见
[API 使用说明](API.md),此处不再重复。

---

## 1. 文件地图

```
plugin.toml          清单:id=dora-tern-omp-usage、host/window 入口、两个 block 声明(dashboard/sync)
host.luau            宿主端(host half,守护进程线程):
                       ├ fetch.service() 循环(每 5s,lib/fetch)
                       ├ sync 数据块(本机 kv → 一行 JSON 文本,5s 自刷新)
                       └ dashboard 仪表盘块(omp usage --history + kv.days 费用)
window.luau          窗口端(window half,每个窗口的 UI 线程):
                       ├ poll_loop 1s tick(焦点 pane → composer 树 → 画线)
                       ├ window_start / focus / budget 事件钩子
                       ├ 多主机:host 映射、sync 块读取、自动开块+驻留(park)
                       ├ 状态栏段(chrome.status,读缓存不读 kv!)
                       └ 设置菜单(pick/prompt)、命令、诊断
lib/parse.luau       纯函数,无 tern 调用(可单测):omp JSON → 内部模型
lib/fetch.luau       进程取数器:usage/models/stats 三任务,串行队列 + kv 锁互斥
lib/line.luau        线与卡片的模型组装 + 全部 CSS 生成
lib/settings.luau    设置读写(tern.kv)+ 调色板预设
lib/labels.luau      en / zh-CN 文案(缺键回退 en)
tern.d.luau          `tern plugin types .` 生成的类型定义(提交在库,供 luau-lsp)
docs/                需求 / 架构 / 实现 / API 说明
```

**常见修改的落点**:

| 想改什么 | 文件 · 位置 |
|---|---|
| 配色预设 | `lib/settings.luau` → `M.PRESETS`(每提供商)/ `M.NAMED`(备选) |
| 琥珀/红阈值默认值 | `lib/settings.luau` → `DEFAULTS.warn_at / bad_at` |
| 轮询间隔默认值 | `DEFAULTS.usage_interval / stats_interval`(秒) |
| 卡片行(加行/改文案) | `lib/line.luau` → `M.card_rows` |
| 线的布局/条宽/紧凑规则 | `lib/line.luau` → 顶部常量(`BAR_GLYPHS` 等)+ `line_of` |
| 新增设置项 | `lib/settings.luau`(DEFAULTS + load 校验)→ `window.luau` 菜单项 → `lib/labels.luau` 文案 |
| 新语言 | `lib/labels.luau` 加表 + `M.LANGUAGES` + `settings.luau` 的 language 校验 |
| 窗口归一化/去重规则 | `lib/parse.luau` → `window_of` / `M.report` |
| 多账号聚合 | `lib/line.luau` → `provider_windows` |
| 仪表盘内容 | `host.luau` → `history_cards` / `cost_card` 相关 |

## 2. 两条运行时

- **宿主端**运行在会话守护进程(或无守护进程的窗口)的工作线程,单次调用预算 2 秒;**窗口端**运行在
  每个窗口的 UI 线程,普通回调 50ms、chrome 格式化器仅 4ms。一旦超限,Tern 会**暂停相应钩子**
  (从 5 秒起指数退避)。插件已订阅 `budget` 事件:暂停时写入日志,恢复后立即重绘。
- **window_start** 每窗口触发一次,时机在会话落定(保存的标签页恢复完毕)之后,是首帧绘制的正确入口。
  注意 **reload 不会重新触发它**(joaodutra88 的注释也强调过),因此加载期定时器仍需保留。
- 宿主端与窗口端通过 **tern.kv** 共享数据(同一数据目录下的 kv.json)。`tern.kv.set` 采用"临时文件 + rename"
  原子写,并发写时后写者胜——因此取数环节设有 4 秒锁(`fetch_lock`)与串行队列(`busy`/`pending`)。

## 3. 数据流水线

```
宿主端(每台机器)                           窗口端(每个窗口)
────────────────────                        ─────────────────────
fetch.service(5s)                           tick(1s / focus / window_start / budget-resumed)
 ├ maybe_fetch("usage")                      ├ refresh_host_map:cx.hosts:list() → pane→主机
 │   omp usage --json → parse.usage          ├ refresh_sync_data(≤3s 一次):
 ├ maybe_fetch("models")                     │   对每个 info.block=="<id>.sync" 的 pane
 │   omp models --json → parse.catalog       │   cx.session:read(pane) → JSON → host_data[主机名]
 └ maybe_fetch("stats")                      ├ ensure_sync_block:当前主机是 remote 且无 sync 块
     omp stats --json → parse.today          │   → cx:new_block(...,"tab",{focus=false}) → park
         + by_provider 分解(差分累计)        ├ data_for(焦点pane):host_data[主机] 或本地 kv 兜底
 → kv: usage / models / today / days         ├ read_dock:composer 树 → 模型芯片名
                                             ├ line.build → line.sheet → tern.css("usage-plus", css)
sync 块:kv → ui.text(JSON 一行,≤7KB)      └ 状态栏(chrome.status,读 tick 缓存,不读 kv)
```

**kv 键一览**(数据目录:`%LOCALAPPDATA%\Tern\plugin-data\dora-tern-omp-usage\kv.json`,
WSL 在 `~/.local/state/tern/plugin-data/...`):

| 键 | 内容 | 写者 |
|---|---|---|
| `usage` | `{at, reports[], capacity}`(已归一、已去重) | fetch |
| `models` | `{at, by_name, by_selector, by_provider}` | fetch |
| `today` | `{at, tokens, cost, day, by_provider}` | fetch |
| `days` | `{"YYYY-MM-DD": {tokens, cost}}`(62 天滚动,仪表盘用) | fetch |
| `by_provider_today` / `by_model_snapshot` | 今日按提供商累计 / byModel 快照(跨零点差分用) | fetch |
| `settings` | 全部设置(DEFAULTS 见 settings.luau) | settings 模块 |
| `refresh_request` / `fetch_lock` / `trace` | 手动刷新请求 / 取数锁 / 最近 20 条取数事件 | fetch |

## 4. 渲染层(line.luau)

- 用量线是聚焦 omp 窗格上下文计量器(`.sf-meter[data-role='omp.composer.context']`)的
  `::before` **文本内容**;一条 `background-clip: text` 的静态渐变按字符区间着色并填充计量条
  (`━`×8,每字符 0.6em)。**条形位置按字符数推算,因此线内不能出现中文**——CJK 字宽约为
  等宽字符的两倍,会破坏填充与动效的对齐;中文仅出现在卡片里。
- 悬停目标是 composer 的空附件行(`omp.composer.chips`,平时隐藏);卡片是其 `::after`,
  默认 `visibility: hidden` 并带 0.5 秒过渡延迟,鼠标移开后短暂停留仍可悬停,不会一闪而过。
- 全部 CSS 在内容签名变化时整表重写(`tern.css("usage-plus", css)`),无状态残留;级联中的
  表名为 `plugin:local:dora-tern-omp-usage:usage-plus`。
- **锚点选择器集中在 line.luau 顶部**(`METER`/`HOST_BASE`)。Tern 升级后若线条消失,先用诊断命令
  确认树可读,再 dump 表面对照新版 DOM 调整选择器。

## 5. 经验与教训

以下均为开发过程中实际踩过的坑,改动相关代码前建议先读一遍。

1. **kv 静默写入失败**。kv.json 是 JSON,无法容纳 `math.huge` 之类的非法值,写入失败也不报错,
   表现为数据停止更新。为此窗口排序改用 `MAX_MS = 1e15` 代替无穷大。
2. **定时器不会自动循环**。`tern.timer` 是单次的,循环必须在回调里重新注册;漏掉即是"跑两次就死"。
3. **格式化器里不要读 kv**。`chrome.status` 的预算只有 4ms,而一次 kv 读取就要约 4ms——
   状态栏只读 tick 阶段准备好的缓存。
4. **每个回调至多启动一个进程**,回调本体控制在预算内,否则 Tern 会停用插件的全部定时器直至 reload。
5. **omp 的 stdout 可能带杂质**(`Syncing session files...`),解析前从第一个 `{` 截取。
6. **`omp models --json` 顶层是 `{models:[...]}` 对象**,不是裸数组。
7. **Kimi 的报告有重复窗口**:`limit_7d` 与 `7d` 数值存在舍入差,去重规则为
   "键以 `limit_` 开头,且与已知窗口的 resetAt 相差 2 分钟以内、用量相差 5 个百分点以内"。
8. **capacity 的窗口名可能是标签**(如 `7 Day`)而非 id,解析时只接受白名单键。
9. **多主机**:kv 不跨机器同步;远程数据依赖 sync 块(`cx.session:read` 可读远程块文本)。
   插件 id 一旦改名,kv 数据目录随之改名,历史数据需手工迁移。

## 6. 调试

- **诊断命令**(命令面板):显示焦点主机、sync 块列表、三类数据的更新时间、芯片名与映射到的提供商。
- **kv 直查**:路径见上;`trace` 键保留最近 20 条取数事件(spawned/callback/handler_error)。
- **日志**:Windows 在 `%LOCALAPPDATA%\Tern\Logs\tern.log`;预算暂停会有 `tern: <hook> exceeded <n> ms`。
- **无头调试**(zh-cn 插件作者的方法):`tern serve --control /tmp/tern.sock` +
  `tern ctl --control /tmp/tern.sock tree` dump DOM,用于调整 CSS 选择器。

## 7. 发布

1. 修改 `plugin.toml` 中的 `version`;
2. 提交并打标签:`git tag v0.x.y && git push --tags`;
3. 用户更新:`tern plugin install github.com/DoraJasmine/dora-tern-omp-usage --force`。
   (可选改进:GitHub Releases 检查与状态栏一键更新,joaodutra88 的 update.luau 是现成范式。)
