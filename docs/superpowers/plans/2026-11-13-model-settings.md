# 模型设置实施计划

> 使用 writing-plans / executing-plans 流程，在已获授权的本地 MVP 内完成。

**Goal:** 用户可以在清晰的设置页自行配置、测试和保存模型 API。

**Architecture:** 纯配置校验 → Keychain 与设置持久化 → ReaderModel 用例 → SwiftUI 草稿表单。

**Tech Stack:** Swift 6、SwiftUI、Security、Foundation；macOS 15 / iPadOS 18。

- [x] 在 `Tests/PaperReaderKitTests/ModelTests.swift` 添加 URL/模型校验、完整端点规范化测试；`swift test --filter model` 验证。
- [x] 新建 `Services/ModelConfigurationStore.swift`；测试旧配置兼容、密钥独立提交、改地址隔离、删除、失败恢复，所有测试使用内存凭据服务。
- [x] `ReaderModel` 注入配置存储，设置改为成功提交后生效；`ModelClient` 使用统一校验，提供不含用户资料的连接验证。
- [x] `SettingsView` 实现分栏切换、预设、草稿、密钥状态、明确保存/取消、连接测试和内联错误；修改相关 GLM 专属文案为可配置模型服务。
- [x] 严格格式、Swift 测试、Mac/iPad 构建；Computer Use 验证真实窗口，必要时迭代布局。只使用原创示例和虚拟配置，不调用真实模型。
- [x] 更新 README / MVP 状态，提交并合入主工作区，更新 `.local/PaperReader.app`。
