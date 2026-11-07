# Dora omp Usage — 架构文档

版本:v1.0.0 · 日期:2026-10-31
配套文档:[REQUIREMENTS.md](./REQUIREMENTS.md) · [IMPLEMENTATION.md](./IMPLEMENTATION.md) · [API.md](./API.md)

参考项目(致谢其探索):
- [jmazzola/tern-plugin-omp-usage](https://github.com/jmazzola/tern-plugin-omp-usage) — 用量线 UI 与设置面板的参考(MIT)
- [joaodutra88/tern-omp-usage](https://github.com/joaodutra88/tern-omp-usage) — 纯插件架构、今日统计、仪表盘、i18n 的参考(MIT)

---

## 1. 设计原则

1. **CLI 采集与可选正式身份桥分离** —— host 轮询负责账户额度/统计;主会话精确身份由随仓库分发的 omp 拓展提供。Tern 一行安装不自动修改 omp 配置;缺桥且同名跨提供商时并列显示全部候选(标注 `同名 ×N`),不猜一家,不保证重名模型精度。
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
│  │ host.luau               │          │ window.luau             │ │
│  │  ├ usage: omp usage     │  tern.kv │  ├ 100ms: 焦点 & composer│ │
│  │  │        --json (90s)  │ ────────▶│  │   树 → 模型芯片名     │ │
│  │  ├ models: omp models   │ (usage/  │  ├ build: 组装 Line 模型 │ │
│  │  │        --json (10m)  │  models/ │  ├ render: tern.css 注入 │ │
│  │  └ stats: omp stats     │  today/  │  │   线 + 悬停卡片        │ │
│  │       --json (5m)       │  days)   │  ├ chrome.status 今日段  │ │
│  │ dashboard block         │          │  ├ 设置菜单(pick)         │ │
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

### D1 数据获取:host 半轮询 CLI,身份由轻量拓展提供

额度、目录、统计仍由 host 半按源串行轮询 omp CLI,不会改成每会话重复采集。可选 `omp/extensions/model-identity.js` 只在主 TUI 会话通过隐藏原生 widget 提供实时身份,无轮询、无文件写入。要求 omp ≥ 18.18.0,需在每个运行 omp 的主机加载;路径与配置方式见 README。插件绝不自动修改用户配置。

### D2 当前提供商识别:统一身份解析器

1. 每约 100 ms 读取聚焦窗格 dock,由 `lib/identity.luau` 提取芯片、子代理 focus 标志和 role `dora.omp.model-identity` 的 JSON。
2. v1 身份字段为 `sessionId, scope: main, provider, id`。拓展使用 `ctx.models.current()` 实时 getter,不依赖公开 `model_changed` 事件。有效主桥确定 selector;目录对应项与芯片不符时待确认。
3. 仅桥缺失时允许 v2 目录回退。`by_name` 保存候选列表，不丢同名项；唯一精确显示名候选解析。跨提供商多候选全部保留并交给界面，不做 first-hit、id 子串、前缀启发或配置/额度/消费排序。非法/不支持桥阻止回退。
4. 无桥且同名跨提供商时，当前模式同时显示全部候选并标注 `同名 ×N`；某家无数据只省略该项，切换同名模型时仍并列。同一提供商多候选、全部无数据、非法/不支持桥及查看子代理时显示待确认及悬停帮助。解析到自身提供商但没有数据只显示自身提示，绝不退回另一家。all/selected 保持原行为。
5. 诊断复用相同解析结果;模型刷新身份键包括 pane、host、session、selector。先画对应缓存,再请求后台刷新。100ms 是读取周期而非硬时延保证;具体烟测与限制见 [CHIP-AMBIGUITY.md](CHIP-AMBIGUITY.md)。

### D3 用量线渲染:CSS 伪元素文本(沿用 jmazzola 技术)

- 锚点:`.tn-pane.on .sf-meter[data-role='omp.composer.context']`(聚焦窗格的上下文发丝线计量器)。
- 线 = 该元素 `::before` 的 `content`:13px 等宽盒,`<提供商> <窗口标签> <━条×8> <N%> <倒计时>` 文本;条形用 `━` 字形(等宽 0.6em),整条一个 `background-clip: text` 静态渐变,每段颜色由字符区间着色(Tern 每元素只画一层渐变且不随位移动画,故内容静止时零重绘)。
- 悬停目标:composer 附件 chips 行(`.sf-row[data-role='omp.composer.chips']:is(.sf-hidden,.sf-void)`)——平时隐藏、无 title、是 meter 的兄弟节点,恰好做悬浮层;有附件显示时线保持但取消悬停反应。
- 卡片:悬停 ~400 ms 后由 CSS(兄弟选择器 + 定位)在上方展开玻璃拟态卡片;内容按数据逐行生成,同样走 `content`/DOM 注入。
- 隐藏策略:不隐藏 omp 状态栏 usage 事实,状态栏原样保留;可选身份桥自身是隐藏原生节点,不占可见行。

### D4 今日统计:stats 轮询 + kv 逐日累积(沿用 joaodutra88 方案)

- `omp stats --json` → `timeSeries[]`(bucket 含 `timestamp`/`tokens`/`cost`)→ 累计 `≥ 当地零点` 的和。
- 逐日 totals 写 kv `days`(`YYYY-MM-DD → {tokens, cost}`,保留 62 天)——stats 只能回溯 ~1 天,周/月统计靠自存。
- 状态栏:`tern.chrome.status` 注册,agent 窗格聚焦时返回 `🔥 N tokens`、`💰 $N` 两段,`command` 指向打开仪表盘的隐藏命令。

### D5 设置:pick 菜单 + kv,多入口

- 菜单:`cx:pick` 多级列表(显示模式 / 选择·排序·配色 / 刷新 / 间隔 / 语言 / 状态栏开关),`tern.command` 注册命令,设置命令带默认键位 `ctrl+alt+u`;状态栏 `usage` 段与卡片尾行是额外入口。canvas 设置面板(`cx.canvas:open` + `tern.on("canvas_action")`)列为后续里程碑,尚未实现。
- 存取:唯一入口 settings 模块(校验 + `tern.kv`);window 半每 1s 重读快照,设置变更即强制重绘。

### D6 插件内 i18n(增强)

joaodutra88 的 labels 模块模式(en 为基准,其他语言 `__index` 回退),首版 en + zh-CN。所有面板/菜单/toast/卡片文案集中于此。

## 4. 模块划分

```
dora-tern-omp-usage/
├── plugin.toml            # id、版本、host/window 入口、dashboard block
├── host.luau              # fetch 服务和仪表盘
├── window.luau            # 焦点/主机映射、身份读取、CSS 安装、状态栏和菜单
├── omp/extensions/model-identity.js  # 可选原生主会话身份桥
├── lib/
│   ├── parse.luau         # CLI JSON → 精确身份键和用量模型
│   ├── identity.luau      # 纯 dock 身份提取和唯一候选解析
│   ├── fetch.luau         # 按源串行采集、锁和版本化 kv
│   ├── line.luau          # 供应商分组、用量线与悬停卡片 CSS
│   ├── settings.luau      # 设置校验与配色
│   ├── labels.luau        # en / zh-CN 文案
│   └── update.luau        # 版本检查和更新
└── tests/                 # identity.luau / line.luau 纯回归脚本
```

**plugin.toml**

```toml
schema = 1
id = "dora-tern-omp-usage"
name = "Dora omp Usage"
version = "2.0.0"
description = "Provider-aware omp usage, today's tokens and API-price cost, dashboard and settings. Optional companion extension provides exact main-session model identity."
icon = "gauge"
host = "host.luau"
window = "window.luau"

[[blocks]]
id = "dashboard"
title = "Dora omp Usage"
```

## 5. 数据流与调度

### 5.1 host 取数服务(host.luau + lib/fetch.luau)

```
每源串行队列 + kv 锁(4s 窗口),同一时刻每源最多 1 个 omp 进程
任务:
  usage   每 settings.usage_interval(默认 90s);失败保留上次数据,下个周期重试
          `omp usage --json` → parse.usage() → kv.usage@<源> = { version=2, at, reports, capacity }
  models  每 10min
          `omp models --json` → parse.catalog() → kv.models@<源> = { version=2, at, by_name=候选列表, by_selector, by_provider }
  stats   每 5min
          `omp stats --json` → parse.today() / parse.by_model_totals() → 今日和与按提供商账本 → kv.today@<源> / days@<源>
手动刷新(命令/点击):前置一次 `omp usage invalidate` 后立即取数;模型切换只写 refresh_usage 请求,宿主每 250ms 接收
```

- 进程调用统一 `tern.process.run(argv, {timeout_ms=20000}, cb)`,回调里只做解析与 kv 写(<50ms)。
- `tern.getenv` 定位 omp:环境变量 `OMP_USAGE_PLUS_BIN` → 托管路径(`%LOCALAPPDATA%\Tern\omp\bin\omp.exe` 等,joaodutra88 同款探测)→ PATH 里的 `omp`。
- kv 结构带 `at`(epoch ms),window 据此显示陈旧程度。

### 5.2 window 渲染循环(window.luau)

```
tern.timer(100) tick:
  1. 每 1s 更新主机映射、settings 与各源 usage / models / today 缓存
  2. cx.session:focused() / :pane() → 聚焦窗格是否 agent
  3. 是 → cx.session:surface(pane, { root="dock" }) → identity.read_dock
  4. identity.resolve(dock, models);身份未变且快照未刷新时直接返回
  5. line.build → line.sheet → 内容变化时 tern.css("usage-plus", css)
  6. 身份变化 → 写 refresh_usage@source,宿主每 250ms 接收并按源串行取数
  7. 非 agent 窗格 → 清除 CSS
tern.on("focus" / "window_start" / budget-resumed) → 强制刷新快照并 tick
reload 后由加载期 100ms 定时器恢复;常规后台到期检查仍为 5s
```

性能要点(全部来自两项目实测教训):
- dock 身份每 100ms 检查;设置、主机映射及 kv 数据每 1s 更新,避免在快路径重复读数据和生成 CSS。
- kv 读取包 `pcall`;切换先画缓存再写刷新请求,窗口快路径不启动 CLI 进程。

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
  credits  = 3,                    -- 可用 saved resets 数(resetCredits 汇总)
}
Window = { key="5h"|"1d"|"7d"|"mo"|"<span>"|"<id>",
           label="5h",            -- 显示标签
           ms=number,             -- 排序用;未知长度窗口为 MAX_MS=1e15(kv 不能存 Infinity)
           left=0..1,             -- remainingFraction 或 capacity 比例
           reset_at=ms?,          -- 重置时刻
           saved=n?, expires_at=ms?,  -- 7d 的已存重置数与最近到期(kv 存于 7d 窗口)
           accounts=n? }          -- Codex capacity 时的账号数
```

归一化规则(对应 FR-3):
- 窗口映射:`5h|5h±1min → 5h`;`daily|24h|1d|24h±1min → 1d`;`7d → 7d`;`monthly|30d|28~31d → mo`;有 durationMs 的其他 → `<span>`(`2h/3d/90m`);仅 windowId → 用原 id。
- **Kimi 去重**:`windowId` 匹配 `^limit_` 且存在已归一窗口与其 `left`(3 位小数)和 `resetAt`(秒级)相同 → 丢弃。
- scope 限定:`scope.shared==true` 或无 `tier/modelId` → 套餐级;否则仅当当前模型 bare id 命中(`id 含 modelId 且含 tier`)时保留;若该提供商所有已知模型都不命中任何 scope → 全部视为套餐级(与 jmazzola `limitApplies` 一致)。
- capacity(provider 级,跨账号):窗口 = `usedAccounts/accounts`,与该提供商 limits 合并(captity 优先展示)。
- 排序:ms 升序,inf 在最后;同 key 取第一个。
- **无限额提供商降级**:按量计费的服务没有 `limits[]`,因此既不在 `reports` 里也不在 `capacity` 里,唯一留痕是 `today@<s>.by_provider`。`line.build` 会为这类提供商补一个"只有当日消耗"的组(`windows={}`、`credits=0`、`spend={tokens,cost}`,Step 5 的 `add_group` 兜底),线上渲染为 `Bailian  TODAY 18.5M · $0.35`,不带计量条;同一 provider id 若同时有窗口则窗口优先,不会重复成组。`providers_present()` 也把它们计入,以便出现在服务开关与排序里。

### 6.2 tern.kv schema(唯一持久层)

| key | 结构 | 写者 | 读者 |
|---|---|---|---|
| `usage@<源>` | `{version=2, at, reports, capacity}`;供应商键保留大小写 | fetch | window |
| `models@<源>` | `{version=2, at, by_name: {显示名→候选列表}, by_selector: {provider/id→条目}, by_provider}` | fetch | identity / line |
| `today@<源>` | `{version=2, at, tokens, cost, day, by_provider}` | fetch | window/statusbar |
| `provider_days@<源>` | `{version=2, days: {日期→供应商分摊}}` | fetch | fetch |
| `by_model_prev@<源>` | `{version=2, by_provider: byModel累计值}` | fetch | fetch |
| `days@<源>` | `{日期: {tokens, cost}}`(62 天滚动) | fetch | dashboard |
| `settings` | `mode, selected, order, colors, warn_at, bad_at, usage_interval, stats_interval, show_tokens, show_cost, alerts, language, update_check` | settings | window |

设置默认值与校验集中在 `settings.luau`。升级时拒读旧小写化的 usage/models/today 记录,供应商累计基线和账本成对重建;保留每日总量历史,沿用原有分摊对账算式。

## 7. 渲染规格(lib/line.luau)

沿用并简化 jmazzola 的 CSS 方案(无状态栏事实隐藏,少一半复杂度):

- **布局**:线为 meter `::before`,13px 高、单行 mono;`<label> <bar> <pct>% <reset>` 以 NBSP 连接,窗口间用 `·`;放不下整项 NBSP 换行到裁剪的第二行(FR-1.6)。
- **无窗口组**:不画条与百分比,只有 `label · TODAY <tokens> · $<cost>`(纯 ASCII、`compact_number` 缩写);卡片里写全「今日 N tokens · $X」。分组间仍用 `·` 连接。
- **条形**:`━`×8(紧凑 6),`background-clip:text` 一层渐变按字符区间着色:已填部分 = 提供商色渐入、未填 = 轨道色;`::after` 为亮端 tip(radial 渐变)。线上文本保持 ASCII(中文仅出现在卡片),否则 CJK 字宽会破坏按字符推算的条形对齐。
- **配色**:每提供商 `{a, b?}`;预设:Claude clay、Codex graphite→blue、OpenAI green、**Kimi green**、Gemini blue→white、MiniMax red→pink、Qwen purple…,未知提供商 = theme accent;自定义 spec=`#hex` 或 `#hex, #hex`;≤25% 该窗口变 amber、≤10% 变 red(独立于提供商色)。
- **动画**:卡片入场 `usage-plus-card` 0.28s;`prefers-reduced-motion: reduce` 下全部动画/过渡禁用。
- **悬停卡片**:hover 目标为附件 chips 行;卡片逐行 = 窗口名 + 计量器 + 剩余 + `resets in Xm` + saved reset 到期(`expires in 10d 14h`,本地化);尾行 = 今日 token/费用 + `settings · Ctrl+Alt+U` 提示。
- **清除**:卸载/停用即消失(CSS sheet 随插件销毁),无 DOM 残留。

## 8. 设置菜单(window.luau)

- 打开:`tern.command` 注册 `panel`(键位 `ctrl+alt+u`)与 `settings`;另有状态栏 `usage` 段与卡片尾行提示两个入口。
- 菜单:`cx:pick` 单级列表(group 分组)→ 按项进入子级:Providers 的选择(`cx:pick` toggle 多选)、排序(选提供商 → 上移/下移/置顶/置底)、配色(预设/命名/自定义 `cx:prompt` hex/重置),以及两个刷新间隔的 `cx:prompt`(校验同 settings.load)。
- 交互:回调按 `item.pick` 分发到 settings 模块写入,然后 `after_change()`:强制 tick 重绘线与状态栏。canvas 设置面板(`cx.canvas:open` + `canvas_action`)为后续里程碑,尚未实现。

## 9. 错误处理与降级矩阵

| 情形 | 表现 |
|---|---|
| omp CLI 不存在 / 启动失败 | kv.usage 不更新;线显示上次数据;超过 15 分钟未更新时状态栏出现 ⚠ 段(点击打开诊断),不弹错误刷屏 |
| `omp usage --json` 解析失败 / reports 空 | 保留可用旧数据并说明陈旧;当前模式自身无数据仍显示自身提示,不以其他提供商替代 |
| 当前提供商无额度或今日消费 | `current` 显示自身提供商无数据提示,不切换其他提供商 |
| 身份缺失/歧义/非法/不支持 | 当前模式待确认及悬停说明,不复用旧芯片身份;非 omp 窗格清除线 |
| meter 锚点缺失(Tern 升级破选择器) | 线与卡片整体静默不渲染;状态栏今日段不受影响;README 注明需适配版本 |
| `omp stats` 为空 / 未同步 | 今日段隐藏;仪表盘费用卡显示空态文案 |
| kv 读写异常 | pcall 吞掉,按默认值处理 |
| 轮询超时(20s) | 视为失败,保留旧数据等待下个周期;串行队列不被卡死(下个任务照常) |

## 10. 性能预算

| 项 | 预算 | 依据 |
|---|---|---|
| 定时器回调 | ≤ 50 ms | Tern 超时即停用插件全部定时器(joaodutra88 注释) |
| 单 omp 进程 | 并发 = 1(每源);超时 20 s | Windows 起进程开销大;usage CLI 实测 ~0.6 s |
| CSS 重建 | 仅签名变化时;本体 < 10 ms | jmazzola 实测量级 |
| dock 树读取 | 每 100 ms(身份);~40 节点 | 2.0.0 起身份检测从 1 s 提到 100 ms |
| kv 体积 | usage < 32 KB、days < 8 KB | 序列化上限,超限截断旧数据 |

## 11. 兼容性与风险

| 项 | 目标版本 | 说明 |
|---|---|---|
| Tern | 0.8+;身份桥验证 0.9.12 | 依赖 surface(dock 树)、原生隐藏 widget 节点、CSS 等;旧版桥兼容性未验证 |
| omp | 身份桥 ≥ 18.18.0(Windows / WSL 已验证) | CLI 采集独立;桥需每个 omp 主机加载 |
| 平台 | 既有 CLI 采集支持 Windows/WSL/SSH | 身份桥已验证 Windows/WSL picker 切换、Windows 双 pane 隔离与新会话;SSH 无可用测试主机 |

**风险控制**:
- R1(选择器漂移):`lib/line.luau` 顶部集中全部选择器常量(`METER`/`HOST_BASE`);meter 锚点缺失时线整体不渲染,状态栏照常。
- R2(CLI schema):parse 层每字段 `type()` 防御;未知窗口/提供商显示而非丢弃。
- R3(模型映射精度):主桥提供正式身份;缺桥时唯一精确候选直接解析,同名跨提供商并列显示全部候选(标注 `同名 ×N`),同提供商多候选、非法/不支持桥及子代理歧义待确认,禁止其他提供商替代。
- R4(限流):默认 90 s 固定间隔,失败保留旧数据;`invalidate` 只在手动刷新;设置可调低间隔,架构文档 §16 说明其收益边界。

## 12. 测试与发布

- **回归**:无 tern 依赖的纯函数场景集中在 `tests/identity.luau` 与 `tests/line.luau`(身份解析、同名候选、Kimi 去重、capacity、排序、签名),`luau tests/identity.luau` / `luau tests/line.luau` 直接运行,输出一行 PASS。
- **手测清单**:验收标准(需求文档 §6)逐条;三形态报告 fixture(kimi/codex/claude)注入 kv 验证渲染。
- **发布**:GitHub 仓库 → `tern plugin install github.com/DoraJasmine/dora-tern-omp-usage`;tag + CHANGELOG;更新检查走 releases.atom,状态栏一键更新。
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
- kv 本身仍不跨主机同步,本插件不尝试从窗口直接读取远端 kv。当前 fetch 服务按 `local / wsl:<发行版> / ssh:<主机>` 分源执行 CLI,窗口使用 pane 所属 Tern 主机选择数据。
- 无法映射的主机不借用本机账户;`@wsl` 名称不能区分多个已安装发行版时返回不可用。源码不会把任意 SSH 主机映射到首个 WSL 发行版。
- 模型身份由当前 pane 的隐藏原生节点随终端输出传输,不是共享文件或跨机 kv。每个实际运行 omp 的主机需要独立加载身份拓展。

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

## 16. 数据新鲜度:插件与 omp 的双层更新机制

本节记录插件的取数机制与 omp(`oh-my-pi`,下称"omp")自身的数据更新机制如何衔接,以及由此推导出的间隔取值依据。依据为 2026-11-02 对 omp 18.14.x 源码([packages/ai/src/usage/claude.ts](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/usage/claude.ts)、[packages/coding-agent/src/cli/usage-cli.ts](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/cli/usage-cli.ts))与本机 `agent.db` 缓存的实测。

### 16.1 omp 侧:按需取数 + 本地缓存,无主动推送

omp 的额度数据不按固定周期刷新,而是"被请求时取数"的拉模型,包含三层:

1. **上游请求层**:omp 收到用量查询(会话内 TUI 状态行、`/usage`、`omp usage` CLI)时,才向各提供商的限额端点发起请求。取回的报告附带 `fetchedAt`(epoch ms,即数据生成时刻),并写入 `agent.db` 的 `usage_cache:report:<provider>:…` 缓存行。
2. **缓存层**:缓存报告带约 **5 分钟** 的 TTL(实测 kimi-code 296 s、openai-codex 325 s)。TTL 未过期时,再次查询直接返回缓存报告,不打上游。取数失败时,上一次成功报告按"最后良好值"策略继续供数,最长保留 **24 小时**;针对 Claude 等按 IP 限流的端点,失败后退避 **60 秒** 起步,避免加剧 429。
3. **自取层**:运行中的 omp 会话以约 **每小时一次** 的节奏自行刷新用量并追加历史快照(`usage_history` 表,即 `omp usage --history` 的数据来源;实测相邻快照间隔 3349–3540 s)。

因此 omp 报告的"数据生成时刻"以报告内 `fetchedAt` 字段为准,与查询发生的时刻解耦。

### 16.2 插件侧:间隔轮询 + 强制失效

插件(`lib/fetch.luau`)对每数据源按各自间隔轮询 omp CLI,间隔为数据年龄阈值(usage 默认 90 s、可设 60–600 s;stats 默认 300 s、可设 60–3600 s;models 固定 600 s),轮询节拍为 host 半每 5 s 检查一次到期。轮询间共享 kv 锁,host 半与 window 半的 watchdog 不重复取数。手动刷新与模型切换触发 `omp usage invalidate` 后立即取数,以绕过 omp 的 5 分钟缓存。

### 16.3 两层机制的衔接与推论

两层机制是"插件调度、omp 执行"的关系:插件决定询问频率,omp 决定上游访问频率。由此有三点推论:

1. **插件的 usage 间隔是"询问间隔",不是"数据新鲜度上限"。** 若询问时 omp 缓存未过期,返回的是缓存中的旧报告;插件 kv 中的 `at` 记录的是取回时刻而非数据生成时刻,故陈旧判定存在乐观偏差。缩短间隔短于 omp 缓存 TTL(~5 min)对新鲜度无增益。
2. **90 s 的默认间隔已接近有效下限。** 相对 omp 的 5 分钟缓存 TTL,90 s 保证缓存过期后约一个周期内即被插件捞起,且给手动 invalidate 留出空间;压至 60 s 仅在缓存恰好过期的窗口内略微提前,同时增加进程开销与上游限流风险(omp 自身在 429 后退避 ≥60 s)。官方第三方拓展(pi-usage-limit-tracker)采用 5 分钟轮询,可作佐证。
3. **stats 无上游限流问题。** `omp stats --json` 读本地统计库,300 s 默认间隔纯属开销权衡,可安全调低。

### 16.4 缓存 TTL 不可配置,唯一接口为 `omp usage invalidate`

omp 的额度缓存 TTL 为硬编码常量 `USAGE_REPORT_TTL_MS = 5 * 60_000`(`packages/ai/src/auth/sqlite-credential-store.ts`),写入时叠加 ±25% 随机抖动(实际 3.75–6.25 分钟),以错开多账号同时刷新、避免按 IP 限流的端点周期性 429。经查证,该值**不提供任何配置入口**:环境变量参考、YAML 设置家族与 CLI flag 中均无对应项;官方文档中唯一名字相近的 `OMP_AUTH_BROKER_SNAPSHOT_TTL_MS` 管的是凭据快照,与额度缓存无关。

唯一受支持的强制刷新接口是 `omp usage invalidate`(CLI 子命令)。其实现(`packages/ai/src/auth/usage-cache.ts`)并非立即向上游取数,而是写入一个 5 分钟有效(`USAGE_FORCE_REFRESH_TTL_MS`)的强制刷新标记,在随后的取数轮次中让对应 provider 跳过缓存直接请求上游,并串行化同 provider 的探测以避免冷账号突发。本插件的手动刷新与模型切换路径已正确使用该接口。

由此确定:额度数据的新鲜度下限约为"缓存 TTL(5±1.25 min)+ 插件轮询周期",为 omp 的设计决策,插件侧无法绕过(除直接读其 SQLite 缓存外,不取)。插件的最优策略即现状——90 s 间隔轮询、敏感操作前 invalidate;若需更实时的额度,应向 omp 上游提议增加缓存 TTL 配置项。

### 16.5 待办:以 `fetchedAt` 校正陈旧判定

omp 输出的每份报告携带 `fetchedAt`。插件解析时若优先采用该字段(缺失时回退本地时间),kv `at` 即反映数据的真实生成时刻,陈旧标记与 16.3.1 的乐观偏差随之消除。已列入待办。
