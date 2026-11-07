# Tern API 使用说明

本文整理了插件用到的全部 Tern API,逐条说明其用途、用法与注意事项,并标注所在文件,便于查阅与维护。

先解释一个贯穿全文的术语。官方文档把插件的结构称为 **halves**(部分):一个插件至多由两部分组成——
**宿主端(host half,入口 `host.luau`)**运行在会话守护进程,负责与窗格相关的一切(取数、仪表盘);
**窗口端(window half,入口 `window.luau`)**运行在每个 Tern 窗口的 UI 线程,负责界面行为(画线、
状态栏、设置菜单)。下表"运行位置"一列即指这两者。

官方文档:<https://docs.stencil.so/tern/>(每页均提供 `.md` 版本);类型定义见仓库根目录的 `tern.d.luau`,
可用 `tern plugin types .` 重新生成。

---

## 0. 总览

| API | 运行位置 | 用途 | 使用位置 |
|---|---|---|---|
| `tern.kv.get / set` | 双方 | 持久化:各源数据缓存与设置 | fetch / settings / 两入口 |
| `tern.json.decode / encode` | 双方 | 解析 omp CLI 输出 | fetch / parse / host |
| `tern.timer(ms, fn)` | 双方 | 轮询与延迟(单次,循环须自续) | fetch / host / window |
| `tern.process.run` | 双方 | 运行 omp CLI(本机 / wsl.exe 穿透 / ssh 穿透) | fetch / host(仪表盘) |
| `tern.getenv` | 双方 | 定位 omp 可执行文件 | fetch.omp_bin |
| `tern.fs.exists / read` | 双方 | omp 路径探测 / 诊断读 kv 体积 | fetch / window(诊断) |
| `tern.log.info` | 窗口 | budget 暂停/恢复留痕 | window |
| `tern.css` | 窗口 | 注入用量线/卡片样式表 | window |
| `tern.chrome.status / refresh` | 窗口 | 状态栏今日段 | window |
| `tern.command` | 窗口 | 面板/设置/刷新/仪表盘/诊断命令 | window |
| `tern.runtime.os` | 双方 | 判定平台(仅 Windows 检测 WSL) | fetch |
| `tern.on`(window_start / focus / budget) | 窗口 | 生命周期事件 | window |
| `cx.session:focused / pane / panes` | 窗口 | 焦点判定、composer 树读取 | window |
| `cx.session:surface` | 窗口 | 读 composer 芯片、子代理 focus 与隐藏身份节点 | window |
| `cx.session:block_types` | 窗口 | 开仪表盘块前的目录门闸 | window |
| `cx.hosts:list / current` | 窗口 | 主机列表、pane 归属与远程主机上报 | window |
| `cx:new_block` | 窗口 | 打开仪表盘块 | window |
| `cx:toast / pick / prompt` | 窗口 | 设置菜单、提示 | window |
| `tern.block.define` | 宿主 | dashboard 仪表盘块 | host |
| `tern.pane.list` | 宿主 | 块存活检查 | host |
| `tern.ui.*` | 双方 | 块视图组件 | host |
| `cx:render`(BlockCx) | 宿主 | 块重绘 | host |

## 1. 数据与存储

### tern.kv.get / set

插件数据目录下 kv.json 的持久键值存储。同一台机器上,宿主端与各窗口的窗口端共享同一份数据;
**不同主机之间互不同步**。

所有调用均以 `pcall` 包裹——写入失败是静默的,pcall 至少保证调用方不被中断。各键的用途见
[实现指南](IMPLEMENTATION.md)第 3 节:数据按源分键(`usage@local`、`usage@wsl:<发行版>`、
`usage@ssh:<主机名>` 等),另有设置、锁、trace 等。

2.0.0 的 `fetch.kv_get` 只接受 `usage/models/today@<source>` 的 v2 记录,读取时即排除旧小写化身份缓存。供应商基线与账本以 v2 包装并成对重建,每日总量历史不变;具体结构见实现指南。


注意事项:

- kv.json 是 JSON,**Infinity / NaN 无法写入且失败不报错**。窗口排序因此改用 `MAX_MS = 1e15`
  代替 `math.huge`(曾因这个问题丢失全部用量数据);
- 读-改-写存在竞态,取数环节以每源锁(4 秒窗口)与串行队列缓解;
- 插件 id 改名时数据目录随之改名,历史数据需要手工迁移。

### tern.json.decode / encode

decode 用于解析 omp CLI 的输出——注意 omp 可能在 JSON 之前打印进度行
("Syncing session files..."),解析前从第一个 `{` 截取;另外 `omp models --json` 与
`omp stats --json` 的顶层是对象(如 `{models:[...]}`),不是裸数组。

### tern.getenv / tern.fs.exists / tern.fs.read

`getenv` 与 `fs.exists` 用于定位 omp 可执行文件,顺序为:`OMP_USAGE_PLUS_BIN` 环境变量 →
Tern 托管路径(Windows 的 `%LOCALAPPDATA%\Tern\omp\bin\omp.exe` 及 macOS / Linux 对应位置)→
`~/.local/bin/omp` → PATH 中的 `omp`。守护进程未必继承 shell 的 PATH,托管路径优先是关键。
`fs.read` 用于诊断命令读取 kv.json 的体积。

### tern.process.run

异步执行外部命令,spawn 失败会直接抛出(需 pcall),结果经回调送达
(`status / stdout / stderr / timed_out`)。

用于:各数据源的 `omp usage / models / stats`(超时 20 秒)、手动刷新前的
`omp usage invalidate`、仪表盘的 `omp usage --history`(超时 60 秒)、WSL 发行版检测
(`wsl.exe -l -q`)。

注意:定时器回调中**每个数据源至多启动一个进程**,回调本体须控制在预算内,否则 Tern 会停用
插件的全部定时器——因此取数实现了按源串行队列与锁。

### tern.timer

单次定时器,循环必须在回调中重新注册。宿主每 250ms 接收切换刷新请求,常规任务每 5s 检查;
窗口 tick 为 100ms,数据快照为 1s,watchdog 为 10s。`tern.now()` 的单调毫秒时钟用于快照与常规任务节流。

## 2. 窗口渲染与状态栏

### tern.css(sheet, css)

按名字注入或整表替换样式表,插件卸载即随之消失。本插件只用一张表 `usage-plus`,在内容签名
变化时整表重写,内含用量线与悬浮卡片的全部样式。

关键锚点集中在 `line.luau` 顶部:线的本体是聚焦窗格上下文计量器
(`.sf-meter[data-role='omp.composer.context']`)的 `::before`,悬停目标是空附件行
(`omp.composer.chips`)。Tern 升级后线条消失,先检查这些选择器。

### tern.chrome.status / refresh

注册状态栏段的生成函数,入参是聚焦窗格信息(含 `kind`),返回段数组(每段 `text / icon / tone /
command`)或 nil。插件用它展示焦点窗格所属主机的当日 token 与费用,并在 agent 窗格聚焦时提供
`usage` 入口。

注意:**格式化器的预算只有 4ms**,不能在其中读取 kv——状态栏读取的是 tick 阶段准备好的缓存
(`cached.by_source`),数据变化后在 tick 里调用 `refresh()` 请求重绘。

### tern.command

声明命令:`panel`(Ctrl+Alt+U 设置菜单)、`settings`、`refresh`、`dashboard`、`diagnostics`。
状态栏段的 `command` 字段引用命令时,动作名为 `plugin.<插件id>.<命令id>`。

## 3. 会话、主机与多数据源

### cx.session:focused / pane / panes

`focused()` 取焦点窗格,`:pane(id)` 取窗格信息(`kind == "agent"` 判定 agent 窗格)。
`panes()` 枚举窗口内全部窗格。

### cx.session:surface(pane, { root = "dock" })

读取窗格 UI 树(节点结构为 `{id, p:{role, spans:[{t}]}, c:[...]}`),每约 100ms 读取 dock,调用务必 pcall。`lib/identity.luau` 提取模型芯片、子代理 focus 与隐藏 role `dora.omp.model-identity`。桥 JSON v1 包含 `sessionId, scope: main, provider, id`;重复/截断/非法/不支持节点不能降级为缺桥。

有效主桥确定当前 provider/id;子代理不继承。仅缺桥或有效主桥下查看子代理时,才可使用目录 v2 的精确显示名候选;无 first-hit、模糊/id 子串或启发。主会话跨提供商多候选全部显示并标注,不猜一家;同一提供商多候选、全部无数据、非法/不支持桥或查看子代理时显示待确认及悬停帮助。诊断共享解析结果。

桥由仓库 `omp/extensions/model-identity.js` 提供,要求 omp ≥ 18.18.0,通过 `belowEditor` 隐藏原生 widget 和实时 `ctx.models.current()` getter,不依赖公开模型变更事件、不轮询、不写文件。需在每个 omp 主机显式加载,Windows/WSL/SSH 绝对路径示例见 README。

### cx.session:block_types()

返回当前主机上可打开的块类型目录(原生 + 各 Ready 插件)。打开仪表盘块之前以此做门闸:
目录中出现目标类型之前绝不调用 `cx:new_block`,否则 Tern 会把
"no block type ... on this host" 直接打印到窗格里(启动竞态实测踩过)。

### cx.hosts:list / current

`list()` 返回每台主机的信息(`name、kind:"local"|"remote"、state、current、rtt_ms、
sessions、panes`)。插件用它完成三件事:

1. 建立 **pane id → 主机名** 的映射(每台主机的 `panes` 数组)——聚焦窗格属于哪台主机由此判定;
2. 记录本机的显示名(卡片今日行的标签);
3. 把**已连接的远程主机**列表上报到 kv(`remote_hosts`),供宿主端的取数服务为每台主机
   建立数据源(WSL 主机走 wsl.exe 穿透,ssh 主机走 ssh)。

### cx:new_block(kind, args?, how?, opts?)

在窗口的**当前主机**上打开一个插件块,目录中没有该类型时返回 nil(不弹错,由调用方决定)。
插件用它打开仪表盘块;开块前配合 `block_types()` 门闸使用,避免启动竞态。

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

## 6. 宿主端

### tern.block.define(id, {init, title, view, key?})

声明块类型,插件定义了 **dashboard**(仪表盘):init 拉取 `omp usage --history`,
`key` 处理 `r` 刷新。块没有 close 钩子,存活检查依靠 `tern.pane.list()` 中自身窗格是否仍在。

### 其他

- **tern.pane.list**(宿主)—— 枚举本机窗格,用于块的存活检查;
- **tern.ui.\*** —— 块视图组件:`ui.col / ui.card / ui.meter / ui.spark / ui.kv / ui.bars /
  ui.progress / ui.text / ui.span`;
- **BlockCx** —— `cx.pane` 为块自身的窗格 id(存活检查用),`cx:render()` 在数据更新后重绘。

## 7. omp CLI 数据源

严格说这不是 Tern API,但属于插件的对外接口,一并记录:

| 命令 | 用途 | 消费者 |
|---|---|---|
| `omp usage --json` | 各提供商限额(reports + capacity) | `usage@<源>` → 线/卡片 |
| `omp usage invalidate` | 手动刷新前清除 omp 缓存 | fetch(force 时) |
| `omp usage --history --json --days 7` | 逐小时限额快照 | 仪表盘 |
| `omp models --json` | 模型目录(v2 候选列表、selector/提供商索引、价格表) | `models@<源>` |
| `omp stats --json` | timeSeries(当日)+ byModel(按提供商分解) | `today@<源>` / 账本 |

**远程执行方式**:本机源直接运行;WSL 源经 `wsl.exe -d <发行版> -- sh -lc 'omp …'` 穿透;
ssh 源经 `ssh <主机名> "sh -lc 'omp …'"` 穿透。三种方式的输出格式完全一致,解析层无感知。

**价格语义**:金额由 omp 按模型目录中的 API 列表价(USD / 百万 tokens,分 input、output、
cacheRead、cacheWrite 四项)计算,是 **API 等效费用**——即"这些用量若按 API 直连计费的花费",
并非订阅账单。插件自身不发起任何网络请求。

## 8. 调用纪律

1. 窗口端普通回调 ≤50ms,格式化器 ≤4ms,宿主端 ≤2s;**超限钩子会被暂停**(budget 事件可见);
2. 原生调用(cx API、kv、fs、起进程)不计入预算,但格式化器中仍应避免;
3. 每个回调每源至多启动一个进程,轮询串行执行并加锁;
4. 一切外部输入(omp JSON、kv)进入渲染前逐字段做类型检查,数值必须有限;
5. 循环定时器必须自续;window_start 在会话落定时仅触发一次。
