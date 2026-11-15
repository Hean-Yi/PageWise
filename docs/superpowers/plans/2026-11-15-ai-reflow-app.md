# 按需 AI 双语重排 App 接入计划

> **For agentic workers:** 使用 superpowers:subagent-driven-development 实施，按任务检查规格与质量；本轮已获用户授权接入、构建并启动本地 App，不再次请求实现许可。

**Goal:** 把已确认的按需重排、结构化双语流、冷启动加载、OCR/结构化来源和低延迟请求接入 Mac/iPad 应用，构建 Mac 供验收。

**Architecture:** 入库只保存原 PDF 与元信息。新任务保存原始证据和已接受窗口计划，模型联合整理结构与翻译，本地验证后追加 HTML；已有 HTML 和 PDF 批注保持兼容。阅读器用真实任务阶段控制首屏加载与逐步阅读，恢复不重写已发布块。

**Tech Stack:** Swift 6、SwiftUI、PDFKit、Vision、SwiftSoup、URLSession SSE、SQLite、现有 WKWebView。

## 任务 1：联合协议与本地校验

- [ ] 在 `Sources/PaperReaderKit/Domain/Papers/` 定义版本化窗口计划和来源映射，模型以受限来源引用组织块，保留资源和数学标记。
- [ ] 在 `Sources/PaperReaderKit/Infrastructure/Models/` 增加联合重排流解析器；复用 SSE，逐条解析 JSON、校验顺序/范围/完整性，完整块回调先于窗口结束。
- [ ] 为智谱文本/图像重排请求显式配置已实测的低延迟参数；不更改用户模型或问答行为，不把 disabled 宣称为实际零思考。
- [ ] 在 `Tests/PaperReaderKitTests/Infrastructure/Models/` 覆盖碎片流、缺资源、乱序、跨片段合并、公式保护和恢复。运行相关测试与格式检查后提交。

## 任务 2：按需任务、加载页与追加阅读

- [ ] 修改 `PDFImporter` 与 `ImportAndReflowActions` 的导入入口，将深解析延迟到用户选择重排；在线导入不预取结构化正文。
- [ ] `Paper` 增加可选任务检查点与旧制品保留字段，`LibraryState` 显式升级并保留所有旧数据；迁移测试核对批注与笔记。
- [ ] 在 `PaperReaderUI/Application/Reading` 新增任务协调，保存计划后才接受完整块，提交后推进恢复点，取消/晚到事件隔离。
- [ ] 在 `Features/Reader` 增加选择/加载/失败/继续状态，实际首屏就绪后切换，阅读区末尾流式加载；阅读计时排除等待。
- [ ] 复用 `HTMLReadingStore` 与 HTML 平台桥的增量追加；不重新加载已发布节点，旧批注版式保持可访问。
- [ ] 工作流测试覆盖入库无模型调用、原版不重排、连续发布、恢复/去重、保留旧用户记录。检查后提交。

## 任务 3：来源提取、OCR 与复杂区域

- [ ] 在 PDF 导入适配层增加独立证据提取，用可靠文字和几何形成候选；扫描/编码失败区域接入 Vision，保留来源与无法识别区域。
- [ ] 从可靠结构和坐标产生先后约束；图表与公式保存对象，只把文字和受保护标记送入翻译。难区可提供局部图像；原版保留不算翻译成功。
- [ ] arXiv 重排时优先同版本 HTML；静态 LaTeX 来源适配只读取受限文本/资源，不执行 TeX；不支持结构按区域回到 PDF。
- [ ] 对 OCR、版本、资源和源文件边界运行原创 fixture 检查，检查后提交。

## 任务 4：集成、构建与实际窗口验收

- [ ] 执行 `bash scripts/check.sh`，修复影响新流程的失败；记录实际 Mac 与 iPad 构建结果。
- [ ] 在独立测试资料目录通过 App 实际调用用户已授权的模型，检查冷启动、首批内容、续接和原版入口；不覆盖用户旧论文版式。
- [ ] 构建 Mac App 后通过 Computer Use 启动该构建，检查真实窗口；最后为用户打开可验收构建。
- [ ] 更新 README、架构和 MVP 状态，区分实现、真实接口结果与未覆盖边界；检查并创建独立本地提交。将完成提交整合到用户工作目录，不推送远程。
