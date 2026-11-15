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

`Platform/HTML/HTMLSelectionScript` 负责语言独立的文本范围、跨段过滤、共享对象选择与文字选区绘制；`Application/Reading/HTMLTextSelection` 保存本次选文的有序块范围，问答固定全部选中块为优先证据。持久化 Highlight 的可选 htmlTarget 保存 source/translation 文本坐标或块内 object 索引；新文字坐标排除共享对象，译文发布后才可选择。图片、表格与公式以整体对象轮廓标记，引用仍固定原文块为证据，文本模型不接收图片字节。缺少 htmlTarget 时，可选 linksTranslation 继续解释此前的源文本与整段译文关联；两者均缺省继续解释旧整段 DOM 坐标，不迁移旧记录或改变已发布文本。


`Domain/Reading/AnnotationRangeEditor` 负责选区减去旧范围并保留两侧片段，颜色与样式为 Highlight 的可选字段，旧记录默认黄色高亮。`Application/Reading/HTMLAnnotationActions` 协调旧坐标投影校验、范围编辑及选区书签持久化；`Platform/HTML/HTMLAnnotationMenuScript` 只负责浮层、选区覆盖状态和动作消息。下划线用独立覆盖层绘制，窗口/正文尺寸变化时重新定位，不包装或替换正文节点。旧坐标只在用户实际编辑命中记录时显式转换，未命中记录保持原样。

文字标记底色和临时选区底色在正文下方显式按行绘制，CSS Highlight 仅提供前景色。静止与笔记上浮共用 `lineRanges` 的实际字形矩形，避免 WebKit 将跨行范围合并并额外填充行间空白，导致局部抬起时底色高度变化。尺寸变化和字体就绪时刷新两种底色，滚动保持文档坐标，不重新拆行；保存坐标仍为完整字符范围。


## HTML 阅读笔记

`Domain/Reading/ReadingNote` 保存独立 NoteAnchor、稳定内容版本、Markdown 源文和软删除状态，不绑定可拆分的 Highlight ID。LibraryState v7 显式为 v1–v6 初始化空笔记集合，保留原批注。重新解析拒绝改写有笔记（包括可撤销删除记录）的版式。

`Application/Reading/ReadingNoteActions` 负责输入保留、350 ms 延迟保存、离开时刷新、失败重试、删除撤销与列表定位；`ObsidianActions` 仅在显式保存时附加阅读笔记。`Infrastructure/HTML/Notes/NoteMarkdownRenderer` actor 复用本地 Marked 引擎，以 SwiftSoup 白名单净化，再调用既有 KaTeX 编译数学。Marked 18.2.0 与 MIT 许可证随 `Resources/Marked` 打包；运行时不加载 CDN。Markdown 源文是唯一持久正文，预览仅在内存复用。

`Platform/HTML/HTMLNoteBridge` 隔离消息、预览与晚到结果；`HTMLNotesScript` 管理编辑状态及同一卡片，`HTMLNoteLayoutScript` 负责页边避让与曲线，`HTMLNoteLiftScript` 合成文字、标注颜色、下划线和波浪线的统一非交互上浮层，`HTMLNoteStyle` 定义预算和减少动态效果样式。Selection 保存完整绘制范围并临时减去已转移范围，回落后恢复；波浪线使用互补遮罩，局部转移不影响其他标注。同一锚点更新样式不重播动画。复用语言独立选区接口，保留部分单词和共享对象；所有提示/上浮都在覆盖层绘制，不包装或移动已发布正文。`Features/Reader/ReaderNotesView` 汇总并定位同一笔记。

笔记页边卡片、波浪线和文字覆盖层采用文档坐标，滚动由 WebKit 原生合成处理；只有激活、窗口/正文几何变化才计算布局。编辑卡片固定于当前视口，滚动只使用缓存锚点更新一条连接路径，不读取逐字几何、不重建装饰 DOM。上浮覆盖限制最多 2000 个字符，超长选区保留原文字体与完整锚点，不为动画产生无界逐字测量。编辑器在同一区域装饰 Markdown 源文，数学合并 60 ms 输入后异步编译，落盘仍为 350 ms。悬停通过缓存文档坐标命中，文字与卡片之间使用方向性通道；显式数值高度与位移共用一次短动画，避免 auto 高度和 CSS 动画竞争。点击进入编辑时独立使用一次可取消的 transform/opacity 入场动画，缩放原点来自连接终点；浮卡入场临时连线结束后移除，不产生定时器重排或持久数据。

`Platform/HTML/NoteEditor/Editor.js` 使用 CodeMirror 6 的状态、Markdown 语法树和装饰层，保持 Markdown 字符串为唯一正文，撤销与输入法由编辑器处理。公式及表格复用 Swift 净化后的渲染结果，点击回到对应源码；装饰替换范围为原子范围，普通加粗文字仍按字符移动光标。`HTMLNativeNoteEditorScript` 加载随应用分发的本地 bundle，不加载 CDN。修改后运行 `npm ci --prefix scripts/note-editor` 与 `npm run build --prefix scripts/note-editor`；依赖和锁文件位于该脚本目录，产物与依赖许可证在 `NoteEditor.bundle`，均需提交。Node 只用于开发时构建，Mac/iPad 运行时不依赖它。
