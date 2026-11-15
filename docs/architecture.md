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

`.build/`、`.local/`、构建结果、验收样例及日志属于忽略的本地制品。用户资料不参与目录整理。已执行的规格与计划留在 `docs/superpowers/` 作为历史记录；当前导航以 README、本文和 engineering.md 为准。

## 结构化重排的文件归属

`Infrastructure/HTML/HTMLPaperParser.swift` 负责受限 HTML/图片解析；`Infrastructure/PDF/Reflow/StructuredPageRenderer.swift` 负责固定页生成，`ReflowArtifactCleanup.swift` 只清理未提交的本应用制品。`Application/Reading/ImportAndReflowActions.swift` 协调导入、翻译和提交，`ReflowRetentionActions.swift` 检查旧预览的用户依赖；View 不直接解析文档或调用模型。第三方许可证放在 `PaperReaderKit/Resources` 并随资源包分发。

`Infrastructure/HTML/Images` 分离图片来源本地化、ImageIO/CoreGraphics 解码、SVG 静态文档规范化和 HTML 图件替换。领域层只保存尺寸、局部失败提示和短期覆盖核验数据，不依赖图片或 WebKit 类型。

`Infrastructure/PDF/Import/Figures` 负责 PDF 图注几何定位、灰度像素/连通区域分析和高清裁剪；失败图件替换由 PDFImporter 协调。领域层的 FigureCaption 保存独立图注结构，使补图后仍能翻译图注而不翻译图内标签。`scripts/FigureCropAudit.swift` 与 `audit-figure-crops.sh` 是基于人工真值框的本地开发验证器，不属于应用运行依赖。


## HTML 连续阅读

`Domain/Papers/HTMLReadingArtifact` 描述唯一已提交 HTML、资源引用与稳定内容锚点；`Paper.readingPages` 为 HTML 内容段和旧 PDF 页面提供统一导航，不代表 HTML 仍然分页。`Infrastructure/HTML/Reading` 负责文件生成、资源去重与未提交文件回收；`Platform/HTML` 负责 WKWebView、隔离脚本桥、选文和滚动事件。HTML 先保存完整原文，只填充待译位置，已完成段落不改写；文本高亮使用 UTF-16 范围和原文核验，旧 PDF 高亮继续使用矩形坐标。

阅读器最多保留一个空的 WebKit 实例用于预热，网站数据存储为非持久化；它不保留论文版本或另建磁盘缓存。实际文档及资源属于用户阅读制品，随数据库提交事务发布。

`Infrastructure/HTML/Mathematics` 使用随包 KaTeX 在 JavaScriptCore 中将受支持 LaTeX 编译为静态 MathML；公式库和许可证位于 `Resources/KaTeX`。`Application/Reading/ReparseActions` 负责旧导入的显式重试、原始文件身份核对与事务发布，拒绝改写已发布版式。

`Infrastructure/Models/ChatCompletionStream` 解码 SSE 文本与工具参数增量，`ParagraphTranslationStream` 验证顺序段落边界并逐段提交。`NetworkTransport` 复用 URLSession，连接能否保持由系统与服务器协商；不承诺整个长文只使用一次 HTTP 请求。UI 临时草稿不进入数据库，已完成段落提交后替换对应草稿。

HTML 文件使用进程内引用计数保护 WebKit 当前载入的文件：清理跳过正在使用的文档，阅读器关闭时释放并清理；重启后无占用的旧文件正常回收。此机制不复制图片，也不累计历史版本。显式重排仅允许无 HTML 批注依赖的内容，保留原始 PDF、论文 ID、可复用块 ID 与已保存译文中的 MathML。

模型请求通过凭据适配器的异步读取入口访问 Keychain；设备适配器把可能等待系统授权的 SecItemCopyMatching 放到后台任务，完成后检查取消。View 的配置判断不读取密钥；仅状态检测与明确模型操作才读取，密钥不落盘。

`Platform/HTML/HTMLSelectionScript` 负责源文本范围、跨段归一化、文字范围选区绘制与英中关联高亮；`Application/Reading/HTMLTextSelection` 保存本次选文的有序块范围，问答固定全部选中块为优先证据。持久化 Highlight 的可选 linksTranslation 标识源文本坐标与段落译文关联；缺省继续解释旧整段 DOM 坐标，不迁移旧记录或改变已发布节点。
