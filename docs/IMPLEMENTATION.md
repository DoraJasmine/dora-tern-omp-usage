# 实现文档(维护者指南)

面向后续维护者:代码怎么组织、数据怎么流动、**常见的修改去哪里改**、有哪些坑。
设计背景见 [REQUIREMENTS.md](REQUIREMENTS.md) 与 [ARCHITECTURE.md](ARCHITECTURE.md);本文只讲实现。

---

## 1. 文件地图

```
plugin.toml          清单:id=dora-tern-omp-usage、host/window 入口、两个 block 声明(dashboard/sync)
host.luau            宿主半(守护进程线程):
                       ├ fetch.service() 循环(每 5s,lib/fetch)
                       ├ sync 数据块(本机 kv → 一行 JSON 文本,5s 自刷新)
                       └ dashboard 仪表盘块(omp usage --history + kv.days 费用)
window.luau          窗口半(每个窗口的 UI 线程):
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
docs/                需求 / 架构 / 本文档
```

**改东西去哪**(速查):

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

## 2. 两条运行时与生命周期

- **host 半**跑在会话守护进程(或无守护进程窗口)的工作线程,**每次调用预算 2 秒**;window 半跑在每个窗口
  的 UI 线程,**普通回调 50ms、chrome 格式化器 4ms**。超预算 → Tern **暂停该钩子**(5s 起指数退避)——
  我们订阅了 `budget` 事件:暂停写日志、恢复时立即重绘。
- **window_start**:每窗口一次,在会话落定(保存的标签页恢复完)之后触发 —— 启动画线的正确位置。
  注意 **reload 不会重新触发 window_start**(joaodutra88 的注释也强调过),所以加载期定时器仍要保留。
- 两半通过 **tern.kv**(同一份数据目录的 kv.json)共享数据;`tern.kv.set` 是"临时文件+rename"原子写,
  并发写"最后者胜"——所以取数有 4s 锁(`fetch_lock`)+ 串行队列(`busy`/`pending`)。

## 3. 数据流水线

```
host 半(每台机器)                          window 半(每个窗口)
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

## 4. 渲染层原理(line.luau)

- 线 = 聚焦 omp 窗格 composer 上下文计量器(`.sf-meter[data-role='omp.composer.context']`)的
  `::before` 的 **content 文本**;一条 `background-clip: text` 的**静态**渐变按字符区间着色并填充
  计量条(`━`×8,每字符 0.6em)。**条的位置按字符数计算,所以线里不能放中文**——CJK 字宽 ≈2×,
  会把填充和彗尾全挤歪;中文只出现在卡片里。
- 悬停目标 = composer 的空附件行(`omp.composer.chips`,平时隐藏);卡片是它的 `::after`,
  基础态 `visibility:hidden` + 0.5s 过渡延迟 → **移开后 0.5s 内移回卡片不消失**;卡片自身
  `pointer-events:auto`(悬停伪元素维持宿主的 `:hover`)。
- 所有 CSS 每次签名变化整表重写(`tern.css("usage-plus", css)`)——简单、无状态残留;Tern 的
  级联里 sheet 名为 `plugin:local:dora-tern-omp-usage:usage-plus`。
- **锚点选择器集中在 line.luau 顶部**(`METER`/`HOST_BASE`)。Tern 升级后线条消失,先查这里:
  用诊断命令确认树能读到,再 dump 表面对照新 DOM 调选择器。

## 5. 常见坑(都踩过)

1. **kv 写静默失败**:kv.json 是 JSON,**Infinity 写不进去** → 所有数值必须有限(窗口排序用
   `MAX_MS=1e15` 代替 math.huge)。写失败无报错,表现为"数据不更新"。
2. **定时器不自续**:`tern.timer` 是单次;循环必须"回调里再注册自己"。漏了就是"跑两次就死"。
3. **格式化器(/**`chrome.status` 回调)里不要读 kv**:预算 4ms,kv 读取 ~4ms —— 用 tick 缓存。
4. **每回调最多起 1 个进程**、回调本体 ≤50ms,否则 Tern 停掉插件全部定时器(直到 reload)。
5. **`omp stats --json` 的 stdout 前面有杂质**("Syncing session files..."):从第一个 `{` 截取再解码。
6. **`omp models --json` 顶层是 `{models:[...]}`** 不是裸数组。
7. **Kimi 报告重复窗口**:`limit_7d` 与 `7d` 数值有舍入差(0.0275 vs 0.030),去重规则是
   "key 以 `limit_` 开头 && 与已知窗口 resetAt 相差 <2min && 用量差 <5 个百分点"。
8. **Infinity 之外**:capacity 的窗口名可能是标签("7 Day")而非 id —— parse 里只接受白名单键。
9. **多主机**:kv 不跨机器同步;远程数据靠 sync 块(`cx.session:read` 可读远程块文本)。
   插件 id 改名 = kv 数据目录改名,**要手工迁移 kv.json**,且 `.path` 链接文件按 id 命名。

## 6. 调试

- **Diagnostics 命令**(命令面板):显示焦点主机、sync 块列表、三类数据的年龄、芯片名与映射到的提供商。
- **kv 直查**:上面的路径;`trace` 键保留最近 20 条取数事件(spawned/callback/handler_error)。
- **日志**:`%LOCALAPPDATA%\Tern\Logs\tern.log`(WSL:`~/.local/state/tern/...`? 不,
  WSL 日志在其运行目录的 Logs 下);预算暂停会有 `tern: <hook> exceeded <n> ms`。
- **无头调试**(zh-cn 插件作者的方法):`tern serve --control /tmp/tern.sock` +
  `tern ctl --control /tmp/tern.sock tree` dump DOM 调 CSS 选择器。

## 7. 发布

1. 改 `plugin.toml` 的 `version`
2. `git commit` + `git tag v0.x.y` + `git push --tags`
3. 用户更新:`tern plugin install github.com/DoraJasmine/dora-tern-omp-usage --force`
   (可选 TODO:GitHub Releases 检查 + 状态栏 ⬆ 一键更新,joaodutra88 的 update.luau 是现成范式)
