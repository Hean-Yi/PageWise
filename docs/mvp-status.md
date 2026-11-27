# PageWise 验证记录

本文按版本倒序记录实际执行过的自动化测试、真机/真模型抽检与构建校验结果，并明确标注未覆盖边界。

---

## v0.5.0（2026-11-27）Agent 稳定性、阅读交互与检索底座

### 本版本核心验证
- **P1 · Agent 稳定性与阅读交互**：稳定跨轮 KV Cache 前缀与工具轨迹保真、新增只读零增量停滞熔断、修复 4+ 反引号代码块内 `<think>` 误判、放宽非用户编辑记忆的自然修正识别；新增 `fastModel` 双档模型路由与配置后自动续行；优化阅读器顶栏/宽屏页边布局/右侧栏拖拽调宽、笔记来源分层与历史版本一键回滚；为书库搜索、阅读笔记与研究记忆接入本地混合检索。回归验证：`AgentTrajectoryEvalTests`、`ReadingNoteRevisionTests` 共 37 项通过，`swift-format lint --strict` 通过。
- **P2 · 阅读与书库工作流**：新增 HTML 内部引用悬停预览浮窗、书库助理 `@ 论文` 多篇显式点选与论文助读「新对话」/工具调用轨迹展示、`pagewise://open` 双向深链与 Obsidian YAML Frontmatter、封面菜单手动编辑论文标题与来源链接。回归验证：`ObsidianReadingDocumentTests`、`AgentTrajectoryEvalTests`、`NoteWriterTests`（9 项）通过，`swift-format lint --strict` 通过。
- **P3 · 派生向量与离线 OCR**：将 7 个派生语义向量缓存统一收敛至单一 `DerivedIndexes/vectors.sqlite`（WAL 模式 + 命名空间隔离），随后优化为 rowid 行表 + 16 KiB 页 + 大命名空间线性扫描与紧凑连续矩阵 `SemanticVectorMatrix`（`vDSP_mmul` 批量打分，兼容原地迁移旧 `vectors_ns`）；单篇语义索引上限由 `400` 提至 `2,000` 区块，并新增基于 Apple `Vision` 的设备端离线 OCR 引擎 `PDFScannedPageOCR`（`allowOCR` 按需开启，保留无文字层扫描页默认原排回退不变量）。在 Apple M2 / 8 GiB Release 实测（384 维合成单位向量）：对比优化前，20 万条 SQLite 文件体积缩小 64%（`894 → 323 MiB`），冷启动+首查提速 19.3×（`22.8 s → 1.18 s`），端到端 `SemanticPassageIndex.matches` 热查询 p50 提速 55×（`755 → 13.7 ms`）；同机对比静态编译的 `sqlite-vec v0.1.9`（ARM NEON），热查询比 `float32` 快 16–37×、比 `int8` 快 5× 且保持 100% 精确召回，因此不引入第三方 C 扩展。回归验证：`SemanticVectorMatrixTests`、`SemanticPassageIndexTests`、`RetrieverTests` 共 16 项通过，`swift-format lint --strict` 通过。
- **0.5.0 打包与分发校验**：`bash scripts/package-mac.sh` 生成 `Artifacts/PageWise-0.5.0-macOS.dmg`（78 MB，Build 6，SHA-256 `22c9fc379000c74d78e4a5957133c2c2834ffa87b6b6662da094f3ddfd78665c`），通过 `arm64 + x86_64` 双架构校验、严格代码签名校验、零本机路径泄漏检查、内置资源逐文件比对与 `hdiutil verify`。
- **回归验证**：2026-11-27 全量 817 项测试中 813 项直接通过；4 项 macOS UI 时序用例在并行下偶发失败，串行复跑全部通过（`selectingAnOriginalPDFQuoteOpensTheFloatingNoteActionAtItsExactRange`、`iconButtonActivatesOnceAndItsInkReturnsToRest`、`wrappedNoteHoverCanCrossToFloatingPreviewWithoutMovingIt`、`marginNoteHoverTracksWrappedTextAndCardWithoutMeasuringOtherPages`）；`swift-format lint --strict` 通过。

### 未覆盖边界
- 0.5.0 发布前未执行 iPad 模拟器/真机构建与自动化 Computer Use Mac 窗口视觉验收；Mac Release DMG 已构建并通过签名、架构、资源与校验和检查。
- 真实模型结果受服务商版本与网络波动影响，静默笔记整理链路已跑通但复杂改写质量与大书库长测仍待后续评估。

---

## v0.4.0（2026-11-27）设备端语义记忆、Agent 编排与界面性能

### 本版本核心验证
- **4-bit 内置语义检索与 FTS5 混合底座**：
  - 将 4-bit 量化 `multilingual-e5-small` Core ML 模型（约 61 MB，权重 SHA-256 `8a00cee4...`）随包内置，阈值统一为 `minScore = 0.15`，配合渐进式冷启动与覆盖度门控、SQLite `FTS5` BM25 论文检索落地。
  - 在 Apple M2 / 8 GiB 上对照实测：12 条未调参独立科研集 Top-1 `11/12`、Top-5 `12/12`（MRR@5 `0.944`）；100 条 Tatoeba 中查英 Top-1 `90/100`、Top-5 `95/100`（较 FP16 仅差 1 条，P95 从 182.7 ms 降至 69.7 ms）；100 条笔记首查词项返回约 `64 ms`，后台预热完成后热查询约 `20–33.5 ms`、峰值 RSS 约 `175 MiB`。
- **Agent 编排、记忆安全与离线评测**：
  - 统一 `AgentLoopRunner` / `AgentContextCompactor`，覆盖循环检测、同轮只读工具并发、Prompt Cache 稳定前缀、实时 `<think>` / `reasoning_content` 思考流、双时态记忆（`validFrom`/`invalidAt`/`supersededBy`）、显著性衰减、`expected_revision` 乐观并发校验、书架作用域隔离与 `NoteReview` 静默分页修订。
  - 新增脱敏 HTTP Cassette 离线轨迹评测框架（`AgentTrajectoryEvalTests`）；2026-11-26 全量串行回归通过 **738 项**自动化测试与严格 `swift-format` 检查。
  - 真实 DeepSeek（`deepseek-flash`）在隔离复制书库上复测通过：`propose_memory` → `revise_memory` → `forget_memory` 全链路（5.7 s）、自然工具选择与本地遗忘快路径（5.0 s）、只读并发检索零命中区分（3.2 s）、`read_paper` 跨页定位引用（6.7 s）、中英文及临时偏好覆盖（6.1 s）、静默笔记整理（0.8 s）与空闲记忆合并（1.4 s）。
- **快速上手引导与侧边栏/书架动画性能**：
  - 引导从 11 步精简为 6 步，新增「如何记录笔记」流程示意与可交互「笔记悬停状态展示」预览，并改为先预加载内置示例再切步。
  - 修复 macOS 左右侧栏开合期间书架逐帧重排与“先变大后变小”问题，书封改用标准版面 GPU 缩放与 `shadowPath`，缓存 `ReaderTheme.editorial` 字体，WebKit 窗口缩放防抖 48 ms。
  - 回归验证：`QuickStartNavigationTests`、`WorkspaceNavigationViewTests`、`ShelfCoverCanvasTests`、`ReadingNoteCardTests`、`ReadingNoteHoverTests`、`PDFMarginNoteTests` 共 21 项通过；`swift-format lint --strict` 通过。
- **0.4.0 打包与分发校验**：
  - `bash scripts/package-mac.sh` 生成 `Artifacts/PageWise-0.4.0-macOS.dmg`（77 MB，SHA-256 `fb4819d54eb7ca9ea8747ea6519d9c8c9c35839a49c261d19b393065e541c2c6`），通过 `arm64 + x86_64` 双架构校验、严格代码签名校验、零本机路径泄漏检查、内置资源逐文件比对与 `hdiutil verify`。

### 未覆盖边界
- 2026-11-27 界面性能优化与引导改版后，按用户要求交由用户直接体验验收，未执行自动化 Computer Use 视觉回归，也未完成全量 `scripts/check.sh` 与 iPad 模拟器/真机验收。
- 真实模型结果受服务商版本与网络波动影响，静默笔记整理链路已跑通但复杂改写质量与大书库长测仍待后续评估。

---

## v0.3.0（2026-11-25）科研助理、AI 精读与增量索引

- **全量回归与真模型验证**：全仓 **645–715 项**自动化测试通过；真实 DeepSeek 在隔离库中验证提议/回顾/删除研究问题闭环，以及 26 页公开论文 [SR-OPSD](https://arxiv.org/abs/2608.09745v2) 重新精读（保存 38 条页边批注、8 节文末笔记、31 处文末依据，离线复核 244 个片段全部可重新定位）。
- **增量事件与热保存性能**：在 48 篇、3,840 个区块的合成隔离库中，24 次工作区/译文保存与分钟计时检查耗时约 `0.11–0.126 s`，不生成事件也不触发简报重建；Apple M2 Debug 样本中 320 段连续核验 12 处引文从 `2.412 s` 降至 `0.025 s`，连续追加 16 份阅读快照从 `0.088 s` 降至 `0.036 s`。
- **增量事件与静默修订回归**：覆盖事件去重、事务回滚、租约互斥与续租、分批发布、派生表删除重建、冲突笔记小幅修订与含糊遗忘回退模型路径。

---

## 历史专题验证归档（2026-11-16 ~ 2026-11-24）

### 2026-11-24 · 多来源论文检索
- 原生 Mac 窗口验证 arXiv / Crossref 检索、开放 PDF 下载、出版页后备入口与单源超时提示；通过 Crossref DOI 从 ACL Anthology 实际下载导入 16 页 BERT 正式版与 18 页 EMNLP 论文，Semantic Scholar 返回 3 张相关推荐卡；DBLP 路径由离线样例覆盖。
- 严格格式检查、451 项自动化测试与离线 TeX 冒烟通过；iPad 验证范围为模拟器构建。

### 2026-11-23 · 英文断词、首页署名与参考文献
- 在 33 篇 PDF / 196 页固定样本上对照基线：图片化原排片段由 `1,500` 处降至 `803` 处，可选非表格文字由 `435,143` 增至 `517,375` 字符，31/33 篇首页提供结构化署名；参考文献支持编号制、作者年份制与同页附录恢复翻译；标准 TeX 署名与引用由设备端静态解析。
- `bash scripts/check.sh` 通过 300 项自动化测试、离线 TeX 冒烟及 Mac/iPad 模拟器构建。

### 2026-11-22 · 本地 PDF 段落重排、连续阅读与可选表格
- 完成本地 PDF 逐句提取、当前页优先的后台全文翻译队列、跨页连续阅读（窗口化前后页加载与回收）及原页图表/规则表格提取。
- 在 33 篇 / 196 页离线样本对照中，随正文直显图表从 `115` 处增至 `144` 处（96 表、48 图），可逐格复制表格从 `13` 张增至 `19` 张；多篇真实论文在 Mac 隔离窗口中核对中英文双向定位、暂停续译、表格一键复制与图表就地放大，导入副本 SHA-256 与源文件一致。
- 各里程碑均通过 `bash scripts/check.sh`（测试数由 234 增至 283 项），iPad 真机手势与 Pencil 交互待真机验收。

### 2026-11-16 · 线上源码重排路线收敛
- 收敛在线论文路线为静态 TeX / 同版本 HTML 重排（原始 PDF 与历史批注保持读取兼容），快照升级至 v9。
- 通过 222 项自动化测试、离线 TeX 冒烟、Mac/iPad 模拟器构建及 Mac 实际窗口排版检查（公式、SVG、表格与原版 PDF 导入）。
