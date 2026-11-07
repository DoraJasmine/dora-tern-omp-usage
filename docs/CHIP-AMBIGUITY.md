# 同名模型身份：主会话桥已解决，子代理仍有边界

更新：2026-11-07，2.0.0。

## 问题与决策

composer 芯片只有显示名。同名、甚至相同 bare id 的模型可以属于不同提供商；目录首项不是当前选择。旧 first-hit 会把 Codex 选成自定义提供商，按额度、登录、默认 modelRoles 或历史消费排序则会把用户确实选择的自定义提供商压成 Codex。两者只是选错相反方向。**这些证据描述可用性或过去使用，不描述当前选择，因此不参与身份解析。** 不读取配置默认角色作为实时模型，不增加用户绑定或行为推断。

## 已采用的正式桥

随仓库分发 `omp/extensions/model-identity.js`，要求 omp ≥ 18.18.0。加载方式及 Windows/WSL/SSH 路径见 [README](../README.md#加载主会话身份扩展)；必须在每个运行 omp 的主机加载，不能只装在 Tern 所在 Windows 上。

扩展通过主会话生命周期安装 `belowEditor` widget，以隐藏原生文本节点 role `dora.omp.model-identity` 传输 JSON：

```json
{"version":1,"sessionId":"…","scope":"main","provider":"identity-alpha","id":"shared-model"}
```

组件的 `describe()` 调用实时 `ctx.models.current()` 和 session manager，不快照启动模型，不依赖不存在的公开 `model_changed` 扩展事件；无轮询、无文件写入、无可见 ANSI 行。仅主 TUI 会话安装；切换/分支/会话树操作重新安装，关闭清理。

## 解析与显示规则

- `lib/identity.luau` 统一读取 dock 与解析身份，窗口渲染和诊断使用同一结果。重复节点、截断树、非法 JSON、字段缺失或不支持的版本/scope 均不能当成桥缺失后猜测。
- 主会话有效桥以 provider/id 确定 selector；若目录有对应条目但显示名不符，暂不采用矛盾身份。
- **仅桥缺失**时允许目录回退。`parse.catalog()` v2 的 `by_name` 保留所有候选，`by_selector` 保留 provider/id，`by_provider` 维护提供商模型集合。显示名按 omp 规则去掉开头的 `Claude `；只接受唯一精确显示名候选，不做大小写/id 子串、前缀启发或首项选择。
- 当前模式未解析时显示待确认与悬停帮助；解析到自身提供商但没有额度或今日消费时显示自身无数据提示，绝不显示另一家的额度。全部/已选模式保持既有行为。
- 诊断提供桥状态、解析状态/来源/原因及身份上下文；刷新身份变化按 pane、host、session、selector 跟踪，不只按芯片字符串。

## 明确限制

**子代理：** 主桥只声明 `scope: main`。查看子代理时即使桥有效也不代表子代理；仅其芯片的唯一精确目录候选可解析，重名则待确认。当前没有正式子代理身份桥，不能声称所有子代理均精确跟随。

**时延：** 身份随原生描述与窗口约 100ms 的 surface 读取更新，无需发送消息。切换先画对应供应商缓存，再由宿主每 250ms 接收后台刷新请求；不保证固定端到端时延。桥/芯片短暂不一致时宁可待确认。额度仍受上游响应、omp 缓存与数据快照周期约束，身份刷新不等于额度实时。

**部署：** Tern 一行安装提供 CLI 采集与显示，但不自动配置 omp 扩展。缺桥的重名模型无法精确识别；旧版 Tern 原生隐藏节点兼容性尚未验证。

## 已验证证据（不是全平台保证）

隔离 headless **Tern 0.9.12 / WSL omp 18.18.0**：配置 `identity-alpha`、`identity-beta`，二者显示名均为 `Identity Shared Model`，bare id 均为 `shared-model`。通过实际 **Alt+P** picker 从 alpha 切换到 beta，未发送消息，同一 sessionId 下隐藏节点 provider 随选择变化；节点可从 dock surface 读取。与未加载扩展的基线比较，模型芯片几何完全一致。未修改用户配置。

`tests/identity.luau` 和 `tests/line.luau` 均已通过 Windows 与 WSL Tern Luau 的 loadstring/module loader 执行,集成 Lua 文件已完成语法编译,JS 扩展通过 `node --check`。Windows omp 18.18.0 还验证了真实 picker 同名切换、两个 pane 各持不同供应商且 sessionId 不同、`/new` 后 sessionId 更新。实际缺扩展 pane 显示 `Provider pending`,悬停显示中文安装帮助;WSL 实际界面验证了自身无数据不展示另一家消费。额度/消费数值在视觉场景中使用确定性 fixture,不是上游额度实时性验证。

缓存迁移烟测用真实 `omp stats --json` 经过正式 fetch handler:旧记录在读取时被拒绝,旧小写账本/基线成对替换为 v2,供应商合计与今日总量一致。临时测试键已清除,用户配置未改动。没有配置可用的 SSH 测试主机,SSH 运行和真实子代理焦点切换尚未验证;子代理主身份拒用已由回归场景覆盖。

自动重试 fallback 也已在真实 Windows omp 路径验证:仅访问本机 HTTP fixture,alpha 返回 503,beta 返回合法 SSE 完成响应。omp 实际报告 fallback applied/succeeded,隐藏节点在同一 sessionId 下更新为 beta,无需扩展事件订阅或额外轮询。此项验证身份跟随自动切换,不代表真实供应商可用性测试。

切换延迟优化另在明确加载插件的隔离 headless Tern 0.9.12 与 omp 18.18.0 验证：Windows、WSL 各 4 次真实 picker 切换同名同 id 的 Codex/LeimuGPT，点击选择至观察到对应缓存额度条分别为 91–211ms、144–203ms。确认了实际额度条画面；此为本机样本，非跨平台时延承诺。现有身份与供应商隔离 Luau 回归均通过。
