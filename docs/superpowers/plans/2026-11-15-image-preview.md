# 图片沉浸预览实现计划

目标：落实用户确认的点击图片自然放大、背景高斯模糊变暗和平滑过渡。

架构：在 WKWebView 隔离脚本中使用独立 HTMLImagePreviewScript 管理顶层模态预览，HTMLReaderScript 装配。复用本地图片资源，不改写已发布 HTML 文件或正文结构，不增加持久化缓存。

技术：现有 WebKit、dialog、原生 Web Animations、CSS backdrop-filter；不增加依赖。

## 交互与边界

- 图片从原图位置等比放大至视口内居中，预留工具栏和边距。SVG 与位图共用流程。
- 遮罩使用固定模糊半径与暗色背景，通过透明度渐入；图片只动画 transform，原图位置仍占位。
- 关闭按钮、点击背景、Esc 平滑缩回原位置；原图已不可见时淡出。保留引用图片操作，关闭后引用原始图片锚点。
- 预览期间阻止正文滚动、保留滚动位置，关闭恢复焦点。窗口变化重新适配；快速关闭取消旧动画；减少动态效果时即时切换。
- 拖选经过图片不打开预览；损坏或未就绪图片不生成空白放大层。所有资源仍使用已入库图片。

## 执行步骤

1. 新增 `Sources/PaperReaderUI/Platform/HTML/HTMLImagePreviewScript.swift`，实现单实例模态、图片几何、开关动画、清理和引用。
2. 修改 `HTMLReaderScript.swift` 装配新脚本，删除旧的直接弹窗分支。通过文档捕获阶段区分单击与拖选，保持共享对象引用能力。
3. 新增 `Tests/PaperReaderWorkflowTests/Platform/macOS/ImagePreviewTests.swift`，用原创 SVG/位图验证源节点与布局不变、缩放比例、快速关闭清理、重复打开单实例、引用原始对象及减少动态效果。
4. 运行严格格式与相关 WKWebView 回归测试；构建 Mac/iPad。通过 Computer Use 启动 Mac 新构建，实际点击图片、关闭、检查模糊背景和居中显示，记录未覆盖边界。
5. 更新需求与 MVP 实测记录，检查差异并创建独立本地提交。
