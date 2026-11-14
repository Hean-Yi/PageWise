# 主页书架导航精简实施计划

> **For agentic workers:** 使用 superpowers:subagent-driven-development 完成同一个界面任务，随后进行规格与质量审查。

**Goal:** 用一条横向书架导航替换主页多层分类区域，保留当前书架内添加论文的归属。

**Architecture:** TopicShelvesView 仅管理导航和名称编辑，LibraryWorkspaceView 管理页面层次；复用 ReaderModel 的书架用例与 OnlinePaperSearch 的目标捕获，不改存储格式或下载服务。

**Tech Stack:** Swift 6 / SwiftUI / AppKit bridge；macOS 15 / iPadOS 18。

- [ ] 修改 Sources/PaperReaderUI/TopicShelvesView.swift：ScrollViewReader + 横向 ScrollView，HStack 顺序固定为未分类、ForEach(shelves)、末尾加号；用紧凑标签替代预览卡片。每项保留 Mac NativeShelfDrop 和 iPad onDrop，未分类传 nil。点击选中、右键改名/删除不回归。
- [ ] 新建/改名仅按需展开 TextField 与 checkmark/xmark 按钮；非空且未保存时可确认，Return 保存、Escape 关闭。createShelf 返回 id 后 selectedShelfID = id，ScrollViewReader.scrollTo(id, anchor: .trailing) 保证选中项可见。尊重 accessibilityReduceMotion。
- [ ] 修改 Sources/PaperReaderUI/LibraryWorkspaceView.swift：标题显示 collection.title；移除下方重复书架名称，只保留排序与查询结果标识。保留继续阅读、论文大封面、已读排序、全库标题检索及 AddPaperCover { onlineSearch.open(shelfID: collection == .all ? selectedShelfID : nil) }。
- [ ] 运行 xcrun swift-format format/lint 与 swift test；现有 OnlinePaperSearchTests 覆盖目标切换、重复导入归属以及进行中导入捕获，不为静态布局添加镜像测试。源码与相关修正各自 commit。
- [ ] 在隔离原创样例通过 Computer Use 检查未分类第一项、末尾加号、新建自动选中、横向滚动、改名/删除、页内检索目标、导入后留在对应书架；不调用真实 API。
- [ ] 运行 bash scripts/check.sh（格式、核心/工作流测试、PDF 冒烟、Mac 与 iPad 构建）；记录真实结果及人工拖拽边界。更新 README 与 mvp-status，commit 后本地合并 main、更新 .local/PaperReader.app；不推送。
