# omp Usage Plus — 需求文档

版本:v0.9(草案) · 日期:2026-10-31
状态:待评审
代号:`dora-tern-omp-usage`(仓库)(插件 id:`dora-tern-omp-usage`)

---

## 1. 背景

[Tern](https://stencil.so/tern) 是 Stencil 出品的 Rust 原生终端,插件用 Luau 编写。
[omp](https://omp.sh) 是 Tern 内置的编码代理,`omp usage --json` 会报告所有已登录提供商的订阅用量限制。

现有两个同类插件,各有明显短板:

| | [jmazzola/tern-plugin-omp-usage](https://github.com/jmazzola/tern-plugin-omp-usage) | [joaodutra88/tern-omp-usage](https://github.com/joaodutra88/tern-omp-usage) |
|---|---|---|
| **UI** | ✅ 用量线显示在 omp composer 上下文栏正上方,细条计量器、悬停详情卡片、换窗格跟随当前模型 | ❌ 仅状态栏圆点风格,信息密度低 |
| **安装** | ❌ 5 步手动配置:clone → `tern plugin link` → 手改 `~/.omp/agent/config.yml` 注册 omp 扩展 → 配置 `statusLine.showHookStatus` → 重启 omp | ✅ 一行:`tern plugin install github.com/joaodutra88/tern-omp-usage` |
| **提供商** | ✅ 任意 `omp usage` 报告的提供商(Claude、Codex、Kimi、Gemini、MiniMax…),跟随当前模型自动切换 | ❌ 硬编码只支持 Claude + Codex,**不支持 Kimi** |
| **今日统计** | ❌ 无 | ✅ 今日 token + API 价格费用(`omp stats`),7 天仪表盘 |
| **设置** | ✅ 图形化设置面板(canvas pane):显示模式、提供商开关与排序、逐提供商配色 | ⚠️ 仅命令面板文本输入式设置 |

**本机实测踩坑**(2026-10-31,omp 18.14.1 / Windows):手动注册扩展时路径极易出错——
`~/.omp/agent/config.yml` 中被写成了 `D:/tern-plugin-omp-usageomp/extensions/usage-remaining.js`
(目录名与 `omp/` 拼接时丢了分隔符),omp 每次启动报 "Failed to load extension",且插件完全失效。
这正是"配置太多、容易错"的直接证据。

## 2. 目标

做一个**兼具两者优点**的单一 Tern 插件:

> **一行安装 + jmazzola 的 UI + 今日 token/费用统计 + 支持 Kimi 与 Codex + 图形化设置。**

### 目标(G)

- **G1 一行安装**:仅需 `tern plugin install github.com/<you>/tern-dora-tern-omp-usage`(或在 Tern 设置页粘贴该地址),**零 omp 配置**、不注册 omp 扩展、不改 `~/.omp/agent/config.yml`。
- **G2 用量线 UI**:复刻 jmazzola 的体验——用量线显示在聚焦 omp 窗格 composer 上下文栏(上下文发丝线)正上方,细条计量器、提供商配色、悬停详情卡片。
- **G3 提供商无关**:显示 omp 报告的**任何**提供商(Kimi、Codex、Claude、Gemini…),新提供商零代码接入;内置 Kimi/Codex/Claude 等配色预设。
- **G4 当前模型跟随**:切换模型(Alt+P)后约 2 s 内切换到对应提供商的用量;查看子代理转录时跟随子代理模型。
- **G5 今日统计**:今日(当地零点起)token 用量与 API 价格费用,覆盖所有提供商(数据源 `omp stats`);状态栏常驻段 + 点击打开 7 天仪表盘。
- **G6 图形化设置**:与 jmazzola 同级——canvas 设置面板 + 命令面板菜单,显示模式 / 提供商开关与排序 / 逐提供商配色 / 刷新间隔 / 阈值 / 语言。
- **G7 稳健降级**:omp 未登录、CLI 失败、Tern 版本 CSS 选择器变化时优雅降级,不崩溃、不刷屏。

### 非目标(Non-goals)

- N1 不做 iOS/Web 端适配(仅桌面 Tern)。
- N2 不修改 omp 的配置文件、不注册 omp 扩展(与 jmazzola 的根本区别)。
- N3 不做用量预测之外的数据分析(工作周预算等 joaodutra88 特色功能列为 P2,可选)。
- N4 不接入 omp 之外的凭据或网络服务(更新检查的 GitHub API 除外,P2)。
- N5 不汉化 Tern 本体(另有 zh-cn 插件)。

## 3. 用户故事

| # | 故事 | 验收 |
|---|---|---|
| US-1 | 作为用户,我把 `github.com/<you>/tern-dora-tern-omp-usage` 粘贴进 Tern 设置页的 Install 框,点 Install,插件立即生效,没有其他步骤 | 安装后 ≤ 10 s 出现用量线(前提:omp 已登录且已打开 omp 窗格) |
| US-2 | 我聚焦一个 omp 窗格,看到当前模型提供商的 5h/7d 用量线在上下文栏正上方 | 线仅在聚焦的 agent 窗格显示;宽度不够时整个窗口项换行或收起,不破版 |
| US-3 | 我按 Alt+P 把模型从 K3 切到 GPT-5.x,用量线 ~2 s 内换成 Codex 的 | 模型芯片名变化后 ≤ 1 个轮询周期 + 1 s 内重绘 |
| US-4 | 我悬停用量线,出现玻璃拟态卡片:每个窗口的计量器、重置倒计时与时钟时间、已保存重置的到期时间、今日 token/费用、设置快捷键 | 卡片在 ~400 ms 延迟后出现;移开即消失;Reduce Motion 时无动画 |
| US-5 | 我看一眼状态栏的 `🔥 616M tokens 💰 $235`,知道今天花了多少;点它打开 7 天仪表盘 | 数据来自 `omp stats`,每日零点清零;点击打开/聚焦仪表盘窗格 |
| US-6 | 我同时登录 Kimi 和 Codex,在设置里选"全部提供商"或勾选想看的,拖不动就用上下移按钮排序 | 设置即时生效并在所有 Tern 窗口共享(存 `tern.kv`) |
| US-7 | 我在设置面板给 Kimi 换成自定义颜色 `#22d3ee, #a78bfa`,线和卡片立即变色 | 支持 6 个命名预设 + 自定义 1–2 个 hex + 重置 |
| US-8 | Kimi 报告同时含 `7d` 和内容相同的 `limit_7d` 两个窗口,我不想看到重复 | 去重后只显示一个 |
| US-9 | 我只有一个提供商登录时,不用任何设置,默认就该显示它 | 默认模式 `current`:跟随当前模型;模型无法识别时回退显示全部提供商 |
| US-10 | omp 命令临时失败,线保留上一次数据并显示陈旧标记,恢复后自动更新 | 连续失败 2 次起在卡片中标注"数据 X 分钟前";恢复后清除 |

## 4. 功能需求

优先级:P0 = 首版必须有,P1 = 首版尽量有,P2 = 后续。

### FR-1 用量线(P0)

- FR-1.1 在聚焦 agent 窗格的 composer 上下文栏正上方绘制用量线;失焦即隐藏,焦点回到 omp 窗格即恢复。
- FR-1.2 每个窗口一项:`<窗口标签> <计量条> <N% left> <重置倒计时>`,窗口按时长升序(5h → 1d → 7d → mo → 其他按长度)。
- FR-1.3 计量条为 8 格(窄处 6 格)字形条,填充比例 = 剩余比例,亮端有"彗尾"亮点。
- FR-1.4 剩余 ≤ 25% 该窗口变琥珀色,≤ 10% 变红色(阈值可设置,FR-6.5)。
- FR-1.5 显示模式:`current`(默认,当前模型提供商)/ `all`(全部提供商)/ `selected`(勾选的提供商)。`all`/多提供商时省略倒计时与 "left" 字样(卡片里有)。
- FR-1.6 窄窗格:放不下的窗口整项换行到被裁剪的第二行(不截半个字)。
- FR-1.7 数据变化时整行重打,变化的计量条跑"彗星"动画到新值(配额降 = 提供商色,回升 = 绿色);Reduce Motion 下全部动画禁用。

### FR-2 悬停卡片(P0)

- FR-2.1 悬停 ~400 ms 后在线上方弹出卡片,逐窗口:计量器、剩余百分比、重置倒计时与时钟时间。
- FR-2.2 已保存重置(saved resets):`(+N)` 显示在 7d 窗口行内;卡片中列出每次的到期日期时间。
- FR-2.3 `all` 模式下卡片按提供商分组。
- FR-2.4 卡片尾行:今日 token/费用摘要 + "settings · Ctrl+Alt+U" 快捷键提示(实际键位从 Tern 键位表读取)。

### FR-3 提供商支持(P0)

- FR-3.1 数据一律来自 `omp usage --json` 的 `reports[]`,不白名单提供商;新提供商出现即显示。
- FR-3.2 提供商短标签:内置映射(anthropic→Claude、openai-codex→Codex、**kimi-code→Kimi**、google-gemini-cli→Gemini、minimax-code→MiniMax、alibaba-token-plan→Qwen…),未知的取 id 首个有意义的词首字母大写(如 `muse-code`→Muse)。
- FR-3.3 窗口归一化:windowId/durationMs 映射为 `5h / 1d / 7d / mo / <span>`;未知 windowId 按原 id 显示,不丢弃。
- FR-3.4 **Kimi 去重**:windowId 形如 `limit_*` 且与某个已归一窗口的 `remainingFraction` 与 `resetsAt` 相同时,丢弃 `limit_*` 项。
- FR-3.5 **Codex 多账号**:存在 `capacity[provider]` 时,窗口用量 = `usedAccounts / accounts`(即"用完的账号占比"),并显示 `×N` 账号数;无 capacity 时按普通 limits 渲染。
- FR-3.6 多账号同提供商(无 capacity):各账号同窗口取最差(usedFraction 最大)值渲染,卡片可展开各账号(P2)。
- FR-3.7 层级/模型限定窗口(scope.tier / scope.modelId,如 Codex Spark 5h):仅当当前模型属于该 scope 时显示;scope 无任何已知模型归属时视为套餐级显示。

### FR-4 当前模型识别(P0)

- FR-4.1 从聚焦 omp 窗格的 composer UI 树读取模型芯片名(role `omp.composer.model` 下 id 以 `/name` 结尾的文本节点)。
- FR-4.2 芯片名 → 提供商映射使用 `omp models --json` 目录(name/id/selector 匹配),目录每 10 min 刷新;匹配不到时回退:依次尝试 内置前缀启发表 → 显示全部提供商。
- FR-4.3 查看子代理转录时(芯片名变化),按子代理模型显示。
- FR-4.4 模型切换后立即用缓存重绘,并触发一次即时用量刷新。

### FR-5 今日统计(P0)

- FR-5.1 数据源 `omp stats --json` 的 `timeSeries[]`:累计 `timestamp ≥ 当地零点` 的 `tokens` 与 `cost`。
- FR-5.2 状态栏段 `🔥 <tokens> tokens` 与 `💰 $<cost>`,仅 agent 窗格聚焦时显示(与 joaodutra88 一致);样式为深色胶囊。
- FR-5.3 点击任一段打开/聚焦 7 天仪表盘。
- FR-5.4 `omp stats` 只能回溯约一天:每日 totals 存 `tern.kv`(保留 62 天)供仪表盘的周/月统计。
- FR-5.5 今日数据同时出现在悬停卡片尾行。

### FR-6 设置(P0)

- FR-6.1 打开方式:键位 `Ctrl+Alt+U`(可改绑 `plugin.dora-tern-omp-usage.panel`)、命令面板 "omp Usage Plus: Settings panel"、状态栏 `usage` 段点击、悬停卡片尾行。面板在聚焦窗格旁打开,重复打开聚焦已有面板。
- FR-6.2 设置项(即时生效,所有窗口共享,存 `tern.kv`):

| 组 | 项 | 默认 |
|---|---|---|
| Line | 预览(以最近使用的 omp 窗格数据渲染) | — |
| Show | current / all / selected | current |
| Providers | 逐提供商开关 + 上/下/置顶/置底排序按钮(Tern 不支持拖拽/右键) | 全开,内置顺序 |
| Colors | 逐提供商:6 个命名预设 + Theme accent + Custom(1–2 个 hex)+ Reset | Claude=Claude clay,Codex=graphite→blue,Kimi=Kimi green,其余=theme accent |
| Meters | 警戒阈值 amber%(默认 25)、red%(默认 10) | 25 / 10 |
| Polling | 用量刷新间隔(默认 90 s,下限 60 s)、今日统计间隔(默认 5 min) | 90 s / 5 min |
| Status bar | 今日 token 段开关、今日费用段开关 | 开 |
| Alerts | 达到阈值/锁定/解锁时 toast(开/关) | 开 |
| Language | en / zh-CN | 跟随 Tern,默认 en |

- FR-6.3 命令面板提供 "omp Usage Plus: Settings…" 菜单版(等价功能,键盘友好):显示模式、选择提供商(多选列表)、排序、颜色。
- FR-6.4 设置写入统一走设置模块(校验 + `tern.kv`),面板/菜单/命令共用。
- FR-6.5 告警 toast(P1):窗口升至阈值、锁定、重新可用时各一条,带重置倒计时;同窗口状态不重复提醒。

### FR-7 仪表盘(P1)

- FR-7.1 block 形式(host 半),`OMP Usage Plus: dashboard` 命令或点击今日段打开,在旁侧开新窗格;已有则聚焦。
- FR-7.2 内容:`omp usage --history --json --days 7` 的逐小时用量(当前提供商的窗口,meter + sparkline)+ 今日/近 7 天/本月费用(`ui.kv`)+ 近 7 天柱状图(`ui.bars`)。
- FR-7.3 `r` 键手动刷新。

### FR-8 安装、更新、卸载(P0)

- FR-8.1 安装:`tern plugin install github.com/<you>/tern-dora-tern-omp-usage`,或在设置页 Install 框粘贴;不要求 clone、不要求任何 omp 配置。
- FR-8.2 卸载/停用:`tern plugin remove/unlink` 或设置页开关;停用后不留任何残留(不改过任何外部文件,所以无需清理)。
- FR-8.3 更新:`tern plugin install --force <同地址>` 覆盖;P2:每日检查 GitHub release,状态栏 ⬆ 段 + 一键更新(joaodutra88 模式)。
- FR-8.4 迁移提示(P2):检测到 jmazzola 插件残留的 omp 扩展配置(`config.yml` 中的 usage-remaining.js 行)时,toast 提示可手动移除(本插件绝不自动改用户配置文件)。

## 5. 非功能需求

| # | 需求 | 指标 |
|---|---|---|
| NFR-1 性能 | 定时器回调不得阻塞 | 任何回调 ≤ 50 ms(Tern 会对超时插件停掉全部定时器);进程调用一律 `tern.process.run` 异步;每回调最多启动 1 个进程,串行排队 |
| NFR-2 轮询 | 默认用量 90 s、模型目录 10 min、stats 5 min、composer 树 1 s、缓存文件 3 s | 失败退避:连续失败翻倍间隔,上限 10 min;手动刷新立即执行并 invalidate |
| NFR-3 限流安全 | 常规轮询不调 `omp usage invalidate`;单进程超时 15 s;串行避免并发进程 | Anthropic 429 阈值(~5 min)下允许用户自担(可调低间隔,文档警示) |
| NFR-4 兼容 | Tern 0.8.x;omp ≥ 18.9(验证环境 18.14.1) | CSS 选择器集中在单一模块并带版本注释;omp JSON 字段缺失时跳过该项而非报错 |
| NFR-5 降级 | 见架构文档 §9 降级矩阵 | 无数据不渲染线;无 stats 隐藏今日段;CLI 缺失静默 + 卡片提示 |
| NFR-6 i18n | 插件自身 UI 文案(en/zh-CN)集中在 labels 模块 | 面板、菜单、toast 全覆盖;缺项回退 en |
| NFR-7 安全 | 不读写 omp 凭据;不修改 `~/.omp/**`;仅读 CLI 输出与写自身 kv | 安装即信任(Tern 插件模型),不扩大权限面 |
| NFR-8 资源 | 常驻内存增量 ≤ 数 MB;无窗口时 host 轮询继续(为状态栏和kv保数据新鲜) | kv 中缓存序列化后 < 1 MB |
| NFR-9 可维护 | 纯 Luau、`--!strict`;类型检查过 `tern.d.luau`;解析层无 tern 依赖可单测 | CI:`scripts/check.py`(luau-analyze)通过 |

## 6. 验收标准(首版)

1. 干净机器(已装 Tern + omp + 至少一个提供商登录)上,执行安装命令后 10 s 内,聚焦 omp 窗格出现用量线;全程未触碰 `~/.omp/agent/config.yml`。
2. Kimi(7d/5h)、Codex(5h/7d + ×N)、Claude(5h/wk/Fable)三种报告形态均正确渲染,Kimi 无重复窗口。
3. Alt+P 切换模型 → 线在 2 s 内跟随;查看子代理 → 显示子代理模型用量。
4. 悬停出卡片,内容与 jmazzola 对齐 + 今日 token/费用尾行。
5. 状态栏显示今日 token/费用胶囊,点击打开仪表盘,仪表盘有 7 天历史与费用。
6. 设置面板全部项即时生效,重启 Tern 后保留。
7. `tern plugin reload` 后设置与面板恢复;杀掉 omp 进程后线消失且无报错 toast 刷屏;恢复 omp 后自动回来。

## 7. 风险与开放问题

| # | 风险/问题 | 处置 |
|---|---|---|
| R1 | Tern 内部 CSS 类(`sf-*`/`tn-*`)与节点 id 无兼容承诺,版本升级可能破版 | 选择器集中管理;启动时探测 meter 节点是否存在,不存在则线不渲染并在卡片/日志说明;README 标注已验证版本 |
| R2 | omp CLI JSON schema 变化 | 解析层宽容(字段缺失跳过);README 标注已验证 omp 版本 |
| R3 | 无 omp 扩展后,无法拿到 omp 会话内 `ctx.models.list()`,极端自定义模型可能映射不到提供商 | 回退链:目录匹配 → 前缀启发 → 显示全部提供商(见 FR-4.2) |
| R4 | 轮询 `omp usage` 的提供商侧限流 | 默认 90 s + 退避;文档说明;`invalidate` 仅手动刷新使用 |
| R5 | 多 Tern 窗口时 window 半各自查树,host 半单一轮询,数据一致性 | host 为唯一数据生产者(写 kv),window 只读,kv 原子读写 |
| R6 | 今日统计依赖 `omp stats` 本机同步(stats.db 为空/未同步时恒为 0) | 文档说明;卡片尾行缺失时隐藏该行;后续可评估读 `~/.omp` 会话文件的替代方案(不承诺) |
| Q1 | 状态栏今日段是否需要在非 agent 窗格隐藏?(joaodutra88 为 agent 窗格聚焦时显示) | 待定:默认跟随焦点,设置可改为常显 |
| Q2 | 插件名/命令前缀:命令以 "omp Usage Plus:" 开头较长,是否用 "Usage+:"? | 待定 |
