# Tern API 使用文档

本插件用到的每一个 Tern API:**是什么、怎么用、用在哪、有什么要注意的**。
官方文档:<https://docs.stencil.so/tern/>(每页有 `.md` 版本);类型定义见仓库根的 `tern.d.luau`
(用 `tern plugin types .` 重新生成)。

---

## 0. 总览

| API | 半区 | 用途 | 使用位置 |
|---|---|---|---|
| `tern.kv.get / set` | 双方 | 插件持久化:数据缓存 + 设置 | fetch / settings / 两入口 |
| `tern.json.decode / encode` | 双方 | 解析 omp CLI 输出、sync 块载荷 | fetch / parse / line / window |
| `tern.timer(ms, fn)` | 双方 | 一切轮询与延迟(单次,循环须自续) | fetch / host / window |
| `tern.process.run` | 双方 | 运行 omp CLI | fetch / host(仪表盘) |
| `tern.getenv` | 双方 | 定位 omp 可执行文件 | fetch.omp_bin |
| `tern.fs.exists` | 双方 | omp 路径探测 | fetch.omp_bin |
| `tern.log.info` | 窗口 | budget 暂停/恢复留痕 | window |
| `tern.css` | 窗口 | 注入用量线/卡片样式表 | window |
| `tern.chrome.status / refresh` | 窗口 | 状态栏今日段 | window |
| `tern.command` | 窗口 | 面板/设置/刷新/仪表盘/诊断命令 | window |
| `tern.context / plugin / runtime` | 双方 | 探针:确认运行半区与 kv 归属 | 两入口 |
| `tern.on` (window_start / focus / budget) | 窗口 | 生命周期事件 | window |
| `cx.session:focused / pane / panes` | 窗口 | 焦点判定、块扫描、主机映射 | window |
| `cx.session:surface` | 窗口 | 读 composer 树(模型芯片名) | window |
| `cx.session:read` | 窗口 | 读 sync 块文本(含远程主机) | window |
| `cx.session:block_types` | 窗口 | 开块前的目录门闸 | window |
| `cx.hosts:list / current` | 窗口 | 主机列表与 pane 归属 | window |
| `cx:new_block` | 窗口 | 在当前主机开 sync 块 | window |
| `cx.layout:park` | 窗口 | 把 sync 块驻流出标签栏 | window |
| `cx:toast / pick / prompt` | 窗口 | 设置菜单、提示 | window |
| `tern.block.define` | 宿主 | dashboard / sync 两个块 | host |
| `tern.pane.list` | 宿主 | sync 块存活检查 | host |
| `tern.ui.*` | 双方 | 块视图组件 | host |
| `cx:render` (BlockCx) | 宿主 | 块重绘 | host |

---

## 1. 数据与存储

### `tern.kv.get(key) / tern.kv.set(key, value)`

- **是什么**:插件数据目录下 `kv.json` 的持久键值存储。同一机器上,插件的 host 半和每个窗口的
  window 半共享同一份;**不跨主机同步**。
- **怎么用**:全部调用都包 `pcall`(写失败是静默的,pcall 至少让我们能兜底)。键见
  [IMPLEMENTATION.md](IMPLEMENTATION.md) §3。
- **用在哪**:`lib/fetch.luau`(usage/models/today/days/锁/trace)、`lib/settings.luau`(settings)、
  两入口(探针)。
- **坑**:
  - kv.json 是 JSON —— **Infinity/NaN 写不进去且静默失败**(我们因此丢过全部 usage 数据,
    现在窗口排序用 `MAX_MS = 1e15`);
  - 值会原样覆盖,写前读改(读-改-写)有竞态,靠 `fetch_lock`(4s 窗口)缓解;
  - 插件 id 改名 = 数据目录改名,历史数据要手工迁移。

### `tern.json.decode(text) / encode(value, pretty?)`

- **用在哪**:decode —— `fetch.run`(omp CLI 输出,先从第一个 `{` 截取,因为 omp 可能先打
  "Syncing session files..." 之类的进度行)、`window.decode_payload`(sync 块文本);
  encode —— sync 块载荷。
- **坑**:`omp models --json` 顶层是 `{models:[...]}` 对象而非数组;`stats --json` 同理是对象。

### `tern.getenv(name) / tern.fs.exists(path)`

- **用在哪**:`fetch.omp_bin()` —— 依次探测 `OMP_USAGE_PLUS_BIN` 环境变量 →
  `%LOCALAPPDATA%\Tern\omp\bin\omp.exe`(Tern 托管的 omp)→ macOS/Linux 托管路径 →
  `~/.local/bin/omp` → PATH 里的 `omp`。守护进程未必继承 shell 的 PATH,托管路径优先是关键。

### `tern.process.run(argv, {timeout_ms = ...}, callback(res, cx))`

- **是什么**:异步起进程;**spawn 失败会抛出**(用 pcall 包住),结果经回调送达
  (`res.status / res.stdout / res.stderr / res.timed_out`)。
- **用在哪**:`fetch.run`(usage / models / stats 三个轮询任务,超时 20s)、
  `fetch.maybe_fetch` 的手动刷新(`omp usage invalidate` 先行)、`host.luau` 的仪表盘
  (`omp usage --history --json --days 7`,超时 60s)。
- **坑**:定时器回调里**每次最多起 1 个进程**、回调本体 ≤50ms(宿主 2s),否则 Tern 停掉
  插件全部定时器直到 reload —— 所以取数是"串行队列 + 锁"(见 fetch.luau 的 `busy`/`pending`)。

### `tern.timer(ms, fn)`

- **是什么**:单次定时,回调可带 `cx`(窗口半可能为 nil);**循环必须回调里自己再注册**。
- **用在哪**:fetch 服务循环(host 5s)、sync 块自刷新(host 5s)、窗口 tick(1s)、
  watchdog(10s)、面板状态签名刷新等。
- **坑**:我们踩过"循环不自续,跑两次就死"的 bug;所有循环统一用
  `local function loop() ... tern.timer(ms, loop) end; tern.timer(ms, loop)` 形态。

## 2. 窗口渲染与状态栏

### `tern.css(sheet, css)`

- **是什么**:按名字注入/整表替换样式表;卸载插件即消失。我们的表名 `usage-plus`,
  实际级联名 `plugin:local:dora-tern-omp-usage:usage-plus`。
- **用在哪**:`window.install()` —— 每次"签名"(内容指纹)变化时整表重写线 + 卡片的全部 CSS。
- **坑**:不要高频重写(我们 1s tick 里做内容签名去重);表内容自包含,
  线的锚点是 `.tn-pane.on .sf-meter[data-role='omp.composer.context']`(::before/::after)+ 
  空附件行 `omp.composer.chips`(悬停目标),Tern 升级后先查这些选择器。

### `tern.chrome.status(fn) / tern.chrome.refresh()`

- **是什么**:注册状态栏段生成器,参数为聚焦窗格信息(`pane.kind` 等),返回
  `{ {text, icon?, tone?, command?} }` 或 nil;`refresh()` 主动要求重绘。
- **用在哪**:`window.luau` —— `🔥 tokens` / `💸 $` / `usage` 段(agent 窗格时)与陈旧 ⚠。
- **坑**:**格式化器预算 4ms,里面不能读 kv** —— 我们用 tick 缓存(`cached`)供它读取;
  数据变化后在 tick 里调 `tern.chrome.refresh()`。

### `tern.command{ id, title, icon, keys?, run }`

- **用在哪**:`panel`(Ctrl+Alt+U 设置菜单)、`settings`、`refresh`、`dashboard`、
  `diagnostics`。动作名(状态栏 `command` 字段)= `plugin.<插件id>.<命令id>`。

## 3. 会话、主机与块(多主机数据总线)

### `cx.session:focused() / :pane(id) / :panes()`

- **用在哪**:tick 里判定聚焦窗格是否 agent(`:focused()` + `:pane(id).kind == "agent"`);
  `:panes()` 扫描所有窗格找 sync 块(`info.block == "<id>.sync"`,还能看到 `info.parked`)。
- **坑**:`info.exited` 等字段只对 terminal/agent 类窗格存在,**插件块没有**——
  所以无法从窗格信息判断 sync 块是否已退出(只能靠 read 失败/文本推断)。

### `cx.session:surface(pane, { root = "dock" })`

- **是什么**:读窗格的 UI 树(节点 = `{id, p:{role, spans:[{t}]}, c:[children]}`)。
- **用在哪**:`read_dock` —— 从聚焦 omp 窗格的 composer 区取**模型芯片名**
  (role `omp.composer.model` 下 id 以 `/name` 结尾的节点),用于"当前模型 → 提供商"映射。
- **坑**:每秒调用,节点数 ~40,很轻;但务必 pcall(窗格消失时会失败)。

### `cx.session:read(pane, { max_chars = 8000 })`

- **是什么**:读窗格的"活模型"——对插件块返回 `{kind="plugin", title, text}`;
  **对远程主机的块同样有效**(这是跨主机数据总线的通道)。
- **用在哪**:`refresh_sync_data` —— 读取每台主机的 sync 块文本(一行 JSON),
  解码进 `host_data[主机名]`。
- **坑**:默认截断 8000 字符,所以 sync 载荷超限时先丢 models 目录(host 端保证 ≤7KB);
  文本若以 `usage-plus sync error:` 开头,说明远端块渲染出错,错误文本会被送进
  `host_data[主机].sync_error` 供卡片显示"数据不可用"。

### `cx.session:block_types()`

- **是什么**:当前主机上可打开的块类型目录(native + 各 Ready 插件)。
- **用在哪**:`ensure_sync_block` 的**门闸** —— 目录里出现 `"<id>.sync"` 之前绝不调
  `cx:new_block`,否则 Tern 会把 "no block type ... on this host" 打进窗格
  (启动竞态实测踩坑:远端主机的目录就绪晚于 window_start)。

### `cx.hosts:list() / :current()`

- **是什么**:`list()` 返回每台主机的 `ManagedHost`
  (`{name, kind:"local"|"remote", state, current, rtt_ms, sessions, panes...}`)。
- **用在哪**:`refresh_host_map` —— 由每台主机的 `panes` 数组建立 **pane id → 主机名** 映射
  (聚焦窗格属于哪台主机就看这张表),顺带记下本机名(`local_host_name`,卡片今日行的标签);
  `ensure_sync_block` 用 `:current().kind == "remote"` 判断是否需要开 sync 块。

### `cx:new_block(kind, args?, how?, opts?)` 与 `cx.layout:park(pane)`

- **是什么**:在窗口**当前主机**上开一个插件块(目录里没有该 kind 时返回 nil);
  `park` 把块从标签栏收进会话的驻留甲板(程序继续跑,`panes()`/`read` 仍可见)。
- **用在哪**:`ensure_sync_block` —— 当前主机是远程且无 sync 块时,
  `cx:new_block(..., "tab", {focus=false})` 后立即 `park`,用户看不到多余标签页。
- **坑**:
  - 开块前必须过 `block_types()` 门闸(见上);
  - 块面板没有编程式关闭 API —— 块若崩成 "exited",只能用户点 Restart/Close
    (所以 sync 块的 view 全程 pcall,出错把错误文本渲染成内容而不是退出);
  - 块面板会话存续期常驻,重装/卸载插件时会随 worker 退出而关闭。

## 4. 事件(window)

| 事件 | 用在哪 | 说明 |
|---|---|---|
| `window_start` | 启动后第一帧画线 | **会话落定后**(保存的标签恢复完)才触发;reload 不会重触发,所以加载期定时器仍保留 |
| `focus` | 立即重绘 | 切窗格/切标签时 |
| `budget` | 自愈 + 留痕 | `{hook, state:"paused"|"resumed", ms}` —— 钩子被预算暂停时记录日志,**恢复时立即 tick**(这正是"启动后必须切一下终端"问题的保险) |

## 5. 交互原语(window)

- **`cx:pick({items, placeholder, icon}):next(fn)`** —— 设置菜单(模式/提供商/配色/语言…);
  item 字段 `{label, detail?, group?, current?, pick=自定义动作, ...}`。
- **`cx:prompt({value, placeholder, icon}):next(fn)`** —— 自定义颜色、阈值、间隔的文本输入。
- **`cx:toast(level, title, sub?)`** —— success/info/error 提示(diagnostics、设置保存等)。
- **`tern.log.info(...)`** —— budget 事件留痕(默认日志级别下 info 被过滤,调 `STENCIL_LOG` 可见)。

## 6. 宿主半专用

### `tern.block.define(id, {init, title, view, key?})`

- **用在哪**:
  - **`sync` 块**:数据总线 —— `view` 把本机 kv(usage/today/models)编码成一行 JSON 文本
    (≤7KB,超限先丢 models 目录),init 里 5s 定时器驱动 `cx:render()`;
    view 全程 pcall,出错渲染错误文本而非退出;
  - **`dashboard` 块**:7 天历史 + 费用;`init` 拉取 `omp usage --history`,`key` 处理 `r` 刷新,
    存活检查用 `tern.pane.list()`(块面板没有 close 钩子,靠"窗格还在不在"判断)。
- **坑**:块视图里 `tern.json.encode` 若遇到不可序列化值会抛出并**终结块**
  (实测表现为 "Shell exited with 1" 对话框)—— 所以 encode 也在 pcall 里。

### `tern.pane.list()`(宿主)

- **用在哪**:sync 块的自检(自己的 `cx.pane` 是否还在列表里,不在就停表)。

### `tern.ui.*`(块视图)

- **用在哪**:sync 块 `ui.text(ui.span(payload))`;仪表盘
  `ui.col / ui.card / ui.meter / ui.spark / ui.kv / ui.bars / ui.progress / ui.text / ui.span`。

### `BlockCx`

- **用在哪**:`cx.pane`(块自己的窗格 id,存活检查用)、`cx:render()`(数据更新后重绘)。

## 7. omp CLI 数据源(非 Tern API,但同属"对外接口")

| 命令 | 用途 | 消费者 |
|---|---|---|
| `omp usage --json` | 各提供商限额(reports + capacity) | kv.usage → 线/卡片 |
| `omp usage invalidate` | 手动刷新前清 omp 缓存 | fetch(force 时) |
| `omp usage --history --json --days 7` | 逐小时限额快照 | 仪表盘 |
| `omp models --json` | 模型目录(芯片名→提供商、价格表) | kv.models |
| `omp stats --json` | timeSeries(今日)+ byModel(按提供商分解) | kv.today / by_provider_today |

**价格语义**:金额由 omp 按模型目录的 API 列表价(USD/百万 tokens,input/output/cacheRead/cacheWrite)
计算,是 **API 等效费用**,不是订阅扣费。

## 8. 调用纪律(总结)

1. 窗口半任何回调 ≤50ms,格式化器 ≤4ms,宿主 2s;**超限钩子被暂停**(budget 事件可见)。
2. 原生调用(cx API、kv、fs、起进程)不计入预算,但不要在格式化器里做。
3. 每回调最多起 1 个进程;轮询串行 + 锁。
4. 一切外部输入(omp JSON、sync 文本、kv)进渲染前先 type 检查;数值必须有限。
5. 循环定时器必须自续;window_start 只在会话落定时来一次。
