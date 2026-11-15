# 标记整体悬浮实现计划

**目标：** 落实用户已确认的方案一，消除文字与原位高光脱离。

**实现：** `HTMLSelectionScript.swift` 提供实际绘制范围和临时排除接口；新增 `HTMLNoteLiftScript.swift` 负责字形、高光、下划线和波浪线的统一非交互图层；`HTMLNoteLayoutScript.swift` 保留布局与连线职责。平移使用单个 transform，正文 DOM 和批注存储不变。

- [ ] 扩展 `ReadingNoteCardTests.swift`：局部彩色高光、下划线、取消、回落恢复；检查源范围外仍可见、正文节点和高度不变。
- [ ] 绘制层按文字节点范围求交，原位绘制减去临时抬起范围；完整样式缓存用于覆盖层，避免从已隐藏图层取样。
- [ ] 统一图层平移 1–2 pt、淡阴影；跨行一致、回落恢复、快速切换取消、同锚点更新不重播、滚动不重测；共享对象及预算外文字原位反馈。
- [ ] 运行 `swift test --filter ReadingNote` 和 `bash scripts/check.sh`，确认检查实际结果。
- [ ] 构建后通过 Computer Use 启动最终 Mac 应用，检查高光、下划线、波浪线和收起状态；更新验收记录并提交本次实现。

当前会话内执行，不部署、不调用模型或修改用户笔记内容。
