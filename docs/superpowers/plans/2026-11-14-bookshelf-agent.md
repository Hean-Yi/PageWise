# 封面书架与书库 Agent 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. 按下列任务执行，完成后分别检查与提交。

**Goal:** 交付大封面书架，以及能真实调用检索、导入准备和位置导航工具的书库 Agent。

**Architecture:** Kit 定义工具协议、检索与数据类型；UI 层的 LibraryAgent 协调 ReaderModel 与网络服务，View 只渲染状态及发送意图。书库与阅读助读保持独立，复用原始 PDF 导入和稳定页导航。

**Tech Stack:** Swift 6、SwiftUI、PDFKit、现有 SQLite、GLM 兼容 Chat Completions。无新增运行依赖。

---

### 1. 工具协议与 Agent 用例

文件：新增 `Sources/PaperReaderKit/Domain/AgentModels.swift`、`Services/AgentClient.swift`、`Services/LibraryAgentSearch.swift`；新增 `Sources/PaperReaderUI/LibraryAgent.swift` 与按职责拆分的工具执行文件；必要时调整 `ArxivClient.swift`；测试 `Tests/PaperReaderKitTests/AgentTests.swift`、`Tests/PaperReaderWorkflowTests/LibraryAgentTests.swift`。

- [x] 先用假 HTTPTransport 验证发送 `tools`、assistant `tool_calls`、tool `tool_call_id` 配对，以及非完整响应拒绝。
- [x] 实现工具消息和客户端，沿用 HTTPS、无鉴权重定向、Keychain 取密钥；不影响原有纯文本 complete。
- [x] 实现实际的 `search_library`、`read_paper`、`search_online`、`prepare_import`、`open_paper`，参数严格校验，可信结果注册表限定可导航/导入对象。
- [x] `LibraryAgent(reader:)` 暴露 turns、isRunning、send(_:)、cancel()、reset()、confirmImport(cardID:)、open(cardID:)；UI 使用有类型的卡片和活动状态，不解析模型文本作命令。
- [x] 测试精确页导航、空命中、未知工具/伪造 ID、导入确认前无下载、重复点击与取消后不写入、新会话隔离、轮数/长度限制。
- [x] `swift test`、Swift 格式检查后提交 `feat: add bounded library agent tools and workflows`。

### 2. 封面书架与 Agent 面板

文件：改 `LibraryWorkspaceView.swift`、`LibraryView.swift`、`ReaderView.swift`；新增 `BookCoverView.swift`、`LibraryAgentView.swift`、`AgentResultCard.swift`；进度纯函数与测试放 `Domain/ReadingProgress.swift`、`Tests/PaperReaderKitTests/ReadingProgressTests.swift`。

- [x] 测试原文/固定页进度映射、缺失稳定 ID 不猜位置；追加 100% 自动已读、状态持久化、未读优先及未完成排序优先的回归。
- [x] 全部论文/收藏网格首项为虚线加号，正在阅读/已读隐藏；缩小继续阅读，保留搜索、集合、排序。删除主内容添加菜单/视图切换，保留侧栏底部 PDF 导入和全窗拖放。
- [x] 封面悬停/焦点显露进度及收藏，减少动态效果与 iPad 触摸等价；标题可读，菜单支持标记状态。
- [x] 右上 Agent 打开独立面板；工具活动、证据导航卡、arXiv 候选卡、导入前/进行中/成功/失败状态清晰。未配置 API 时提供设置入口；输入框支持发送/停止，新会话清理。
- [x] `swift test` 与 Mac/iPad 编译后提交 `feat: introduce cover bookshelf and actionable agent sidebar`。

### 3. 真实窗口验收与交付

文件：按实际发现修正 UI；更新 `README.md`、`docs/mvp-status.md`、`docs/requirements.md`。

- [x] Computer Use 在独立本地样例库检查封面、聚焦时等价的悬停显露状态、收藏、继续阅读、虚线入口、Agent、窄窗口。不能用真实 API 作为默认测试。
- [x] 按发现的问题单独修正、检查并 commit；执行需求审核及代码质量审核，处理实际问题。
- [x] `bash scripts/check.sh` 全部通过；记录实际覆盖与未覆盖边界。
- [x] 更新功能与状态文档并提交。
- [x] 本地合并回 main，复验并交付已构建 Mac 应用。
