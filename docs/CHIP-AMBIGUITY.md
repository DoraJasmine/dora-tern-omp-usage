# 芯片重名消歧问题（未解决，交接文档）

> 状态：**未解决**。本文档记录问题的完整根因、已尝试并回退的三种方案、真实数据形状和可行的解决方向。
> 接手者请先读完「根因」和「为什么无解」，再看「解决方向」。
> 最后更新：2026-11-07（对应 main = `3cf89c1`，该提交之后的两轮消歧尝试均已回退）。

## 一、问题现象

omp composer 的模型芯片（dock 上的显示名）只携带**显示名**，例如 `GPT-6.1 Sol`。当**多个提供商**的模型目录里存在**同名模型**时（本例：自定义提供商 `leimugpt` 与内置 `openai-codex` 都有一个名为 "GPT-6.1 Sol" 的模型），插件无法从芯片字符串判断用户选中的是哪一家的。显示结果必然二选一，且两个方向都已实测翻车：

| 版本 | 行为 | 用户视角 |
|---|---|---|
| v1.3.3（first-hit） | 选中 Codex 的 GPT-6.1 Sol → 显示 `Leimugpt TODAY 3 $0.00` | 选了正经套餐却显示空壳自定义商 ❌ |
| `b65e518`（证据排序，**已回退**） | 选中 **Leimugpt** 的 GPT-6.1 Sol → 显示 `Codex 5H/7D 额度条` | 选了自定义商却被证据压成 Codex ❌ |

**这是同一个硬币的两面**：芯片字符串无法区分两个同名模型，任何"自动挑一个"的规则都会在某个方向上出错。

## 二、根因链条

代码涉及四个文件：`window.luau`（读 dock）、`lib/parse.luau`（目录/配置解析）、`lib/fetch.luau`（拉取通道）、`lib/line.luau`（芯片→提供商解析与渲染）。

1. **dock 芯片只有显示名**。`window.luau` 的 `read_dock` → `dock_chip` 从 surface 树的 `MODEL_ROLE` 节点下取 `NAME_SUFFIX` 节点的第一个文本 span，得到 `"GPT-6.1 Sol"`。**Tern 的 surface API 是否暴露更多（selector、tooltip、模型 id）尚未探明**——这是最值得先查的方向。
2. **目录索引先到先得**。`lib/parse.luau` 的 `catalog()`：

   ```lua
   if name ~= "" and by_name[name] == nil then
       by_name[name] = entry
   end
   ```

   `omp models --json` 里 leimugpt 排在前面，`by_name["GPT-6.1 Sol"]` 从此只指向 leimugpt，codex 的同名条目在该索引中**不存在**（`by_selector` 里两者都在，键是各自的 selector）。
3. **解析层没有消歧**。`lib/line.luau` 的 `build()` 用 `by_name[data.chip]` 一查即得，selected 错误条目后不再看第二个候选。
4. **"无数据"判定会被账本痕迹骗过**。`build()` 的 `seen` 集合包含"今日账本有消费"的提供商。leimugpt 曾跑过 3 token（$0.00），于是 `seen["leimugpt"] = true`——任何"提供商没数据就换一个"的启发式在此失效。

## 三、真实数据形状（2026-11-07 从 WSL 实测）

**`omp models --json`**（同名条目并存，各带 provider/id/name/selector）：

```json
{ "provider": "leimugpt",      "id": "gpt-6.1-sol", "name": "GPT-6.1 Sol", "selector": "leimugpt/gpt-6.1-sol" }
{ "provider": "openai-codex",  "id": "gpt-6.1-sol", "name": "GPT-6.1 Sol", "selector": "openai-codex/gpt-6.1-sol" }
```

注意：**两家的 bare id 也完全相同**（`gpt-6.1-sol`），id 也不能用来消歧。

**`omp config list --json`**（modelRoles 是完整 selector，自带 provider 前缀）：

```json
"modelRoles": { "value": { "default": "openai-codex/gpt-6.1-sol:high" }, "type": "record" }
```

它反映的是**配置的默认角色**，composer 里临时切换模型不保证写回（omp 行为未验证）。格式：`"provider/model[:effort]"`。

**`omp stats --json` 的 `byModel`**（模型→提供商的用量证据）：

```json
{ "model": "gpt-6.1-sol", "provider": "openai-codex", "totalRequests": 11, "totalCost": ..., ... }
```

**`omp usage --json`**：`reports[].provider` + `capacity` 键给出"哪些提供商有额度窗数据"（本例只有 `kimi-code`、`openai-codex`）。

## 四、已尝试并回退的方案

### 方案 1：v1.3.3 的 first-hit（现状）

`by_name[data.chip]` 直接取。重名时取到目录序靠前的那个。→ 方向一翻车（选 Codex 显示 Leimugpt）。

### 方案 2：commit `c5fa992`（2026-11-06，已从 main 丢弃，reflog 可查）

思路：解析到的提供商**完全没有数据**时，去 `by_selector` 里找同名、且有数据的候选替换。
失败原因：触发条件是 `not seen[provider]`，而 `seen` 包含账本痕迹——leimugpt 的 3 token 使 `seen["leimugpt"]=true`，条件永不成立，**修了个寂寞**。此提交还顺带在 `provider_windows` 里给容量窗口硬编码 `scope_shared = true`（另一处争议，一并被否）。

### 方案 3：commit `b65e518` + `bb857d7`（2026-11-07，已回退，本文档写作时的直接前身）

思路：收集**全部**同名候选（`by_selector` 全量 + `by_name` 命中，按 provider+id 去重；精确名/忽略大小写/id 子串三级匹配），按证据强度排序取最强：

```
modelRoles selector 点名(5) > 额度窗口(4) > byModel 归属(3) > 内置 ORDER(2) > 账本痕迹(1) > 无(0)
```

为此新增了 `config` 拉取通道（15 分钟 TTL，解析 `modelRoles.value` 的 selector 为 `{provider, id}` 对）和 byModel 的 `model→provider` 映射保留。用真实数据仿真验证过四个芯片全部解析正确（GPT-6.1 Sol → openai-codex；Kimi/DeepSeek 芯片不受影响；单候选纯消费商不要求证据）。
**被否的根本原因**：排序是"谁证据强选谁"，用户**真心选中 leimugpt 的同名模型**时，leimugpt 拿不到任何强证据，必然显示成 codex。方案 1 与方案 3 只是选错了相反的两边。

结论：**在"只有显示名"这个前提下，本问题在显示层无解**。出路只能是拿到更精确的信号（见下）或让用户显式指定。

## 五、解决方向（按性价比排序，供接手者评估）

1. **查 Tern surface API 能给什么**（首选，成本最低收益最大）。`cx.session:surface(pane, { root = "dock" })` 返回的树里，`MODEL_ROLE` 节点及其子节点除显示名外还有什么属性？tooltip、aria、自定义 data、模型 selector……如果任何一个字段携带 selector 或 provider，问题直接终结。`tern.d.luau`（类型声明）和 Tern 源码是入口。`dock_chip` 现在只挖了 name span，值得把整棵 dock 子树 dump 出来看看。
2. **查 omp 是否有"当前会话活跃模型"的 CLI**。例如 `omp status`、`omp session`、`omp config get modelRoles` 之类。注意区分"配置默认"与"composer 当前选中"。若 omp 能答"当前选中 = openai-codex/gpt-6.1-sol:high"，同样直接终结。
3. **用户显式绑定**（保底，一定能用）。设置里加一张 `芯片名 → 提供商` 的映射表（"当芯片为 GPT-6.1 Sol 时按 leimugpt 处理"），存 settings，`build()` 排序前先查表，命中即用。无歧义时不要求配置。缺点是要用户动手，但语义 100% 准确。
4. **行为推断**。切换芯片后观察接下来一个 stats 周期内哪家的 byModel/today 增长了，把下一次解析偏向它。缺点：慢（要等一个周期）、双在同用时抖动，只适合做加分项，不适合做主判据。
5. **上游协作**。请 omp 在 dock 芯片的可读属性里带 selector，或显示 provider 消歧。周期长，但根治。

## 六、代码落点与约束

- 芯片解析：`lib/line.luau` `build()` 开头的 chip 块（v1.3.3 现状：`by_name` 直查 + 忽略大小写/id 子串模糊回退 + `parse.provider_hint` 兜底）。
- 目录解析：`lib/parse.luau` `catalog()`（`by_name` 先到先得、`by_selector` 键为 selector、`by_provider` 每提供商的 id 列表）。
- 拉取通道：`lib/fetch.luau`（`argv_for`/`interval_for`/`handle`/`service`，kind→子命令映射；注意本地 spawn 的 argv 数组**不拆空格**，`"config list"` 必须拆成两个元素——`b65e518` 里踩过）。
- 数据管线：`window.luau` `data_for()` 组装 `{usage, models, today}` 传给 `line.build`，新数据源在此挂载；`read_dock`/`dock_chip` 是 dock 树的读取点。
- 约束：window 线程 50ms 预算（chrome 格式化器 4ms）；kv 键约定 `<kind>@<source>`；守护与窗口两半都会调 `service()`，靠 `fetch_lock@<source>` 防重；强制拉取走 `omp usage invalidate` 先行。

## 七、复现步骤

1. omp 配置两个提供商：内置 `openai-codex`（已登录，有额度窗）+ 自定义 `leimugpt`（转发站），两者都有名为 "GPT-6.1 Sol" 的模型（id 同为 `gpt-6.1-sol`）。
2. composer 选中 GPT-6.1 Sol。
3. 观察插件状态行/悬浮卡显示的是哪家的数据；再切换到另一家的同名模型（如有入口），观察显示是否跟随。
