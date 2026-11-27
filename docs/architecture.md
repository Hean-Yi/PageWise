# 工程结构与模块归属

本项目围绕 `PaperReaderKit`、`PaperReaderUI` 与 `ReaderSmoke` 三个 Swift Package 产品按职责分层组织目录；仅 Swift Package target 是编译边界，避免在当前阶段过度拆包引入装配成本。

---

## 1. 目录导航与职责边界

```text
App/                         # 应用入口、Info.plist、签名与权限配置
Sources/
├── CSQLite/                 # SQLite C 模块桥接
├── PaperReaderKit/          # 跨平台核心库（无 SwiftUI / AppKit / UIKit 依赖）
│   ├── Domain/              # 领域模型与纯业务规则（Library / Papers / Reading / Assistant / Settings / Common）
│   ├── Application/         # 用例计算、检索、Agent 循环与上下文压缩
│   ├── Infrastructure/      # PDF / TeX / HTML / SQLite / 模型协议 / 在线检索 / Obsidian 适配
│   └── Samples/             # 应用内原创教学 PDF 入口
├── PaperReaderUI/           # 跨平台界面与协调层
│   ├── Application/         # ReaderModel 共享状态与用例协调扩展
│   ├── Features/            # 按功能聚合的页面与控制器（Library / Reader / Agent / Discovery / Calendar / Memory / Settings）
│   ├── Platform/            # macOS / iPadOS / PDFKit / WebKit 原生桥接与拖放
│   └── DesignSystem/        # 主题、字体缓存、动效、图标与共享控件材质
└── ReaderSmoke/             # 独立离线端到端冒烟入口
Tests/
├── PaperReaderKitTests/     # 核心领域与适配器单元测试
└── PaperReaderWorkflowTests/# 跨模块工作流、WebKit/PDFKit 界面回归与 Cassette 轨迹评测
scripts/                     # 启动、检查、打包与笔记编辑器构建脚本
docs/                        # 7 份规范长期文档
```

### 依赖方向
```text
App ──▶ PaperReaderUI ──▶ PaperReaderKit ──▶ CSQLite

Features ──▶ Application (ReaderModel) ──▶ Domain + Infrastructure
Platform ──▶ shared feature state + Domain
DesignSystem ──▶ SwiftUI
```

### 新文件放置原则
1. 先按职责判断属于**领域规则、外部适配、应用协调、功能页面还是平台桥接**，再选择目录。
2. 一文件一主题；小型私有子视图可留在对应页面文件中，跨业务类型拆开存放。
3. **禁止**向 `PaperReaderKit/` 或 `PaperReaderUI/` 根目录堆放 Swift 文件，**禁止**新增通用 `Models.swift`、`Utils.swift` 或无边界 `Services/` 目录。
4. 平台专有控件放 `Platform/macOS` 或 `Platform/iPadOS`；跨端 PDF 画布放 `Platform/PDF`；WebKit 阅读与笔记桥接放 `Platform/HTML`。
5. 仅在单一功能内使用的组件留在对应 `Features/` 子目录，确认多处复用再提升至 `DesignSystem/`。
6. 公共假服务与测试替身放在对应测试 target 的 `Support/`，跨功能测试放 `Integration/`。

---

## 2. 核心子系统与文件映射

### 持久化与快照迁移（SQLite）
`LibraryStore` 采用 SQLite 记录表事务存储（论文、笔记、标注、对话、记忆、阅读事件、书签与每篇工作区独立表保存），配合代次校验防止多实例陈旧覆盖。`ReaderModel` 维护串行保存队列，按最新内存状态增量编码变更。

| 快照版本 | 显式迁移内容 |
| --- | --- |
| **v2** | 事务内将早期整库 JSON 转为独立记录表 |
| **v9** | 清除未完成 TeX/HTML 任务的旧窗口计划，保留已完成来源、已发布内容与用户记录 |
| **v10** | 按精读报告 ID 将旧全文总结迁至文末总结位置，保留 Markdown 与引用 |
| **v12** | 将试用暂存论文并回活动集合，永久删除走窗口确认并清理私有文件 |
| **v13** | 为单次划线产生的多片段记录统一操作 ID，支持原页与重排句坐标核验 |
| **v14** | 保留完整笔记原文、创建时间、引用锚点与研究记忆增量表兼容 |

> 新增持久化字段时，必须明确归属并编写旧库升级迁移测试，禁止以删库作为升级方案。

### 阅读生成、双语重排与平台渲染

| 路径（`UI/` 指 `PaperReaderUI`，其余在 `PaperReaderKit`） | 职责 |
| --- | --- |
| `Infrastructure/PDF/Import/PDFImporter` | 原始 PDF 校验、哈希计算与副本保存 |
| `Infrastructure/PDF/{Display,Navigation}` | 原版展示、目录、逐句提取、图表定位、规则表格提取、英文断词/署名/书目识别 |
| `Infrastructure/Models/PDFSentenceTranslator` & `Infrastructure/Persistence/PDFSentenceTranslationStore` | 本地 PDF 逐句翻译校验与独立按页原子缓存 |
| `Application/Reading/PDFDocumentTranslationQueue` & `UI/Application/Reading/PDFDocumentTranslationController` | 当前页优先的后台全文翻译队列与生命周期管理 |
| `Infrastructure/Discovery/{FederatedPaperDiscovery,ScholarlyIndexes,ArxivClient,OpenAccessPDFDownloader}` | 多源并发检索、DOI 合并、相关推荐与开放全文下载 |
| `Infrastructure/TeX` & `Infrastructure/HTML` | 有界静态 TeX/HTML 净化、图片与 KaTeX MathML 本地化、增量只追加 HTML 发布（`HTMLReadingStore`） |
| `Infrastructure/Models/{AIReflowStream,AIReflowRecovery,ChatCompletionStream,NetworkTransport}` | 流式结构计划/译文校验、有界恢复与 SSE 解码 |
| `UI/Platform/HTML/{HTMLCanvas,PDFSentenceTextCanvas,HTMLNoteBridge,HTMLNotesScript,HTMLNoteLayoutScript}` | WebKit 连续阅读、按语言独立选区、批注浮层、图片预览与页边笔记卡片 |
| `UI/Platform/PDF/PDFCanvas` | 原版 PDF 渲染、高亮叠加、选文浮层与 iPad Pencil 笔迹 |

- 笔记编辑器前端资源由 `scripts/note-editor` 构建；页边卡片使用文档坐标随正文滚动，动画不改变正文几何布局。
- 原始 PDF 与已发布 HTML 块不可变；旧版本通过 `RetainedReading` 保留读取与定位兼容。

### Agent 编排、混合检索与研究记忆
- **统一循环与压缩**：`AgentLoopRunner` 与 `AgentContextCompactor`（`PaperReaderKit/Application/Assistant`）由书库助理与论文助读共用，负责有界多轮工具调用、Prompt Cache 稳定前缀、渐进上下文压缩、同轮只读工具并发与 `propose_memory` 事务提交。
- **模型兼容与思考流**：`ModelCapabilities` 集中管理各模型家族与端点的参数兼容；`ChatCompletionStream` 支持 `reasoning_content` 与全程 `<think>/<thought>/<thinking>` 增量路由。
- **设备端检索**：`DeviceSemanticEncoder` 优先加载随包内置的 4-bit Core ML 模型；`SemanticPassageIndex` 负责派生向量与冷启动覆盖度门控，7 类派生向量通过命名空间收敛至单一 `DerivedIndexes/vectors.sqlite`（WAL 模式）；`LibraryFTSIndex` 提供 SQLite `FTS5` BM25 论文检索；`Retriever` 融合词项与语义候选（单篇上限提升至 2,000 段）。
- **研究记忆与定期整理**：主库事务内写入 `research_events` 并推进 `research_generation`，`ResearchBriefIndex` 按水位增量更新简报；`MemoryItem` 支持双时态窗口、显著性衰减与 `revisionFingerprint` 乐观校验；`MemorySleepSession` 与 `NoteReviewSession` 分别负责空闲记忆整理与定期静默笔记修订。

### 书库与界面性能约定
- `QuickStartOverlay` 仅在引导命中当前步骤时通过环境条件上报 `anchorPreference`，日常使用无偏好树开销。
- `BookCoverView` 在书架列表中对标准版面启用不透明光栅化并走 GPU 缩放；`LibraryWorkspaceView` 在侧栏开合期间锁定目标布局宽度并缓存 `ShelfBookGridLayout` 子视图高度，避免逐帧重排；`ReaderTheme.editorial` 缓存 CoreText 字体实例。

---

## 3. 构建与工程规则
- Swift Package 自动发现 target 下的 Swift 文件；`PaperReader.xcodeproj` 仅管理 `App/` 与本地包引用，修改 `project.yml` 后用 `xcodegen generate` 重新生成。
- 运行 `bash scripts/check.sh` 执行严格格式检查、全量测试、离线冒烟与 Mac/iPad 构建。
- `.build/`、`.local/`、`Artifacts/` 与用户私有书库均属于忽略产物，不入仓。
