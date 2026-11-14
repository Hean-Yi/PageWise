# 主题书架与页内查找实施计划

> **For agentic workers:** 使用 superpowers:subagent-driven-development，逐项验证、提交并进行需求及质量审查。

**Goal:** 在现有全部论文页面完成主题归类和连续的在线获取体验。
**Architecture:** Kit 持有 Shelf 与单一归属、快照迁移；ReaderModel 用例协调持久化；SwiftUI 只发送意图。独立可注入的在线查询协调器管理任务，不在 View 调服务。
**Tech Stack:** Swift 6 / SwiftUI / SQLite，macOS 15 / iPadOS 18。

- [x] 在 Models.swift 添加主题书架持久结构，显式升级快照；测试 v1/v2 保留、未知版本拒绝、新结构往返。
- [x] 新增 ShelfActions.swift，创建/改名/删除/移动均校验名称与 ID；删除仅清归属。添加重启、移动去重、失败恢复回归，swift test 后独立提交。
- [x] 新增主题卡片及页内编辑区域，LibraryWorkspaceView 展示卡片/未分类/选中主题；BookshelfItem 支持内部论文拖拽及归类菜单，内部拖放与 PDF 外部拖放分离。
- [x] 将 SearchView 改为页内组件，LibraryView 移除查找 sheet；查询协调器注入 PaperDiscovery，支持取消、失败重试、过期响应隔离、导入成功留在页面并归入当前主题。
- [x] 假服务测试查询和导入状态，严格格式检查、swift test、Mac/iPad 构建，每项完成即 commit。
- [x] 先需求审查后质量审查，Computer Use 检查真实窗口的新建、归类、页面展开与返回，实际缺陷单独修正提交。
- [x] 更新 README/requirements/mvp-status，运行 scripts/check.sh；本地合并 main、复验并更新 .local/PaperReader.app，不推送。

- [ ] Mac 真实手势往返移动验收：旧版已被用户确认失败；原生拖放候选修复完成，等待新版人工复测，不以单元测试或启动拖拽会话替代。

验收边界：Computer Use 已验证新建、菜单归类、重启、页内查找、输入聚焦，以及新原生覆盖层上的单击阅读和右键菜单。事件诊断显示自动化没有移动系统全局光标，虽然事件坐标命中目标仍未收到落点回调；人工复测问题保持待答，样例窗口保留。最终实现检查：be15f1b，128 项测试、格式、冒烟及 Mac/iPad 构建通过。
