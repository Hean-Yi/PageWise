# 工程目录与职责整理

用户要求按类别分层、避免所有代码堆在单个目录。本轮保持产品行为、公开 API、数据库 v4 编码及最低系统版本，整理代码和测试的物理归属，并拆分明显混合职责的文件。

核心模块按 Domain（纯业务模型与规则）、Application（检索等纯用例）、Infrastructure（PDF、持久化、模型服务、发现论文、配置与 Obsidian 适配）、Samples（应用内原创示例）分类。Domain 下按 Library、Papers、Reading、Assistant、Settings 和 Common 分组；Models.swift 按模型职责拆开。

UI 模块按 Application（状态与用例协调）、Features（按 Library、Reader、Agent、Discovery、Calendar、Memory、Settings 聚合页面）、Platform（macOS/iPadOS 原生桥接）、DesignSystem（主题与共享视觉）分类。日历与记忆页面分开，排序持久化操作与拖动临时控制器分开，文件名称反映主要类型/职责。平台共用 PDF 画布归 Platform/PDF。测试对应领域、适配器与工作流，跨业务集成测试明确归 Integration，公共假凭据归 Support。

保留现有少量 Swift Package targets，使用递归源码发现；不为目录创建空 target，不改变 Xcode App 配置路径。历史规格与实施记录保留原路径作为历史证据，当前入口文档链接更新到新结构。目录规则写入 engineering.md 与独立 architecture.md，约束后续文件摆放，避免新的 Utils/Services 大杂烩。

验证：审查移动/拆分差异与公开符号、对比整理前后源码/测试清单防止遗漏，运行格式检查、140 项既有测试、ReaderSmoke、Mac 与 iPad 构建。此次为源码结构重构，不需要重复手势/UI 视觉验收，不修改用户资料或发布远程。
