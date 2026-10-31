# Dora omp Usage — 架构文档

版本:v0.9(草案) · 日期:2026-10-31
配套文档:[REQUIREMENTS.md](./REQUIREMENTS.md)

参考项目(致谢其探索):
- [jmazzola/tern-plugin-omp-usage](https://github.com/jmazzola/tern-plugin-omp-usage) — 用量线 UI 与设置面板的参考(MIT)
- [joaodutra88/tern-omp-usage](https://github.com/joaodutra88/tern-omp-usage) — 纯插件架构、今日统计、仪表盘、i18n 的参考(MIT)

---

## 1. 设计原则

1. **纯 Tern 插件,零 omp 配置** —— 与 jmazzola 架构的根本分歧。omp 扩展需要手改 `config.yml`、配 `showHookStatus`、重启会话,是安装失败的主要来源(本机实测即因路径拼接出错而失败)。改由 host 半直接轮询 omp CLI,牺牲"会话内 ctx.models 精确映射",换来一行安装。
2. **host 生产,window 消费** —— 数据采集全部在 host 半(守护进程,常驻、跨窗口唯一),写入 `tern.kv`;window 半只读 kv + 读 UI 树 + 渲染。多窗口零重复轮询。
3. **提供商无关** —— 不白名单任何提供商;一切窗口/标签/颜色从报告数据推导,新提供商零代码接入。Kimi/Codex 的特殊形态(重复窗口、capacity 聚合)走归一化规则而非特判分支。
4. **渲染走 CSS,数据走文本** —— 沿用 jmazzola 验证过的方案:用量线是上下文计量器元素的 `::before` 的 `content` 文本,配色/动画全在 CSS;不触碰 omp 自身 DOM 结构,只在既有的稳定 role/id 上锚定。
5. **降级优先于报错** —— 任何数据缺失都表现为"少显示一项",永不弹错误刷屏;选择器锚点缺失时整体静默关闭线渲染。

## 2. 总体架构

```
┌────────────────────────────── Tern ──────────────────────────────┐
│                                                                  │
│  Host 半(守护进程,唯一)              Window 半(每窗口一个)      │
│  ┌─────────────────────────┐          ┌─────────────────────────┐ │
│  │ poller.luau             │          │ watcher.luau            │ │
│  │  ├ usage: omp usage     │  tern.kv │  ├ 1s: 聚焦窗格 & composer│ │
│  │  │        --json (90s)  │ ────────▶│  │   树 → 模型芯片名     │ │
│  │  ├ models: omp models   │ (usage/  │  ├ build: 组装 Line 模型 │ │
│  │  │        --json (10m)  │  models/ │  ├ render: tern.css 注入 │ │
│  │  └ stats: omp stats     │  today/  │  │   线 + 悬停卡片        │ │
│  │       --json (5m)       │  days)   │  ├ chrome.status 今日段  │ │
│  │ dashboard block         │          │  ├ settings 面板(canvas)│ │
│  │ (omp usage --history)   │          │  └ palette 菜单/命令      │ │
│  └─────────────────────────┘          └─────────────────────────┘ │
│                                       │ CSS sheet: usage/panel   │
└───────────────────────────────────────┼──────────────────────────┘
                                        ▼
                         聚焦 omp 窗格的 composer 树
                  .sf-meter[data-role='omp.composer.context']
                        └─ ::before{content:"用量线"}
                        └─ 悬停卡片(同级注入节点)
```

## 3. 关键决策记录(ADR)

### D1 数据获取:host 半轮询 omp CLI,不用 omp 扩展

| | 方案 A:omp 扩展(jmazzola) | **方案 B:host 轮询(采纳)** |
|---|---|---|
| 安装 | clone + link + 改 config.yml + statusLine 配置 + 重启 | 一行 install |
| 数据新鲜度 | 会话内 60s,turn_end 即刷 | 90s + 模型切换即刷(主动 fetch) |
| 模型映射 | 会话内 `ctx.models.list()` 精确 | `omp models --json` 目录 + 启发回退(R3) |
| 副作用 | 每会话一个常驻 JS、写状态事实 | 每 90s 一个短进程(~0.6s,NFR-3) |
| 与 omp 耦合 | setStatus 事实 id 前缀会变(`k.`/`3.`) | 只依赖 CLI 输出 schema,比内部事实 id 稳 |

采纳 B。理由:用户的首要痛点是安装;模型映射的精度损失有回退链兜底(FR-4.2)。

### D2 当前提供商识别:composer UI 树 + models 目录

jmazzola 证明:模型芯片文本节点(id 以 `/name` 结尾,role `omp.composer.model`)在 0.8.0 可从 `cx.session:surface(pane, { root = "dock" })` 读到。本插件:
1. 每 1 s 读聚焦窗格 dock 树(~40 节点,轻量),提取芯片名与 focus 行(子代理查看)。
2. 芯片名 → 提供商:host 半维护的目录表(kv `models`,来自 `omp models --json`,字段 `name`/`id`/`selector`/`provider`)。
3. 匹配顺序:目录 `name` 精确 → 目录 `id`/`selector` 含芯片名 → 内置前缀启发(`opus|sonnet|haiku`→anthropic,`gpt|codex`→openai-codex,`kimi|k2|k3`→kimi-code,`gemini`→google-gemini-cli)→ 放弃,回退"显示全部提供商"。

### D3 用量线渲染:CSS 伪元素文本(沿用 jmazzola 技术)

- 锚点:`.tn-pane.on .sf-meter[data-role='omp.composer.context']`(聚焦窗格的上下文发丝线计量器)。
- 线 = 该元素 `::before` 的 `content`:13px 等宽盒,`<提供商> <窗口标签> <━条×8> <N%> <倒计时>` 文本;条形用 `━` 字形(等宽 0.6em),整条一个 `background-clip: text` 静态渐变,每段颜色由字符区间着色(Tern 每元素只画一层渐变且不随位移动画,故内容静止时零重绘)。
- 悬停目标:composer 附件 chips 行(`.sf-row[data-role='omp.composer.chips']:is(.sf-hidden,.sf-void)`)——平时隐藏、无 title、是 meter 的兄弟节点,恰好做悬浮层;有附件显示时线保持但取消悬停反应。
- 卡片:悬停 ~400 ms 后由 CSS(兄弟选择器 + 定位)在上方展开玻璃拟态卡片;内容按数据逐行生成,同样走 `content`/DOM 注入。
- 隐藏策略:**无需隐藏任何东西**。jmazzola 需要隐藏 omp 状态栏里的 usage 事实,因为它的数据经过状态栏;我们不经过,状态栏原样保留。

### D4 今日统计:stats 轮询 + kv 逐日累积(沿用 joaodutra88 方案)

- `omp stats --json` → `timeSeries[]`(bucket 含 `timestamp`/`tokens`/`cost`)→ 累计 `≥ 当地零点` 的和。
- 逐日 totals 写 kv `days`(`YYYY-MM-DD → {tokens, cost}`,保留 62 天)——stats 只能回溯 ~1 天,周/月统计靠自存。
- 状态栏:`tern.chrome.status` 注册,agent 窗格聚焦时返回 `🔥 N tokens`、`💰 $N` 两段,`command` 指向打开仪表盘的隐藏命令。

### D5 设置:canvas 面板 + kv,双入口

- 面板:`cx.canvas:open({view, dock, how="beside"})`,`tern.ui` 节点搭建(分段/开关/按钮/色点/预览线);交互经 `tern.on("canvas_action")` 回调(`mode/toggle/up/down/top/bottom/named/preset/custom/reset`)。
- 菜单:`cx:pick` 多级列表(等价功能,纯键盘);`tern.command` 注册面板/菜单命令,面板命令带默认键位 `ctrl+alt+u`。
- 存取:唯一入口 settings 模块(校验 + `tern.kv`);window 半每 tick 顺便重读(kv 便宜),改动即时全窗口生效。

### D6 插件内 i18n(增强)

joaodutra88 的 labels 模块模式(en 为基准,其他语言 `__index` 回退),首版 en + zh-CN。所有面板/菜单/toast/卡片文案集中于此。

## 4. 模块划分

```
tern-dora-tern-omp-usage/
├── plugin.toml            # id=dora-tern-omp-usage, host+window 入口, blocks=[dashboard]
├── host.luau              # host 半入口:装配 poller + dashboard block
├── window.luau            # window 半入口:装配 watcher/render/settings/statusline
├── lib/
│   ├── parse.luau         # 纯函数:omp JSON → 内部模型(无 tern 依赖,可单测)
│   ├── poller.luau        # host 轮询器(串行队列、退避、kv 写入)
│   ├── model.luau         # Line/卡片的数据组装(当前提供商、模式、去重、排序)
│   ├── render.luau        # Line → CSS 文本、卡片 CSS、comet 动画、sheet 管理
│   ├── watcher.luau       # dock 树读取、芯片名提取、焦点判定
│   ├── settings.luau      # 设置 schema、校验、kv 读写、变更通知
│   ├── panel.luau         # canvas 设置面板(节点树 + action 分发)
│   ├── menus.luau         # palette 菜单(pick 多级)
│   ├── dashboard.luau     # host block 视图(usage --history + 费用)
│   └── labels.luau        # en / zh-CN 文案
└── scripts/check.py       # CI:luau-analyze 类型检查(joaodutra88 同款)
```

**plugin.toml**

```toml
schema = 1
id = "dora-tern-omp-usage"
name = "Dora omp Usage"
version = "0.1.0"
description = "Usage line above the omp composer (any provider omp reports: Kimi, Codex, Claude, …), today's tokens & cost, dashboard, settings panel."
icon = "gauge"
host = "host.luau"
window = "window.luau"

[[blocks]]
id = "dashboard"
title = "Dora omp Usage"
```

## 5. 数据流与调度

### 5.1 host 轮询器(poller.luau)

```
每项任务 = { name, interval_ms, run }
队列:同一时刻最多 1 个 omp 进程在跑(串行),完成后再取下一个到期任务
任务:
  usage   每 settings.usage_interval(默认 90s,失败退避×2,上限 10min)
          `omp usage --json` → parse.reports() → kv.usage = { at, reports, fail }
  models  每 10min(失败退避)
          `omp models --json` → parse.catalog() → kv.models = { at, byName, byId, prefix }
  stats   每 5min
          `omp stats --json` → parse.timeseries() → 今日和 → kv.today / kv.days(逐日合并)
手动刷新(命令/点击/模型切换):把 usage 提到队首,并带 `omp usage invalidate` 前置一次
```

- 进程调用统一 `tern.process.run(argv, {timeout_ms=15000}, cb)`,回调里只做解析与 kv 写(<50ms)。
- `os.getenv` 定位 omp:环境变量 `OMP_USAGE_PLUS_BIN` → 托管路径(`%LOCALAPPDATA%\Tern\omp\bin\omp.exe` 等,joaodutra88 同款探测)→ PATH 里的 `omp`。
- kv 结构带 `at`(epoch ms),window 据此显示陈旧程度。

### 5.2 window 渲染循环(watcher + render)

```
tern.timer(1000) tick:
  1. cx.session:focused() / :panes() → 聚焦窗格是否 agent
  2. 是 → cx.session:surface(pane, { root="dock" }) → 芯片名、focus 行、meter 节点存在性
  3. 读 kv.usage / kv.models / kv.today(settings 每 tick 顺便重读)
  4. model.build(settings, chip, data) → Line 模型(签名 = 内容指纹)
  5. 签名变化 → render.line():生成整段 CSS → tern.css("usage", css)
     变化窗口 → 附 comet 动画 CSS(1.4s 后清除)
  6. 非 agent 窗格 → tern.css("usage", "") 清除
tern.on("focus") → 立即 tick 一次
tern.timer(300) 启动首 tick;reload 后同路径恢复
```

性能要点(全部来自两项目实测教训):
- dock 树每秒重读 ~40 节点,渲染函数本体 10ms 级;若本 tick 只更新了 kv,跳过 CSS 重建。
- kv 读取包 `pcall`;JSON 解码只在文本变化时执行(joaodutra88/jmazzola 均如此)。
- 动画计时器用 `tern.timer(1450, clear)` 一次性清理。

### 5.3 状态栏与仪表盘

- `tern.chrome.status(fn)`:pane.kind == "agent" → 返回今日两段 + `usage` 段(打开面板);其余窗格返回 nil(或按 Q1 设置常显)。
- 仪表盘:host block(`tern.block.define`),`cx:new_block("dora-tern-omp-usage.dashboard", nil, "beside")`;数据 `omp usage --history --json --days 7` + kv.days;`r` 刷新;视图用 `ui.meter / ui.spark / ui.kv / ui.bars`(joaodutra88 同款组件)。

## 6. 数据契约

### 6.1 内部模型(parse.luau 输出)

```lua
-- 一个提供商的一份用量报告归一为:
Report = {
  provider = "kimi-code",          -- 原始 id
  label    = "Kimi",               -- 短标签(映射表/启发)
  windows  = { Window... },        -- 归一化、去重、排序后
  credits  = 3,                    -- 可用 saved resets 数
  resets   = { { expiresAt=ms, count=n }... },  -- 7d 的 saved resets 明细
}
Window = { key="5h"|"1d"|"7d"|"mo"|"<span>"|"<id>",
           label="5h",            -- 显示标签
           ms=number|inf,         -- 排序用
           left=0..1,             -- remainingFraction 或 capacity 比例
           resetAt=ms?,           -- 重置时刻
           accounts=n? }          -- Codex capacity 时的账号数
```

归一化规则(对应 FR-3):
- 窗口映射:`5h|5h±1min → 5h`;`daily|24h|1d|24h±1min → 1d`;`7d → 7d`;`monthly|30d|28~31d → mo`;有 durationMs 的其他 → `<span>`(`2h/3d/90m`);仅 windowId → 用原 id。
- **Kimi 去重**:`windowId` 匹配 `^limit_` 且存在已归一窗口与其 `left`(3 位小数)和 `resetAt`(秒级)相同 → 丢弃。
- scope 限定:`scope.shared==true` 或无 `tier/modelId` → 套餐级;否则仅当当前模型 bare id 命中(`id 含 modelId 且含 tier`)时保留;若该提供商所有已知模型都不命中任何 scope → 全部视为套餐级(与 jmazzola `limitApplies` 一致)。
- capacity(provider 级,跨账号):窗口 = `usedAccounts/accounts`,与该提供商 limits 合并(captity 优先展示)。
- 排序:ms 升序,inf 在最后;同 key 取第一个。

### 6.2 tern.kv schema(唯一持久层)

| key | 结构 | 写者 | 读者 |
|---|---|---|---|
| `usage` | `{ at, ok, reports: Report[](已归一), err? }` | poller | window 全部 |
| `models` | `{ at, byName: {name→provider}, byId: {id→provider}, prefix: {prefix→provider} }` | poller | watcher |
| `today` | `{ at, tokens, cost, day: "YYYY-MM-DD" }` | poller | window/statusbar |
| `days` | `{ ["YYYY-MM-DD"]: {tokens, cost} }`(62 天滚动) | poller | dashboard |
| `settings` | `{ mode, selected[], order[], colors{key→spec}, warnAt, badAt, usageInterval, statsInterval, showTokens, showCost, alerts, language }` | settings 模块 | window 全部 |

设置 key 的默认值与校验集中在 `settings.luau` 的 SCHEMA 表,面板/菜单/命令共用一份。

## 7. 渲染规格(render.luau)

沿用并简化 jmazzola 的 CSS 方案(无状态栏事实隐藏,少一半复杂度):

- **布局**:线为 meter `::before`,13px 高、单行 mono;`<label> <bar> <pct>% <reset>` 以 NBSP 连接,窗口间用 `·`;放不下整项 NBSP 换行到裁剪的第二行(FR-1.6)。
- **条形**:`━`×8(紧凑 6),`background-clip:text` 一层渐变按字符区间着色:已填部分 = 提供商色、未填 = 15% 透明提供商色;`::after` 为亮端 tip(radial 渐变)。
- **配色**:每提供商 `{label, bar1, bar2?}`;预设:Claude clay `#d97757`、Codex graphite→blue、OpenAI green、**Kimi green**、Gemini blue→white、MiniMax red→pink、Qwen purple…,未知提供商 = theme accent;自定义 spec=`#hex` 或 `#hex, #hex`;≤25% 全线该窗口变 amber、≤10% 变 red(独立于提供商色)。
- **comet**:窗口 left 值变化 → 该窗口区间以 `image()` 层做 1.4s 位移动画(降=提供商色,升=--ok 绿);Reduce Motion(Tern 或系统)时输出 STILL 版本,无任何动画。
- **悬停卡片**:hover 目标为附件 chips 行;卡片逐行 = 窗口名 + 计量器 + 剩余 + `resets in Xm · HH:MM` + saved reset 到期(`expires Thu Oct 22, 12:00 PM · in 10d 14h`,zh-CN 用本地化格式);尾行 = 今日 token/费用 + `settings · <chord>`(chord 从 `cx.actions:keys()` 读,缓存 30s)。
- **清除**:卸载/停用即消失(CSS sheet 随插件销毁),无 DOM 残留。

## 8. 设置面板(panel.luau)

- 打开:`cx.canvas:open({ title, about, view, dock, how="beside" })`;已开则 `cx.layout:focus`。
- 分区:Line 预览(用 kv 最新数据渲染假线)→ Show(三选一)→ Providers(行 = 开关 + ↑/↓/置顶)→ Colors(每提供商一排色点:预设×6、Theme accent、Custom…、Reset)→ Meters(amber/red 阈值)→ Polling(两个间隔)→ Status bar(两开关)→ Alerts → Language。
- 交互:`tern.on("canvas_action", ev)` 按 `ev.act/ev.value` 分发到 settings 模块,然后 `after_change()`:重载设置、立即重渲染线与面板;Custom 颜色走 `cx:prompt`(文本输入 hex)。
- 面板状态签名(state.sig)去重:数据没变不重绘;`pane_closed` / `canvas_action` 维护 panel_pane;reload 后 `find_panel()` 找回 Tern 保留的面板。

## 9. 错误处理与降级矩阵

| 情形 | 表现 |
|---|---|
| omp CLI 不存在 / 启动失败 | kv.usage 不更新;线显示上次数据,卡片标注"数据 X 分钟前";连续 3 次失败线变为灰色省略号,不再弹任何 toast |
| `omp usage --json` 解析失败 / reports 空 | 同上;若从未成功过 → 线不渲染 |
| 当前提供商无报告(未登录) | `current` 模式回退为"全部提供商"(FR-4.2 回退链末端) |
| 芯片名读不到(非 omp 窗格 / 树变化) | 线隐藏;`current` 模式用最后一次有效芯片(≤2min) |
| meter 锚点缺失(Tern 升级破选择器) | 线与卡片整体静默不渲染;状态栏今日段不受影响;README 注明需适配版本 |
| `omp stats` 为空 / 未同步 | 今日段隐藏;仪表盘费用卡显示空态文案 |
| kv 读写异常 | pcall 吞掉,按默认值处理 |
| 轮询超时(15s) | 视为失败,走退避;串行队列不被卡死(下个任务照常) |

## 10. 性能预算

| 项 | 预算 | 依据 |
|---|---|---|
| 定时器回调 | ≤ 50 ms | Tern 超时即停用插件全部定时器(joaodutra88 注释) |
| 单 omp 进程 | 并发 = 1;超时 15 s | Windows 起进程开销大;usage CLI 实测 ~0.6 s |
| CSS 重建 | 仅签名变化时;本体 < 10 ms | jmazzola 实测量级 |
| dock 树读取 | 每秒 1 次,~40 节点 | jmazzola 同配置 |
| kv 体积 | usage < 32 KB、days < 8 KB | 序列化上限,超限截断旧数据 |

## 11. 兼容性与风险

| 项 | 目标版本 | 说明 |
|---|---|---|
| Tern | 0.8.x(验证 0.8.0+) | 依赖:surface(dock 树)、css sheets、canvas、chrome.status、block、kv、process、timer、command/pick/prompt |
| omp | ≥ 18.9(验证 18.14.1) | 依赖:`usage --json`(reports/limits/scope/window/amount/resetCredits/capacity)、`models --json`、`stats --json`、`usage --history --json` |
| 平台 | Windows(验证)/ macOS / Linux | omp 托管路径探测三平台齐全(joaodutra88 清单);其余无平台分支 |

**风险控制**:
- R1(选择器漂移):`render.luau` 顶部集中全部选择器常量并注明来源版本;启动探测失败 → 降级开关(线关、状态栏照常)。
- R2(CLI schema):parse 层每字段 `type()` 防御;未知窗口/提供商显示而非丢弃。
- R3(模型映射精度):三级回退链,最差情况显示全部提供商(信息不多不少)。
- R4(限流):默认 90 s + 指数退避;`invalidate` 只在手动刷新;设置页提示调低间隔的风险。

## 12. 测试与发布

- **单测**(无 tern 依赖的纯函数):parse.luau(kimi 去重、capacity 聚合、scope 过滤、窗口归一)、model.luau(模式/排序/签名)、settings.luau(校验)。可在本地 luau 或 CI 中跑(`scripts/check.py` 用 luau-analyze 做类型检查,测试文件仿 joaodutra88 `tests/history_test.luau`)。
- **手测清单**:验收标准(需求文档 §6)逐条;三形态报告 fixture(kimi/codex/claude)注入 kv 验证渲染。
- **发布**:GitHub 仓库 → `tern plugin install github.com/<you>/tern-dora-tern-omp-usage`;tag + CHANGELOG;P2 更新检查走 GitHub releases API。
- **文档**:README(英/中双语,安装 30 秒动画 GIF)+ 本目录两份文档随仓库维护。

## 13. 里程碑

| 里程碑 | 内容 | 验收 |
|---|---|---|
| M1 数据层 | plugin.toml、host.luau、poller、parse、kv 落地 | `tern plugin list` ready;kv 中 usage/models/today 数据正确(kimi 实测数据) |
| M2 用量线 | watcher + model + render,`current` 模式 | 聚焦 omp 窗格出现线;切模型跟随;失焦消失 |
| M3 卡片 | 悬停卡片全量内容 + comet 动画 | 与 jmazzola 截图对齐 + 今日尾行 |
| M4 设置 | 面板 + 菜单 + 命令 + 键位 | 全部设置项即时生效、跨窗口共享、重启保留 |
| M5 今日+仪表盘 | chrome.status 段 + dashboard block | 图2 状态栏胶囊;仪表盘 7 天图 |
| M6 打磨 | i18n(zh-CN)、降级矩阵全覆盖、多提供商模式、Codex capacity、CI | 验收标准全过 |

依赖顺序:M1 → M2 → (M3, M4, M5 可并行) → M6。

## 14. 多主机语义(官方文档确认,2026-10-31 补)

来源:[Architecture › Where each half runs](https://docs.stencil.so/tern/concepts/architecture.html)、[Packages › Data directory](https://docs.stencil.so/tern/concepts/packages.html)。

- **Host 半在 pane 所在的机器上运行**:"Install a host half on the machine whose panes it should serve." 远程主机的 daemon 从**该机器自己的插件文件夹**加载插件。
- **Window 半是本地的**:"Your window half is local: it runs from your plugins folder and **sees every pane in your windows, local and remote**." Windows Tern 窗口(无论显示本地还是 WSL 的 pane)画线的都是 Windows 侧的 window half。
- **kv 不跨主机同步**:"Both halves of a plugin, and the window half in every window, share this folder and one `tern.kv` store"(同一台机器内共享一个 kv.json);**"Each machine reads its own settings; nothing syncs between hosts."**
- 因此本插件的数据语义:
  - **用量限额线** = 窗口所在机器的 omp 账号数据(账号级;若两机登录同一批账号,数字一致,显示正确);
  - **今日统计** = 窗口所在机器的 stats.db("本机今日"文案即为此语义);
  - 远程主机(如 WSL)要服务它自己的 pane/窗口,必须在它上面安装插件(host half),其数据写入该机器的 kv。
- 已实测验证(探针写入 `probe_host`/`probe_window`):Windows kv 含 windows 的 host+window 探针;WSL kv 仅含 linux 的 host 探针 —— 与文档完全一致。
- **限制**:Windows 窗口显示 WSL pane 时,无法读到 WSL 的今日统计(无跨主机 API)。缓解:① 在 WSL 侧开 Tern 窗口看 WSL 数据;② 未来可探测远程 pane(cwd 为 POSIX 路径)并经 ssh 拉取远程 stats(超出 MVP,记录备查);③ 向 Stencil 提议暴露 pane 所属 host 或远程 kv 只读访问。

## 15. 附录:参考项目 API 速查(实测自源码)

| API | 用途 | 出处 |
|---|---|---|
| `tern.css(sheet, css)` | 注入/更新样式表 | jmazzola / joaodutra88 |
| `tern.timer(ms, fn)` | 定时(单次;循环需自递归) | 两者 |
| `tern.kv.get/set` | 插件持久 kv(host/window 共享) | 两者 |
| `tern.process.run(argv, opts, cb)` | 异步进程(回调含 stdout/status) | joaodutra88 |
| `tern.json.decode` / `tern.fs.read/exists` / `tern.getenv` / `tern.now` | 基础设施 | 两者 |
| `tern.command{ id,title,icon,keys,run,available }` | 面板命令/键位/隐藏命令 | 两者 |
| `tern.chrome.status(fn)` / `tern.chrome.refresh()` | 状态栏段注册/刷新 | joaodutra88 |
| `tern.on("focus"/"canvas_action"/"pane_closed")` | 事件 | jmazzola |
| `tern.plugin.id` / `tern.plugin.data` | 插件标识/数据目录 | 两者 |
| `tern.ui.{col,card,text,span,meter,spark,kv,bars,progress}` | block/panel 原生组件 | 两者 |
| `cx.session:surface(pane,{root}) / :panes() / :focused() / :pane(n)` | 读窗格 UI 树/信息 | jmazzola |
| `cx.canvas:open/set/list` + `tern.on("canvas_action")` | canvas 设置面板 | jmazzola |
| `cx:pick / cx:prompt / cx:toast / cx:new_block / cx.layout:focus` | 交互原语 | 两者 |
| `tern.block.define(id, {init,title,view,key})` | host block(仪表盘) | joaodutra88 |
