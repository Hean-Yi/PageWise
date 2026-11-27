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

读到论文一半，你在页边记下一个疑问。几周后读到另一篇，你依然能找回当时那句话，对照两次实验条件，把新的判断写进笔记。PageWise 把**英文原文、中文双语重排、可追溯出处的 AI 助读、页边 Markdown/LaTeX 笔记与本地研究记忆**放在同一座书架上。

## 核心能力

| 使用场景 | 在 PageWise 里的体验 |
| --- | --- |
| **找论文与封面预览** | 拖入本地 PDF，或在书架同时检索 arXiv、Crossref、DBLP，有开放全文时一键导入；按主题书架归类。Mac 指针停在封面上按住空格即可预览摘要与精读概括。 |
| **原版与双语重排** | 本地 PDF 按自然段重排并优先翻译当前页，图表与可选表格随正文展示；在线 arXiv 论文优先解析同版 TeX / HTML。原始 PDF 永不覆盖，随时切回核对原貌。 |
| **划线与页边笔记** | 拖选中英文句子自动弹出批注浮层，一键高亮、下划线或添加笔记，支持实时 Markdown、LaTeX 公式与跨论文笔记引用；收起侧栏后以手绘波浪线提示，悬停即可原句轻浮、虚线相连并展开预览。 |
| **AI 精读与双助理** | 「论文助读」提供五色分类批注、文末总结与可定位出处的划词问答；「书库助理」支持跨论文查笔记、推荐相关工作与整理书架；回答可实时展示模型思考过程。 |
| **本地语义检索与研究记忆** | 随包内置约 61 MB 的 4-bit Core ML 中英语义模型，启动即搜、后台完成向量索引，离线也能跨语言召回笔记与记忆；两处助理共用回答习惯，长期记忆可随时修改或删除。 |
| **导出笔记与阅读日历** | 「阅读笔记」按论文收拢文末总结与页边批注，点击正文即原地编辑；支持手动触发「整理到 Obsidian」并保留手写区；「阅读日历」自动合并当日阅读时长。 |

## 三步上手

1. **打开内置示例**：下载 DMG 后将 **PageWise** 拖入「应用程序」。首次打开空书库时，点击 6 步快速上手中的 **「直接试读示例」**，即可离线阅读随包附带的两页示例论文 *When the Average Misleads*。
2. **划线、记笔记与悬停预览**：拖选任意句子，在浮层中选择颜色或点 **「添加笔记」** 写下想法（支持 Markdown 与 `$公式$`）。切到「双语重排」并收起侧栏后，把指针停在波浪线原句或页边卡片上即可体验悬停展开预览。
3. **按需配置模型服务**：需要中文翻译、AI 精读或助理问答时，在 **「设置 → 模型服务」** 选择服务商（内置 OpenAI、Claude、Gemini、DeepSeek、千问、Kimi、GLM、Mistral、Grok、豆包与自定义兼容接口）并保存自己的 API 密钥。

> 随时可通过菜单栏 **「帮助 → 快速上手」** 或设置页重看引导。Mac 试用包使用本地签名、尚未经过 Apple 公证；下载后可在发布页核对 SHA-256，首次打开请参照 [Apple 打开未公证应用说明](https://support.apple.com/zh-cn/102445)。

## 隐私与边界

- **完全本地运行**：论文副本、SQLite 书库、批注、检索索引与 4-bit 语义模型均存在本机；Mac 与 iPad 独立工作，不依赖自建后端或 Python 服务。
- **密钥不离设备**：API 密钥按服务地址存入设备钥匙串（Keychain），绝不写入 Git、日志、提示词或导出的笔记。
- **联网与导出均透明**：仅在用户发起翻译、助读、在线检索或开启空闲整理时向所选服务发送必要上下文；Obsidian 写入仅由用户点击触发，不会覆盖手写内容。
- **当前未接入**：扫描件 OCR、HTML 手写与 iCloud 跨设备自动同步尚未接入，详见 [阅读指南 · 当前边界](docs/reader-guide.md#当前边界)。

## 从源码构建

需要 Xcode（Swift 6 / macOS 15+ / iPadOS 18+）。打开 `PaperReader.xcodeproj` 可选择 `PaperReader`（Mac）或 `PaperReader-iPad` scheme：

```sh
bash scripts/run-mac.sh       # 构建并启动 Mac 调试版
bash scripts/check.sh         # 格式检查、自动化测试、离线冒烟与 Mac/iPad 构建
bash scripts/package-mac.sh   # 打包通用 Release DMG 与 SHA-256（输出至 Artifacts/）
```

> 可通过 `PAPERREADER_DATA_DIR` 指定独立测试书库；修改 `project.yml` 后用 `xcodegen generate` 重新生成工程。

## 文档索引

| 文档 | 适合谁看 | 内容简介 |
| --- | --- | --- |
| [阅读指南](docs/reader-guide.md) | 读者 / 使用者 | 导入、双语重排、页边笔记、AI 精读、书库助理与 Obsidian 导出指南 |
| [产品需求](docs/requirements.md) | 产品 / 开发者 | 按功能域整理的已确认需求、交互细节与产品不变量 |
| [研究记忆设计](docs/agent-memory.md) | 开发者 / 深度用户 | 长期记忆、空闲整理、静默笔记修订、24 个 Agent 工具与本地语义检索实测 |
| [工程结构](docs/architecture.md) | 开发者 | 模块分层、目录归属、数据库迁移与平台桥接说明 |
| [工程规范](docs/engineering.md) | 开发者 | Swift 6 并发、测试门槛、文档同步与 Git 提交流程 |
| [技术现状](docs/technology.md) | 开发者 | 实际使用的框架、本地检索底座与尚未接入的能力边界 |
| [验证记录](docs/mvp-status.md) | 维护者 / 验收者 | 各版本实测结果、性能数据与未覆盖边界 |
| [精读笔记提示词](Sources/PaperReaderKit/Resources/Prompts/CloseReadingNotebook.md) | 开发者 / 读者 | AI 文末精读笔记的写作结构与引文规范 |
