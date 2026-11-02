# dora-tern-omp-usage

**Dora omp Usage** 是一款 [Tern](https://stencil.so/tern) 插件,把 omp 各家服务的订阅额度展示在输入栏上方的上下文用量条处,支持 omp 所有的提供商——Kimi、Codex、Claude、Gemini、MiniMax 等,并附带当日 token 用量与费用统计、近 7 天仪表盘和完善的设置界面。

一行命令即可安装,无需对 omp 做任何配置:

```sh
tern plugin install github.com/DoraJasmine/dora-tern-omp-usage
```

也可以在 Tern 的 **设置 › 插件 › Install…** 中粘贴上述地址。

![悬浮在用量线上方的卡片:各窗口计量器、重置倒计时,以及窗格所在主机的当日统计](docs/images/hover-card.png)

English: [README.en.md](README.en.md)

## 功能

- **额度展示**——聚焦 omp 窗格后,各家服务的 5 小时 / 7 天等窗口用量一目了然:填充条、剩余比例、重置倒计时,逐家配色;余量不足时自动转为琥珀色和红色。
- **悬浮卡片**——鼠标停在用量线上,即可查看各窗口的计量器、重置时间与已存重置的到期时间;卡片支持悬停停留,不会一闪而过。
- **模型跟随**——切换模型(Alt+P)后约两秒内,额度自动切换到对应的服务;查看子代理时亦然。
- **多主机**——远程主机(如 WSL、服务器)上的窗格展示该主机自己的数据,与本机互不干扰,全程自动完成。
- **当日统计**——状态栏常驻当日 token 用量与费用,点击可打开近 7 天仪表盘。
- **设置**——通过 `Ctrl+Alt+U` 或命令面板打开:显示模式、服务排序、逐家配色、阈值、用量与当日统计的刷新间隔、界面语言(English / 简体中文)等。

## 环境要求

- Tern 0.8 及以上(在 0.9.8 上验证,Windows 与 WSL)
- omp 18.9 及以上(在 18.14.1 上验证),并已登录至少一家有用量限额的服务
- 无需注册 omp 扩展,不改动任何 omp 配置文件

## 数据说明

- 额度数据来自 `omp usage --json`,omp 登录了哪些服务就展示哪些,新服务无需更新插件;
- 当日统计自当地零点起,覆盖所有服务,金额按 omp 模型目录中的 API 牌价折算——反映的是"若按 API 直连计费"的等效费用,并非订阅账单。

### 关于额度的更新时效

额度数字并非实时:omp 对上游用量报告维护约 **5 分钟**(±25% 抖动)的本地缓存,缓存期内再次查询返回同一份报告;缓存 TTL 由 omp 硬编码,不提供配置入口,因此插件无法(也不应)通过更频繁的轮询换取更新的数据。实际的数据延迟最坏约为"缓存有效期 + 插件刷新间隔"(默认 90 秒,可在设置中调整)。插件的「立即刷新」会调用 omp 官方的 `omp usage invalidate` 接口强制绕过缓存,是最快拿到最新额度的途径。详见[架构文档](docs/ARCHITECTURE.md)第 16 节。

## 相关文档

- [实现指南](docs/IMPLEMENTATION.md) —— 文件结构、数据流水线与常见修改
- [Tern API 使用说明](docs/API.md) —— 插件用到的每一个 Tern API
- [需求文档](docs/REQUIREMENTS.md) · [架构文档](docs/ARCHITECTURE.md)

## 致谢

- [jmazzola/tern-plugin-omp-usage](https://github.com/jmazzola/tern-plugin-omp-usage) —— 线条与卡片的渲染方案参考自此项目
- [joaodutra88/tern-omp-usage](https://github.com/joaodutra88/tern-omp-usage) —— 取数架构、状态栏与仪表盘的实现思路参考自此项目

## 许可

[MIT](LICENSE) © 2026 DoraJasmine,第三方组件声明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
