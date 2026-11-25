# 工程结构与文件归属

本项目按职责组织物理目录，保留 `PaperReaderKit`、`PaperReaderUI` 和 `ReaderSmoke` 三个产品。目录用于定位和约束职责；只有 Swift Package target 才是编译边界。当前不把每个功能拆成独立 package，避免在 MVP 阶段引入额外装配成本。

## 目录导航

```text
App/
Sources/
|-- CSQLite/
|-- PaperReaderKit/
|   |-- Domain/
|   |-- Application/
|   |-- Infrastructure/
|   `-- Samples/
|-- PaperReaderUI/
|   |-- Application/
|   |-- Features/
|   |-- Platform/
|   `-- DesignSystem/
`-- ReaderSmoke/
Tests/
|-- PaperReaderKitTests/
`-- PaperReaderWorkflowTests/
scripts/
docs/
```

| 路径 | 负责内容 | 不应放入 |
| --- | --- | --- |
| `App/` | 应用入口、Info.plist、签名权限 | 业务实现、功能页面 |
| `PaperReaderKit/Domain/` | 论文、阅读、书架、助读等模型及纯业务规则 | SwiftUI、PDFKit、数据库与网络调用 |
| `PaperReaderKit/Application/` | 检索等依赖领域对象的用例计算 | 视图、平台控件 |
| `PaperReaderKit/Infrastructure/` | PDF 处理、SQLite、模型协议、在线检索、配置与 Obsidian 适配 | 页面布局与交互状态 |
| `PaperReaderKit/Samples/` | 应用内原创教学 PDF 生成器 | 用户论文与外部版权资料 |
| `PaperReaderUI/Application/` | ReaderModel 共享状态和用例协调：导入、保存、导航、阅读、助读等 | 具体 View 布局、原生控件实现 |
| `PaperReaderUI/Features/` | 按功能聚合的页面、视图组件与功能控制器 | 数据库操作、模型 HTTP 请求 |
| `PaperReaderUI/Platform/` | AppKit、UIKit、PDFKit 的视图桥接与原生拖放 | 领域排序规则、存储迁移 |
| `PaperReaderUI/DesignSystem/` | 主题、基础视觉与共享插图 | 业务流程与 API 配置 |
| `CSQLite/` | SQLite C 模块桥接 | Swift 业务逻辑 |
| `ReaderSmoke/` | 独立、离线的端到端冒烟入口 | 正式应用代码 |

表内省略 `Sources/` 前缀。`Features` 以 Library、Reader、Agent、Discovery、Calendar、Memory、Settings 分组；`Domain` 以 Library、Papers、Reading、Assistant、Settings、Common 分组。同一业务的页面与流程可能分别位于 Features 和 Application，这是展示与协调的边界。

## 依赖与共享状态

```text
App -> PaperReaderUI -> PaperReaderKit -> CSQLite

Features -> Application -> Domain + Infrastructure
Platform -> shared feature state + Domain
DesignSystem -> SwiftUI
```

`ReaderModel` 仍是应用共享状态和依赖的装配点，相关操作通过扩展分文件组织；它的数据库写入继续使用原有串行保存队列。`LibraryAgent`、在线查找与拖动状态控制器服务于各自功能，不因同属 UI target 就混入主题或平台代码。

SQLite 格式 v2 的 `LibraryStore` 在一次事务内将旧版整库 JSON 转为记录表。论文、笔记、标注、对话、记忆、阅读事件、书签以及每篇的阅读状态独立保存，各有序集合单独保存 ID 顺序。书架归属、手动排序与目录设置由 `LibraryStore.Catalog` 保存。新增持久化字段时，需明确归入目录或 `LibraryRecords` 并验证旧库升级。应用保存队列在前次写入后取最新内存状态，数据库仅编码变更记录。另一实例已提交更新时，版本检查会阻止陈旧快照覆盖。整篇重排发布仍以单篇论文为写入单位。

研究记忆使用同一书库的持久化与变更校验。`ResearchMemory` 管理与提问相关的个人关注，`ReadingNoteMemoryIndex` 返回可核对的笔记片段，`ResearchBriefIndex` 在设备端整理题名与跨论文证据。`ChatSourceVersions` 记录新回答和派生笔记所用的背景。书库 Agent 通过工具读取这些投影，写入研究问题时仍由应用检查来源、修订和去重。

研究来源变更在主库事务内写入 `research_events`，并推进独立的 `research_generation`。事件只含稳定 ID、修订哈希和归属，不含正文；阅读位置、翻译与工作区保存不生成事件。`research_index_state` 记录事件水位与最近核对时间，`research_maintenance_lease` 限制同一本地库的并发整理。`ResearchBriefIndex` 只在有待处理事件、来源代次变化或需要审计时重建，并把简报与水位原子发布；`research_brief` 或水位表损坏时从主库重建。

`DeviceSemanticEncoder` 管理按需下载的 Core ML 模型，`SemanticPassageIndex` 用稳定来源和内容指纹维护派生向量。明确的回答习惯经 `ReaderPreference` 确定作用域。`MemorySleepSession` 在空闲时调用书库配置的模型，`MemorySleepStore` 核验变更并原子更新同库 `memory_sleep` 表。书库工具和两处对话复用 `effectiveSleepMemory`，历史重放同时检查来源和当时生效的记忆版本。

上述内部依赖是工程约定，并非已经由独立 target 强制隔离。新增代码应沿此方向组织；发现跨层依赖时优先拆清职责，再考虑是否需要新的编译边界。

## 新文件放在哪里

1. 先判断是业务规则、外部适配、应用协调、功能展示还是平台桥接，再选目录。
2. 一个文件围绕一个主要类型或紧密相关的一组类型；文件名表达职责。小型私有视图与其页面可以同文件，跨业务声明应拆开。
3. 不向 `PaperReaderUI/` 或 `PaperReaderKit/` 根目录追加 Swift 文件，不重建通用 `Models.swift`、`Utils.swift` 或无边界的 `Services/` 收纳目录。
4. 平台专有控件放 `Platform/macOS` 或 `Platform/iPadOS`；两端共用 PDF 画布放 `Platform/PDF`。纯拖动状态与引用格式留在书库功能目录。
5. 仅被一个功能使用的组件留在该功能；确认多个功能复用的视觉才进入 DesignSystem。不要因命名方便提前抽成共享层。
6. 公共假服务和测试辅助代码放对应测试 target 的 Support；单个测试文件私有辅助保留在文件内。测试文件按领域、适配器或工作流归类，跨功能链路明确归 Integration。

## 构建与资源规则

Swift Package 自动递归发现每个 target 目录下的 Swift 文件。当前 Xcode 工程依赖本地 Package，只显式管理 `App/`；这次目录整理不需要重新生成工程或修改产品名、签名权限和 deployment target。

运行 `bash scripts/check.sh` 会递归检查格式，并执行测试、冒烟与 Mac/iPad 构建。搬移时还需核对公开符号和测试清单，避免仅因为编译成功而漏掉未被编译的文件。

`.build/`、`.local/`、构建结果、验收样例及日志属于忽略的本地制品。用户资料不参与目录整理。历史设计记录保存在本地。当前工程文档从 README、本文和 engineering.md 进入。

## 阅读生成与文件归属

| 路径 | 职责 |
| --- | --- |
| `Infrastructure/PDF/Import/PDFImporter` | 校验并保存原始 PDF，计算哈希和轻量元信息 |
| `Infrastructure/PDF/{Display,Navigation}` | 原版与历史固定页的展示、目录、定位，按页提取带原文范围和行框的句子 |
| `Infrastructure/PDF/Navigation/PDFIllustratedPage` | 按原页题注、栏界及绘制内容定位图表，组合本页正文、表格、原排片段和整页预览，保留原页矩形 |
| `Infrastructure/PDF/Navigation/{PDFTableExtractor,PDFTableBitmap,PDFSourceRemainder}` | 核对单元格文字、格式、闭合网格与组标题分隔线，合并未配对且未被图表覆盖的原排区域 |
| `Infrastructure/PDF/Navigation/{PDFEnglishLineBreak,PDFEnglishWordSpacing,PDFProseMarkers,PDFBylineExtractor,PDFReferenceSection}` | 核对英文断词与字距、识别首页署名和跨页书目，并保留原文与页内顺序 |
| `Infrastructure/PDF/Display/PDFRegionRenderer` | 有尺寸上限的原页区域渲染，输出本机阅读所用的 PNG |
| `Infrastructure/Models/PDFSentenceTranslator` | 批量逐句翻译并校验来源编号、数字、单位及引用 |
| `Infrastructure/Persistence/PDFSentenceTranslationStore` | 独立于书库快照的逐页原子写入与续译，按原文件和句子签名隔离缓存版本 |
| `Application/Reading/PDFDocumentTranslationQueue` | 从当前页开始逐页提取段落、复用译句、处理缺译与无正文页，按阅读位置更新优先级 |
| `UI/Application/Reading/PDFDocumentTranslationController` | 管理每篇论文的翻译任务与进度、用户暂停和应用生命周期 |
| `UI/Application/Reading/PDFBilingualSession` | 原页、译句、选区和暂停/恢复的协调 |
| `UI/Platform/HTML/{PDFSentenceTextCanvas,PDFReadingTableScript}` | 呈现逐句对照、连续段落和可选表格，连接视口页码、选文复制与原页定位 |
| `Infrastructure/Discovery/{FederatedPaperDiscovery,ScholarlyIndexes,PaperDiscoveryRanking}` | 多索引并发检索、按 DOI 和显式版本关联合并结果、Semantic Scholar 相关推荐 |
| `Infrastructure/Discovery/OpenAccessPDFDownloader` | 出版记录的开放 PDF 来源校验与下载 |
| `Infrastructure/Discovery/ArxivClient` | 可信候选与同版本 TeX/PDF 下载 |
| `Infrastructure/TeX` | 有界解包、静态包含/宏展开、语义标记、源码保存和 TeX/HTML 路由 |
| `Infrastructure/HTML` | HTML 净化、图片本地化、公式处理与最终阅读文件追加 |
| `Infrastructure/Models` | SSE、结构计划、翻译与有界恢复；不接受模型生成的 HTML/资源地址 |
| `Infrastructure/Persistence/PaperAbstractStore` | 按原文件哈希和已发布版本保存摘要及译句定位，导入、旧库补齐与预览共用同一提取任务 |
| `Infrastructure/Persistence/ReadingArtifactCleanup` | 清理未引用的应用制品，保留旧版本 |
| `UI/Application/Reading/ImportActions` | 导入、哈希去重、补齐线上来源和提交 |
| `UI/Application/Reading/AIReflowActions` | 保存来源、计划与完整块，协调暂停、恢复和新版本 |
| `ReaderSmoke/TeXPreviewSmoke` | 原创离线 TeX/HTML、原版完整性与重启验证 |

表内 UI 指 `PaperReaderUI`，其余适配路径位于 `PaperReaderKit`。本地 PDF 的段落重排在同一滚动视图中呈现相邻原页，加载窗口围绕阅读位置移动。原文件页号、字符范围和行框仍是批注与回原页的定位依据。译句缓存的签名使用原段标识，因此调整阅读分段后仍可复用对应的完整译句。独立 TeX 图件可以使用 PDF 图片格式，由图片解码器处理。

`OnlinePaperSource` 保存来源版本、源码路径和哈希；`TeXSourceAnchor` 保存主文件与展开块序号。源码失败后只尝试同版本 HTML，失败交回原版阅读。`ReflowJob` 保存可恢复来源、计划与完成记录；仅 preparing/tex/html 路线可续跑，旧记录继续解码但不进入转换。

`AIReflowEvidence` 建立来源和对象身份；`AIReflowEnvelopeStream` 增量解析 JSON events；`AIReflowStream` 校验原文顺序、覆盖、完整块、公式和恢复前缀。协议失败时 `AIReflowRecovery` 复用同一校验，按整段恢复。`ChatCompletionStream` 解码 SSE 文本和工具参数；`NetworkTransport` 复用 URLSession。密钥通过异步凭据适配读取，View 不直接访问 Keychain 或调用模型。

`HTMLReadingStore` 只追加完整块并写新文件。`HTMLReadingArtifact` 的稳定节 ID 同时用于导航、批注与引用，不代表 HTML 纸张分页；重复块拒绝发布。串行保存先提交引用，之后才清理孤立文件；WebKit 打开的文档有引用保护。`RetainedReading` 保存旧版本，旧 PDF/HTML 数据只保留阅读与定位兼容，旧生成代码已删除。

## 平台阅读与笔记

`Platform/HTML` 负责 WebKit、语言独立选区、浮层、图片预览和阅读笔记；`Application/Reading` 负责可持久化动作。HTML 高亮使用稳定块、语言和字符范围；旧字段继续按原语义读取，不自动扩大或迁移范围。共享图片/表格/公式按对象定位。

`Domain/Reading/AnnotationRangeEditor` 处理局部范围编辑；`ReadingNote` 保存独立锚点、Markdown 与软删除状态。笔记编辑器资源由 `scripts/note-editor` 构建，预览不写入数据库。页边卡片使用文档坐标跟随原生滚动，编辑时保持位置；动画不能改变正文布局。

`Infrastructure/HTML/Mathematics` 在 JavaScriptCore 中用随包 KaTeX 编译静态 MathML；图片模块保留 SVG 与受支持位图/PDF 图件，拒绝活动资源。第三方资源与许可证随 `Resources` 分发。

快照 v9 显式清除未完成 TeX/HTML 任务的旧窗口计划与窗口提交索引，避免已删除元数据改变来源摘要后阻断恢复；已完成来源 ID、已发布内容和用户记录不变。下一次继续只规划未发布部分。

书库快照 v10 按已保存精读报告的笔记 ID 识别旧的全文总结，保留 Markdown 和引用，并把其位置迁到文末。文末页属于阅读器，原始 PDF 与已发布 HTML 的页码、段落和批注坐标沿用原有版本。

快照 v12 从活动集合永久移除论文及其用户记录。v11 试用快照中的暂存论文在迁移时并回活动集合。`ReaderModel` 协调串行保存、后台任务停止及应用私有文件清理。手动删除与助理结果卡共用窗口级确认，在执行前重新核对目标。

快照 v13 为一次划线产生的多个片段记录同一操作 ID。PDF 提取器同时提供原页字符范围和重排句内的 UTF-16 范围，供选择和绘制复用。迁移仅按已有记录为可识别的旧笔记留下线索，打开对应原页时再核对片段文字和间隔。页边显示使用核验后的范围，编辑和引用沿用保存时的原始锚点。

`Application/Reading/PaperReadingNotebook` 通过精读报告的论文 ID 和文末笔记 ID 关联当前有效的 `ReadingNote`。书库按论文分组展示，历史各次保留自己的报告时间和关注点，打开时读取原笔记。独立保存的文末笔记按创建时间列入同一索引。设置中的研究记忆复用 `Features/Memory/MemoryView`，继续通过 `ReaderModel` 编辑和删除。现有研究资料、Agent 工具、记忆的更正与删除，以及周期整理的后续设计见[研究记忆设计](agent-memory.md)。

`Domain/Reading/ReadingMetrics` 按所选日的起止时间截取 `ReadingEntry`，分别计算每篇论文和全日的时间并集。`Features/Calendar` 展示聚合结果，明细通过原记录 ID 修正，数据库继续逐条保存阅读活动。
