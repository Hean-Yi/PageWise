# 目录整理实施计划

目标：每个目录归属单一职责类别，功能页面、应用流程和平台适配可独立定位。

- [x] 按规格移动 PaperReaderKit 的 Domain / Application / Infrastructure / Samples，拆分 Models.swift；保留声明内容、访问级别和 Codable 字段。
- [x] 按 Application / Features / Platform / DesignSystem 整理 PaperReaderUI；拆分 MemoryView、CoverArrangement 等混合职责声明；保留共享状态和串行保存行为。
- [x] 整理两个测试 target 的分类，拆开跨领域 CoreTests，提取共用 WorkflowCredentials 至 Support；测试名称、数量与断言保留。
- [x] 根代理编写 architecture.md，更新 README、engineering.md 和 AGENTS.md 的归属规则；核对构建配置和当前文档路径引用。
- [x] 独立规格与代码质量审查，修复实际问题；执行 scripts/check.sh，对比源清单及 API，检查 gitdiff；本地提交、合并并清理分支。

已有基线：ff58ec0，140 项测试通过；普通可逆整理直接执行，不新增产品功能和依赖。实现代理负责代码与测试，根代理负责文档、完整构建和交付。
