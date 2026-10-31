# dora-tern-omp-usage

**omp Usage Plus** —— 在 [Tern](https://stencil.so/tern) 中,把你的 omp 用量额度显示在 omp 输入栏上下文指示条的
正上方,**支持 omp 报告的所有提供商**(Kimi、Codex、Claude、Gemini、MiniMax……),并附带今日 token 用量与
API 等效费用(含按提供商分解)、7 天仪表盘和图形化设置。

**一行安装,零 omp 配置。**

```sh
tern plugin install github.com/DoraJasmine/dora-tern-omp-usage
```

或在 Tern 的 **设置 › 插件 › Install…** 中粘贴同一地址。

English readme: [README.md](README.md)

## 环境要求

- Tern 0.8+(实测 0.9.8,Windows 与 WSL)
- [omp](https://omp.sh) 18.9+(实测 18.14.1),已登录至少一个有用量限额的提供商
- 不需要 omp 扩展、不改 `config.yml`、不用重启 —— 装完即用

## 功能一览

- **用量线**:聚焦的 omp 窗格上下文栏正上方,按窗口(5h/7d/…)显示填充条、剩余比例、重置倒计时与已存重置,
  逐提供商配色(剩余 ≤25% 琥珀色,≤10% 红色)。
- **悬停卡片**:逐窗口计量器、重置时间与时钟时间、已存重置的到期时间、今日总量与按提供商分解、设置入口。
  鼠标移到卡片上不会消失(0.5s 宽限期)。
- **模型跟随**:Alt+P 切换模型后约 2 秒内跟随当前提供商;查看子代理转录时跟随子代理的模型。
- **按主机显示数据**:远程主机(WSL、服务器)上的窗格显示**那台主机**登录账号的额度与统计;本机窗格显示本机数据。
  全自动 —— 插件会在远程主机上开一个小的数据块并立即驻留(park),不占标签页。
- **状态栏**:🔥 今日 token 数、💸 今日 API 等效费用(跟随焦点窗格所在主机)。
- **仪表盘**:近 7 天用量历史 + 今日/近 7 天/本月费用(`r` 刷新)。
- **设置**(`Ctrl+Alt+U`、状态栏 `用量` 段、或命令面板):显示模式(当前模型/全部/勾选)、提供商排序、
  逐提供商配色、阈值、刷新间隔、状态栏开关、界面语言(English / 简体中文)。

## 数字是怎么算的

- **额度**来自 `omp usage --json` —— 账号级数据,omp 登录了什么就显示什么,新提供商零代码接入。
- **今日**把 `omp stats --json` 的小时桶从当地零点起求和;按提供商分解聚合自 `byModel`
  (input + output + cache,与总量同口径)。
- **价格**来自 omp 的模型目录(`omp models --json`):各模型 input/output/cacheRead/cacheWrite 的
  API 列表价(USD / 每百万 tokens)。因此金额是 **API 等效费用**(这些用量若按 API 直连要花多少),
  不是订阅账单。

## 多主机

Tern 的窗口可以显示所有已连接主机的窗格,而插件的 window 半运行在窗口所在机器。本插件用文档支持的方式打通:
每台主机的 host 半渲染一个极小的 `sync` 数据块(内容为本机数据的 JSON 文本),窗口读取所有能看到的 sync 块
(`cx.session:read`),并用 `cx.hosts:list()` 把窗格映射到主机。当你在远程主机上工作时数据块自动开启,
并立即驻流出标签栏。

## 开发

```sh
git clone https://github.com/DoraJasmine/dora-tern-omp-usage
tern plugin link ./dora-tern-omp-usage   # 链接你的检出
tern plugin reload dora-tern-omp-usage   # 改代码后
tern plugin types ./dora-tern-omp-usage  # 重新生成 tern.d.luau 供 luau-lsp 使用
```

`docs/` 里是中文的需求文档与架构文档,含多主机语义及本插件依赖的全部 Tern API。

## 致谢

- [jmazzola/tern-plugin-omp-usage](https://github.com/jmazzola/tern-plugin-omp-usage)(MIT)——
  本插件线条与卡片的渲染技术(输入栏计量器的 `::before` content + 单层 `background-clip: text` 渐变)改写自此项目。
- [joaodutra88/tern-omp-usage](https://github.com/joaodutra88/tern-omp-usage)(MIT)——
  纯 Tern 插件的取数架构、状态栏分段、仪表盘块与逐日统计累计,本项目将其扩展到所有提供商与所有主机。

## 许可

[MIT](LICENSE) © 2026 DoraJasmine
