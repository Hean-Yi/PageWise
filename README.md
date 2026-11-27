<div align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/Mac-256.png" width="108" alt="PageWise 书本图标">
  <h1>PageWise</h1>
  <p><strong>本地优先的学术论文双语阅读、页边笔记与研究记忆工作台</strong></p>
  <p>
    <code>v0.4.0</code> ·
    <code>macOS 15+ (Apple Silicon &amp; Intel)</code> ·
    <code>iPadOS 18+</code> ·
    <code>Swift 6</code> ·
    <code>Local-First</code>
  </p>
  <p>
    <a href="https://github.com/Hean-Yi/PageWise/releases/latest"><strong>下载 Mac 版</strong></a> ·
    <a href="docs/reader-guide.md">阅读指南</a> ·
    <a href="docs/agent-memory.md">研究记忆</a> ·
    <a href="docs/architecture.md">工程结构</a> ·
    <a href="docs/mvp-status.md">验证记录</a>
  </p>
</div>

---

一本论文读到一半，你在页边留下一个问题。几周后读到另一篇，你依然能回到当时那句话，对照两次实验条件，把新的判断写回笔记。PageWise 把**英文论文、中文双语重排、可回溯出处的 AI 助读、页边 Markdown/LaTeX 笔记与设备端研究记忆**安放在同一座本地书架上。

## 核心特性

| 能力 | 在 PageWise 中的体验 |
| --- | --- |
| **多源找论文与封面预览** | 拖入本地 PDF，或在书架并行检索 arXiv、Crossref、DBLP，开放全文一键下载入库；按主题书架整理。Mac 指针停在封面上按住空格即可预览摘要与精读概括。 |
| **原版与双语重排无缝切换** | 本地 PDF 按自然段重排并优先翻译当前页，图表与可选表格随正文呈现；在线 arXiv 论文优先解析同版 TeX / HTML。原始 PDF 永不覆盖，随时核对出版原貌。 |
| **页边笔记与悬停联动** | 拖选中英文句子即弹出批注菜单，支持分色高亮、下划线与实时 Markdown / LaTeX 笔记；收起侧栏后以手绘波浪线提示，鼠标悬停即原句轻浮、虚线相连并展开卡片预览。 |
| **AI 精读与双入口科研助理** | 「论文助读」提供五色分维 AI 精读、文末笔记与可定位出处的划词问答；「书库助理」跨论文检索笔记、推荐相关工作与整理书架；支持实时展示模型思考过程。 |
| **内置 4-bit 本地语义检索与研究记忆** | 随包内置约 61 MB 的 4-bit Core ML 中英语义模型，结合 SQLite FTS5 与渐进式冷启动，离线即可跨语言召回笔记与记忆；两处助理共用回答习惯与可编辑、可撤回的长期研究记忆。 |
| **带走你的笔记与阅读记录** | 「阅读笔记」按论文汇总文末总结与页边批注，点击正文即原地编辑；支持用户主动触发「整理到 Obsidian」并保留手写区；「阅读日历」自动合并当日阅读时长。 |

## 三步开始使用

1. **打开内置示例**：安装后将 **PageWise** 拖入「应用程序」。首次打开空书库时，点击 6 步快速上手中的 **「直接试读示例」**，即可离线打开内置两页教学论文 *When the Average Misleads*。
2. **划线、写笔记与悬停预览**：拖选任意句子，在弹出的批注浮层中选择高亮/下划线或点击 **「添加笔记」**（支持实时 Markdown、LaTeX 公式与跨论文笔记引用）。切换双语重排并收起侧栏后，将指针悬停在波浪线原句或页边卡片上即可预览完整笔记。
3. **按需连接模型服务**：若需双语翻译、AI 精读或助理问答，在 **「设置 → 模型服务」** 选择预设服务商（支持 OpenAI、Claude、Gemini、DeepSeek、千问、Kimi、GLM、Mistral、Grok、豆包及自定义兼容接口）并保存自己的 API 密钥。

> 「帮助 → 快速上手」和应用内设置可随时重看 6 步引导。Mac 试用包采用本地签名，尚未经过 Apple 公证；可在发布页核对 SHA-256，首次打开请参照 [Apple 打开未公证应用说明](https://support.apple.com/zh-cn/102445)。

## 隐私与本地数据边界

- **本地优先**：论文副本、SQLite 书库、批注、检索索引与 4-bit 语义模型均保存在设备本地；Mac 与 iPad 各自独立运行，不依赖自建服务器或常驻后台服务。
- **密钥隔离**：API 密钥按服务地址单独存入设备钥匙串（Keychain），不写入 Git、日志、导出笔记或普通同步数据。
- **按需联网与显式导出**：仅在用户发起翻译、助读、在线检索或启用空闲整理时，将必要的原文/上下文发送至用户配置的模型或学术索引服务；Obsidian 导出仅在用户主动点击时执行，且保留手写内容。
- **当前边界**：扫描件 OCR、HTML 手写与跨设备 iCloud 自动同步尚未接入，详见[阅读指南 · 当前边界](docs/reader-guide.md#当前边界)。

## 从源码构建与检查

需要安装 Xcode（工具链基准：Swift 6 / macOS 15+ / iPadOS 18+）。打开 `PaperReader.xcodeproj` 可选择 `PaperReader`（Mac）或 `PaperReader-iPad` scheme：

```sh
bash scripts/run-mac.sh       # 构建并启动 Mac 调试版
bash scripts/check.sh         # 严格格式检查、全量测试、离线冒烟与 Mac/iPad 构建
bash scripts/package-mac.sh   # 构建通用 Release DMG 安装包及 SHA-256（输出至 Artifacts/）
```

> 隔离验收可通过环境变量 `PAPERREADER_DATA_DIR` 指定独立书库目录；修改 `project.yml` 后使用 `xcodegen generate` 重新生成 Xcode 工程。

## 文档导航

| 文档 | 内容说明 |
| --- | --- |
| [阅读指南](docs/reader-guide.md) | 从导入、双语重排、页边笔记、AI 精读到 Obsidian 导出的完整使用说明 |
| [研究记忆设计](docs/agent-memory.md) | 长期记忆来源、空闲整理、静默笔记修订、24 个 Agent 工具与语义召回实测 |
| [已确认需求](docs/requirements.md) | 产品范围、交互细则与数据不变量 |
| [工程结构](docs/architecture.md) | Target 分层、目录归属、存储迁移与渲染桥接 |
| [代码与工程规范](docs/engineering.md) | Swift 6 并发约束、测试门槛与交付约定 |
| [技术现状](docs/technology.md) | 实际使用的框架、本地检索组件与尚未接入的边界 |
| [验证记录](docs/mvp-status.md) | 各版本实测记录、回归覆盖范围与未覆盖边界 |
| [精读笔记提示词](Sources/PaperReaderKit/Resources/Prompts/CloseReadingNotebook.md) | 文末精读笔记的写作结构与引文规范 |
