# 实现指南

本文面向后续维护,介绍插件的代码组织、数据流转,以及常见修改的落点与开发过程中积累的经验教训。
背景与设计取舍见[需求文档](REQUIREMENTS.md)与[架构文档](ARCHITECTURE.md),各 Tern API 的逐条说明见
[API 使用说明](API.md),此处不再重复。

---

## 1. 文件地图

```
plugin.toml          清单:id=dora-tern-omp-usage、host/window 入口、dashboard block 声明
host.luau            宿主端(host half,守护进程线程):
                       ├ fetch.service() 循环(每 5s,lib/fetch)
                       └ dashboard 仪表盘块(omp usage --history + 各源 days@ 费用)
window.luau          窗口端(window half,每个窗口的 UI 线程):
                       ├ poll_loop 1s tick(焦点 pane → composer 树 → 画线)
                       ├ window_start / focus / budget 事件钩子
                       ├ 多主机:host 映射与数据源解析(pane→host→source)
                       ├ 状态栏段(chrome.status,读缓存不读 kv!)
                       └ 设置菜单(pick/prompt)、命令、诊断
lib/parse.luau       纯函数,无 tern 调用(可单测):omp JSON → 内部模型
lib/fetch.luau       取数器:数据源(local / wsl:<发行版> / ssh:<主机>)、按源串行队列与锁
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
| 新增数据源类型 | `lib/fetch.luau` → `argv_for` / `invalidate_argv` + `window.luau` 的 `source_for_host` |
| 仪表盘内容 | `host.luau` → `history_cards` / `costs` |

## 2. 两条运行时

- **宿主端**运行在会话守护进程(或无守护进程的窗口)的工作线程,单次调用预算 2 秒;**窗口端**运行在
  每个窗口的 UI 线程,普通回调 50ms、chrome 格式化器仅 4ms。一旦超限,Tern 会**暂停相应钩子**
  (从 5 秒起指数退避)。插件已订阅 `budget` 事件:暂停时写入日志,恢复后立即重绘。
- **window_start** 每窗口触发一次,时机在会话落定(保存的标签页恢复完毕)之后,是首帧绘制的正确入口。
  注意 **reload 不会重新触发它**(joaodutra88 的注释也强调过),因此加载期定时器仍需保留。
- 宿主端与窗口端通过 **tern.kv** 共享数据(同一数据目录下的 kv.json)。`tern.kv.set` 采用"临时文件 + rename"
  原子写,并发写时后写者胜——因此每个数据源都有独立的串行队列与锁(`fetch_lock@<源>`)。

## 3. 数据流水线

```
宿主端(每台机器)                              窗口端(每个窗口)
──────────────────────                          ─────────────────────
fetch.service(5s)                               tick(1s / focus / window_start / budget-resumed)
 ├ detect_wsl(10min):wsl.exe -l -q              ├ refresh_host_map:cx.hosts:list() → pane→主机
 ├ maybe_fetch(local,"usage")                   ├ refresh_cache:各源 usage@/today@ 快照
 │   omp usage --json → parse.usage             ├ data_for(焦点pane):host→source→数据
 ├ maybe_fetch(local,"models")                  ├ read_dock:composer 树 → 模型芯片名
 │   omp models --json → parse.catalog          └ line.build → line.sheet → tern.css
 ├ maybe_fetch(local,"stats")
 │   omp stats --json → 当日总量 + 按提供商账本
 └ maybe_fetch("wsl:<发行版>" / "ssh:<主机>", …)
     同样的三条命令,穿透到对应机器执行

数据按键"kind@<source>"分源存储:usage@local、usage@wsl:Ubuntu-22.04、
today@ssh:dora@wsl、days@local、days@wsl:…;窗口按焦点窗格所属主机选用。
```

**kv 键一览**(数据目录:`%LOCALAPPDATA%\Tern\plugin-data\dora-tern-omp-usage\kv.json`,
WSL 在 `~/.local/state/tern/plugin-data/...`;`<s>` 为数据源名):

| 键 | 内容 |
|---|---|
| `usage@<s>` / `models@<s>` | 各源限额报告(已归一、已去重)/ 模型目录 |
| `today@<s>` | `{at, tokens, cost, day, by_provider}` 当日统计与按提供商分解 |
| `days@<s>` | 各源逐日 `{tokens, cost}`(62 天滚动,仪表盘聚合用) |
| `provider_days@<s>` / `by_model_prev@<s>` | 按提供商的当日账本 / byModel 累计基线(差分用) |
| `wsl_distros` / `remote_hosts` | 检测到的 WSL 发行版 / 窗口上报的已连接远程主机 |
| `fetch_lock@<s>` | 各源取数锁(4 秒窗口) |
| `settings` | 全部设置(DEFAULTS 见 settings.luau) |
| `refresh_request` / `trace` | 手动刷新请求 / 最近 20 条取数事件(带 source 标注) |

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

## 4.1 性能画像

- 窗口 tick(1s):三次 kv 读 + `hosts:list` + composer 树(~40 节点)——与 jmazzola 同款节奏;
- CSS 整表重写:数据变化或倒计时跳分时(约每分钟一次),单次 4~6KB 字符串拼接,可忽略;
- omp 进程 spawn 串行且受设置控制(usage 90s / stats 5min / models 10min,单次 0.3~0.6s);
- 内存观测:诊断命令会报告窗口 VM 的 Lua 堆(`collectgarbage("count")`)与 kv.json 体积。

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
9. **多主机**:kv 不跨机器同步。远程主机的数据由取数器按源穿透获取(WSL 走 wsl.exe,
   ssh 主机走 ssh),源与数据的键都带来源前缀。插件 id 一旦改名,kv 数据目录随之改名,
   历史数据需手工迁移。
10. **改名/搬移函数后必须全仓 grep 旧名**。多轮脚本补丁叠加时,漏改一处调用就是运行时
    "call a nil value";`tern plugin types` 可作语法门,但查不出 nil 引用。
11. **Luau 没有位运算符**(`<<` 等会直接语法错误),且工具链多层转义容易把 `\n` 写成真实换行——
    Lua 双引号字符串不允许跨行,生成代码时宁可不用转义。

## 6. 调试

- **诊断命令**(命令面板):显示焦点主机与数据源、各源的 usage/today 更新时间、芯片名与
  映射到的提供商、窗口 VM 的 Lua 堆与 kv.json 体积。
- **kv 直查**:路径见上;`trace` 键保留最近 20 条取数事件(spawned/callback/handler_error,
  均带 source 标注)。
- **日志**:Windows 在 `%LOCALAPPDATA%\Tern\Logs\tern.log`;预算暂停会有 `tern: <hook> exceeded <n> ms`,
  样式表解析错误会有 `plugin style sheet has errors`(含每条被丢弃规则的行号与原因)。
- **无头调试**(zh-cn 插件作者的方法):`tern serve --control /tmp/tern.sock` +
  `tern ctl --control /tmp/tern.sock tree` dump DOM,用于调整 CSS 选择器。

## 7. 发布

1. 修改 `plugin.toml` 中的 `version`;
2. 提交并打标签:`git tag v0.x.y && git push --tags`;
3. 用户更新:`tern plugin install github.com/DoraJasmine/dora-tern-omp-usage --force`。
   (可选改进:GitHub Releases 检查与状态栏一键更新,joaodutra88 的 update.luau 是现成范式。)
