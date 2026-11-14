# 封面拖动实施计划

目标：让拿起、移动、插入和取消都有直观反馈，支持持久化手动整理。

架构：领域层负责合法顺序与版本化存储，ReaderModel 负责提交与失败处理；临时拖动状态隔离在 UI，会话结束时释放；原生桥仅传递经过验证的论文 ID 与位置。

- [ ] 在 LibraryState / LibraryQuery / ShelfChange 与 ReaderModel 中增加自定义排序，显式升级旧快照。验证隐藏项保留、分组、重复或未知 ID、重启与失败。
- [ ] 在 BookCoverView / NativePaperDrag / LibraryWorkspaceView 中生成真实书封拖动图，原位置淡化、短动画让位、落位与取消恢复；避免透明层截图、悬停抖动、跨窗口外来引用和拖动触发打开。
- [ ] TopicShelvesView 强化有效目标描边与缩放，拖动结束恢复；提供菜单排序操作与 iPad 拖放路径。
- [ ] 独立规格审查后进行代码审查，修复实际问题；运行 scripts/check.sh、隔离样例 Computer Use 检查，记录限制，提交并更新本地应用。

检查命令：`swift test`、`bash scripts/check.sh`、`git diff --check`。所有验收资料留在忽略目录，仅提交原创代码、测试和文档；无真实 API 调用。
