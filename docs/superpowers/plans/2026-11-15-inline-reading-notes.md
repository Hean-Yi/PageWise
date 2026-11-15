# 阅读笔记卡片 Implementation Plan

**Goal:** 实现已确认的 HTML 笔记设计，跨侧栏切换保持同一笔记、草稿和稳定锚点。

**Architecture:** 领域记录保存独立锚点与 Markdown 源文，v7 快照显式迁移。应用层协调自动保存、预览和撤销删除；WebKit 隔离脚本处理命中、卡片空间预算、波浪线与动画，不修改正文节点。

**Tech Stack:** Swift 6、SwiftUI、WebKit、SwiftSoup；随包 Marked 18.2.0（MIT）解析 Markdown，已有 KaTeX 本地编译数学公式。按本会话授权在当前线程顺序实现，无远程发布。

## 实施顺序

- [x] `Domain/Reading/ReadingNote.swift`：独立 NoteAnchor 与 ReadingNote；LibraryState v7 增加 readingNotes、v1–v6 初始化空集合。测试旧快照迁移、保存重开、删除撤销和笔记不随高光拆分丢失。
- [x] `Infrastructure/HTML/Notes/NoteMarkdownRenderer.swift`：actor 内 Marked + 数学 token 编译，白名单净化、危险链接拒绝、公式错误保留源码。测试列表、任务、表格、代码内美元符号、独立/行内公式及恶意 HTML。
- [x] `Application/Reading/ReadingNoteActions.swift`：立即保留输入、延迟落盘、离开时刷新、失败提示、删除/撤销、列表定位；重新解析保留笔记锚点。Obsidian 只在主动保存时包含阅读笔记。
- [x] `Platform/HTML/HTMLNoteBridge.swift`：验证输入锚点，异步预览与保存回执，迟到结果隔离；传入实际侧栏状态。通过已有选区接口复用颜色/模式编辑。
- [x] `Platform/HTML/HTMLNotesScript.swift`、`HTMLNoteLayoutScript.swift`、`HTMLNoteStyle.swift`：同一编辑卡片；点标注、拖选入口；页边摘要/展开与浮卡切换；局部文字覆盖层上浮、波浪线、双向虚线；长内容内部滚动、键盘和触摸入口。
- [x] `Features/Reader/ReaderNotesView.swift`：阅读笔记汇总、进入同一笔记、撤销删除。增加真实 WKWebView 工作流测试，验证跨段/独立语言、侧栏切换、标注和笔记独立、预算及正文几何不变。
- [x] 运行 `bash scripts/check.sh`（格式、全部测试、冒烟、Mac/iPad 构建）；通过 Computer Use 启动新 Mac 构建检查上述状态。更新 requirements、architecture、README 与 mvp-status，仅报告实测结果，创建本地提交。

## 完成边界

卡片空间不足回退浮卡，不改变正文宽度。Markdown 源文是唯一持久正文，预览只在内存缓存；错误源码可保存。公式支持范围依现有编译器；不运行任意 TeX 工程。真实论文、模型密钥与笔记验收数据不进入 Git。iPad 若只构建则明确记录未做触摸真机验收。

执行结果：199 项测试及完整检查通过，Mac 实际窗口已检查并重启恢复；后续视觉细节修正另做针对性回归与 Mac 构建复验。实际范围和未覆盖边界见 docs/mvp-status.md。

用户验收追加项已处理：编辑态实时编译预览；滚动不再重排或重建笔记节点；文档坐标跟随与固定编辑卡片、短缓动展开/回落。新增回归检查输入晚到隔离、滚动坐标/节点稳定，完成最终 Mac 构建后的 Computer Use 复验。
