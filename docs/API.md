# Tern API 使用说明

本文整理了插件用到的全部 Tern API,逐条说明其用途、用法与注意事项,并标注所在文件,便于查阅与维护。
官方文档:<https://docs.stencil.so/tern/>(每页均提供 `.md` 版本);类型定义见仓库根目录的 `tern.d.luau`,
可用 `tern plugin types .` 重新生成。

---

## 0. 总览

| API | 半区 | 用途 | 使用位置 |
|---|---|---|---|
| `tern.kv.get / set` | 双方 | 持久化:数据缓存与设置 | fetch / settings / 两入口 |
| `tern.json.decode / encode` | 双方 | 解析 omp CLI 输出、sync 块载荷 | fetch / parse / line / window |
| `tern.timer(ms, fn)` | 双方 | 轮询与延迟(单次,循环须自续) | fetch / host / window |
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
| `cx:render`(BlockCx) | 宿主 | 块重绘 | host |

## 1. 数据与存储

### tern.kv.get / set

插件数据目录下 kv.json 的持久键值存储。同一台机器上,宿主半与各窗口的窗口半共享同一份数据;
**不同主机之间互不同步**。

所有调用均以 `pcall` 包裹——写入失败是静默的,pcall 至少保证调用方不被中断。各键的用途见
[实现指南](IMPLEMENTATION.md)第 3 节。

注意事项:

- kv.json 是 JSON,**Infinity / NaN 无法写入且失败不报错**。窗口排序因此改用 `MAX_MS = 1e15`
  代替 `math.huge`(曾因这个问题丢失全部用量数据);
- 读-改-写存在竞态,取数环节以 `fetch_lock`(4 秒窗口)与串行队列缓解;
- 插件 id 改名时数据目录随之改名,历史数据需要手工迁移。

### tern.json.decode / encode

decode 用于两处:解析 omp CLI 的输出(先从第一个 `{` 截取——omp 可能在 JSON 之前打印
"Syncing session files..." 之类的进度行),以及解析 sync 块的 JSON 载荷。encode 用于宿主半
生成 sync 块载荷。

注意 `omp models --json` 与 `omp stats --json` 的顶层是对象(如 `{models:[...]}`),不是裸数组。

### tern.getenv / tern.fs.exists

用于定位 omp 可执行文件,顺序为:`OMP_USAGE_PLUS_BIN` 环境变量 → Tern 托管路径
(Windows 的 `%LOCALAPPDATA%\Tern\omp\bin\omp.exe` 及 macOS / Linux 对应位置)→
`~/.local/bin/omp` → PATH 中的 `omp`。守护进程未必继承 shell 的 PATH,托管路径优先是关键。

### tern.process.run

异步执行外部命令,spawn 失败会直接抛出(需 pcall),结果经回调送达
(`status / stdout / stderr / timed_out`)。

用于三处:轮询任务中的 `omp usage / models / stats`(超时 20 秒)、手动刷新前的
`omp usage invalidate`、仪表盘的 `omp usage --history`(超时 60 秒)。

注意:定时器回调中每次至多启动一个进程,回调本体须控制在预算内,否则 Tern 会停用插件的
全部定时器——因此取数实现了串行队列与锁。

### tern.timer

单次定时器,循环必须在回调中重新注册。插件的全部轮询(fetch 服务 5s、sync 块自刷新 5s、
窗口 tick 1s、watchdog 10s)均基于它。

## 2. 窗口渲染与状态栏

### tern.css(sheet, css)

按名字注入或整表替换样式表,插件卸载即随之消失。本插件只用一张表 `usage-plus`,在内容签名
变化时整表重写,内含用量线与悬浮卡片的全部样式。

关键锚点集中在 `line.luau` 顶部:线的本体是聚焦窗格上下文计量器
(`.sf-meter[data-role='omp.composer.context']`)的 `::before`,悬停目标是空附件行
(`omp.composer.chips`)。Tern 升级后线条消失,先检查这些选择器。

### tern.chrome.status / refresh

注册状态栏段的生成函数,入参是聚焦窗格信息(含 `kind`),返回段数组(每段 `text / icon / tone /
command`)或 nil。插件用它展示当日 token 与费用,并在 agent 窗格聚焦时提供 `usage` 入口。

注意:**格式化器的预算只有 4ms**,不能在其中读取 kv——状态栏读取的是 tick 阶段准备好的缓存,
数据变化后在 tick 里调用 `refresh()` 请求重绘。

### tern.command

声明命令:`panel`(Ctrl+Alt+U 设置菜单)、`settings`、`refresh`、`dashboard`、`diagnostics`。
状态栏段的 `command` 字段引用命令时,动作名为 `plugin.<插件id>.<命令id>`。

## 3. 会话、主机与块

### cx.session:focused / pane / panes

`focused()` 取焦点窗格,`:pane(id)` 取窗格信息(`kind == "agent"` 判定 agent 窗格),
`panes()` 枚举窗口内全部窗格——插件借此扫描 sync 块(`info.block == "<id>.sync"`,
另可读 `info.parked` 判断是否已驻留)。

注意:`exited` 等字段只存在于 terminal / agent 类窗格,**插件块没有**,因此无法从窗格信息
直接判断 sync 块是否已退出。

### cx.session:surface(pane, { root = "dock" })

读取窗格的 UI 树(节点结构为 `{id, p:{role, spans:[{t}]}, c:[...]}`)。插件用它从聚焦 omp
窗格的 composer 区提取**模型芯片名**(role `omp.composer.model` 下 id 以 `/name` 结尾的节点),
作为"当前模型 → 提供商"映射的输入。每秒一次、每次约 40 个节点,开销很小;调用务必 pcall。

### cx.session:read(pane, { max_chars })

读取窗格的当前内容:对插件块返回 `{kind = "plugin", title, text}`。**对远程主机的块同样有效**,
这是跨主机数据总线的通道——插件借此读取每台主机的 sync 块文本(一行 JSON)。

注意:默认截断 8000 字符,因此宿主端保证载荷不超过 7KB(超限先丢弃 models 目录);若文本以
`usage-plus sync error:` 开头,说明远端块渲染出错,错误文本会被写入
`host_data[主机].sync_error`,卡片据此显示"数据不可用"。

### cx.session:block_types()

返回当前主机上可打开的块类型目录。`ensure_sync_block` 以此为门闸:目录中出现 `<id>.sync`
之前绝不调用 `cx:new_block`,否则 Tern 会把 "no block type ... on this host" 打进窗格
(启动时远端主机的目录就绪晚于 window_start,实测踩过)。

### cx.hosts:list / current

`list()` 返回每台主机的信息(`name、kind:"local"|"remote"、state、current、rtt_ms、
sessions、panes`)。插件用它建立 **pane id → 主机名** 的映射(聚焦窗格属于哪台主机即由此
判定),同时记录本机名作为卡片今日行的标签;`current()` 用于判断是否需要为远程主机开启
sync 块。

### cx:new_block / cx.layout:park

`new_block(kind, args?, how?, opts?)` 在窗口的**当前主机**上打开一个插件块,目录中没有该类型
时返回 nil;`park(pane)` 将块从标签栏收进会话的驻留甲板——程序继续运行,`panes()` 与
`read` 仍可访问。

插件在当前主机为远程且尚无 sync 块时,开块并立即驻留,用户不会看到多余的标签页。两个注意点:
开块前必须过 `block_types()` 门闸;块没有编程式关闭的 API,一旦崩成 exited 只能由用户
Restart / Close(因此 sync 块的 view 全程 pcall,出错时把错误文本渲染成内容而不是退出)。

## 4. 事件

| 事件 | 用途 | 说明 |
|---|---|---|
| `window_start` | 首帧绘制 | 每窗口一次,时机在会话落定(保存的标签页恢复完毕)之后;reload 不会重新触发 |
| `focus` | 立即重绘 | 切换窗格或标签时触发 |
| `budget` | 自愈与留痕 | 钩子被预算暂停/恢复时触发;恢复时立即 tick,并写入日志 |

## 5. 交互

- **cx:pick({items, placeholder, icon})** —— 设置菜单(显示模式、提供商、配色、语言等),
  item 字段为 `{label, detail?, group?, current?, pick = 自定义动作, ...}`;
- **cx:prompt({value, placeholder, icon})** —— 自定义颜色、阈值、刷新间隔的文本输入;
- **cx:toast(level, title, sub?)** —— success / info / error 提示(诊断、设置保存等);
- **tern.log.info** —— budget 事件留痕(默认日志级别会过滤 info,需设置 `STENCIL_LOG` 才可见)。

## 6. 宿主半

### tern.block.define(id, {init, title, view, key?})

声明块类型,插件定义了两个:

- **sync**(数据总线):view 将本机 kv(usage / today / models)编码为一行 JSON 文本
  (上限 7KB,超限先丢弃 models 目录),init 中 5 秒定时器驱动 `cx:render()`。
  view 全程 pcall——出错时渲染错误文本,而不是让块退出;
- **dashboard**(仪表盘):init 拉取 `omp usage --history`,`key` 处理 `r` 刷新。
  块没有 close 钩子,存活检查依靠 `tern.pane.list()` 中自身窗格是否仍在。

### 其他

- **tern.pane.list**(宿主)—— 枚举本机窗格,用于 sync 块的存活检查;
- **tern.ui.\*** —— 块视图组件:sync 块用 `ui.text(ui.span(payload))`,仪表盘用
  `ui.col / ui.card / ui.meter / ui.spark / ui.kv / ui.bars / ui.progress`;
- **BlockCx** —— `cx.pane` 为块自身的窗格 id(存活检查用),`cx:render()` 在数据更新后重绘。

### tern.json.encode 的教训

视图中的 encode 全程 pcall:一旦遇到不可序列化的值(如 Infinity),异常会**终结整个块**,
实测表现就是 "Shell exited with 1" 对话框。这是 sync 块渲染全部包 pcall 的原因。

## 7. omp CLI 数据源

严格说这不是 Tern API,但属于插件的对外接口,一并记录:

| 命令 | 用途 | 消费者 |
|---|---|---|
| `omp usage --json` | 各提供商限额(reports + capacity) | kv.usage → 线/卡片 |
| `omp usage invalidate` | 手动刷新前清除 omp 缓存 | fetch(force 时) |
| `omp usage --history --json --days 7` | 逐小时限额快照 | 仪表盘 |
| `omp models --json` | 模型目录(芯片名→提供商、价格表) | kv.models |
| `omp stats --json` | timeSeries(当日)+ byModel(按提供商分解) | kv.today / by_provider_today |

**价格语义**:金额由 omp 按模型目录中的 API 列表价(USD / 百万 tokens,分 input、output、
cacheRead、cacheWrite 四项)计算,是 **API 等效费用**——即"这些用量若按 API 直连计费的花费",
并非订阅账单。插件自身不发起任何网络请求。

## 8. 调用纪律

1. 窗口半普通回调 ≤50ms,格式化器 ≤4ms,宿主半 ≤2s;**超限钩子会被暂停**(budget 事件可见);
2. 原生调用(cx API、kv、fs、起进程)不计入预算,但格式化器中仍应避免;
3. 每个回调至多启动一个进程,轮询串行执行并加锁;
4. 一切外部输入(omp JSON、sync 文本、kv)进入渲染前逐字段做类型检查,数值必须有限;
5. 循环定时器必须自续;window_start 在会话落定时仅触发一次。
