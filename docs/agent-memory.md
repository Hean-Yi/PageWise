# 研究记忆与科研助理设计

> **状态导读：** 第 1–5 节描述 **v0.4.0 已落地并经测试验证的机制与实测数据**；第 6 节明确列出**后续规划项与发布门槛**，不将规划项描述为已实现能力。

PageWise 的研究记忆旨在清晰区分三件事：**「我收集了什么」**（书库与书架）、**「我实际追查过什么」**（笔记、讨论与阅读活动）、**「我目前认为或希望什么」**（个人偏好与长期判断）。所有记忆均保留可追溯来源，读者可随时在「设置 → 研究记忆」中查看、修订或删除。

**核心约定：** 本应用不引入独立于书架的“项目”对象——**一个书架即一个研究主题/项目**（`Scope.shelf`），书库为全局范围，单篇论文为局部范围。

---

## 1. 日常问答如何召回与保护来源

| 读者想问的问题 | 实际数据与入口 | 能力与边界 |
| --- | --- | --- |
| **我在哪篇笔记里写过这个观点？** | `search_reading_notes` 对笔记正文做本地词项 + 语义检索 | 支持论文标题与笔记正文查找，自动剔除嵌入的引用标签；原文定位由独立原文入口提供 |
| **这篇论文具体说了什么？** | `search_library`、`read_paper` 与论文内问答 | 仅引用可定位的原文或已发布段落；仅有题注时不凭空臆测图表细节 |
| **我最近在研究什么？** | `research_overview` 读取书架统计、跨论文主题线索与活跃记忆 | 同篇论文多条笔记只计一篇；无查询词返回概览，带查询词或 `*` 返回最多 5 条相关记忆（用户修订优先） |
| **它记得我的哪些习惯与关注点？** | 双入口共用回答偏好与长期记忆；`MemoryItem.sourceID` 可回溯原对话 | 空提取或纯引用他篇笔记时不重复存记忆；已删除命题保留规范化 SHA-256 抑制指纹，防止自动复活 |
| **上次聊到哪里了？** | 书库助理保留近期完整工具轮次（默认 6 轮）；论文讨论随论文保存 | 短期会话、个人研究记忆与文末笔记三者独立存储 |

### 来源校验与防污染机制
- **来源版本跟踪（`ChatSourceVersions`）**：新问答与 AI 生成笔记会记录实际读过的记忆指纹、失效时间（`invalidAt`）与笔记修订时间；续问与自动检索只复用来源仍有效的记录。
- **中途撤回保护**：生成过程中若某条记忆被删除或改写，应用立即停止采纳该结果；来源修改后依赖旧判断的 AI 笔记仍可在原位查看编辑，但不再进入 Agent 自动检索。
- **双时态与显著性衰减**：`MemoryItem` 支持 `validFrom`、`invalidAt`、`supersededBy` 与显著性衰减（自动记忆 60 天半衰期、下限 `0.35`；用户手改与明确偏好免衰减）。
- **乐观并发与用户优先**：`revise_memory` / `forget_memory` 校验 `expected_revision`；读者明确说出“记住/更正/忘掉某条”且目标唯一时优先走本地快速路径，模型绝不能覆盖用户手动修订。

---

## 2. 空闲整理与静默笔记修订

### 增量事件与设备端索引
- 论文导入、笔记编辑、讨论、移架与删除在主库事务内写入 `research_events`（仅存稳定 ID、修订哈希与归属，不含正文）并推进 `research_generation`；阅读位置、工作区与翻译保存**不产生事件**。
- 前台空闲时按批（每批最多 256 条）消费事件并原子发布 `research_brief` 与水位；`research_maintenance_lease` 防止并发整理。派生索引损坏或删除后可从主库完整重建。
- 打开论文、开始翻译或写笔记会按论文/日期去重记为 `paperEngaged` 观察事件，用于后续整理。

### 空闲记忆整理（`MemorySleep`）
- **触发条件**：默认开启（可在「设置 → 研究记忆」关闭），应用前台运行、至少 2 分钟无读者操作、无进行中的对话/导入且非低电量模式时自动运行；模型调用按所选服务计费。
- **整理范围**：每批最多 20 条待处理记录、8 条同范围既有记录与 12 条相关归纳（单条截断至 400 字），排除回答偏好类记录。
- **安全写入**：模型可精炼、合并重复项、关联同题或并列冲突，通过来源代次与修订校验后原子写入 SQLite 的 `memory_sleep` 表，立即供双入口助理复用（`effectiveSleepMemory`），同时完整保留原记录溯源；手动修订与明确偏好受保护。

### 静默笔记整理（`NoteReview`）
- **触发条件**：默认关闭，开启后可按 30 分钟至 1 天的间隔在空闲时运行，也可在设置页手动触发；与 `MemorySleep` 互斥。
- **保守修订**：通过 `NoteReviewCursor` 分页扫描有变化的笔记（每批最多 8 条目标、每条最多 4 个 E5/词项近邻，输入约 6,000 tokens、输出上限 800 tokens），按相似 / 冲突 / 重复 / 范围不同组织紧凑关系图。
- **防大幅改写与可回退**：提示词限制仅做局部补充，程序结合 `CollectionDifference` 校验并拒绝大幅重写；新正文直接追加为新修订并保留旧版本历史，写入 `backgroundSources`。阅读器「笔记」侧栏支持查看修订历史并一键恢复至读者原版或其他历史版本。Obsidian 仍只在用户主动导出时更新。

---

## 3. Agent 工具目录（共 24 个）

书库助理与论文助读共用 `PaperReaderKit` 中的 `AgentLoopRunner` 与 `AgentContextCompactor`（默认上限 16 轮 / 48 次调用，同轮只读工具并发执行、写操作串行，首轮即注入预算并在尾部与跨轮历史中保持 Prompt 前缀逐字节稳定以命中服务端缓存；内置精确重复、交替乒乓及连续三轮零新增资料熔断）。每轮仅开放当前可用子集：

| 分类 | 工具名 | 作用与权限约束 |
| --- | --- | --- |
| **研究与资料检索** | `research_overview`、`search_reading_notes`、`search_library`、`read_paper` | 按全局/书架/论文范围查询；`research_overview` 默认仅作内部锚点，读者主动要求时才展示来源 |
| **发现与呈现** | `search_online`、`recommend_related`、`present_results`、`prepare_import`、`open_paper` | 区分检索失败与零命中；下载与跳转生成可点击结果卡 |
| **精读与笔记** | `close_read_paper`、`create_reading_note`、`ask_user` | 按本轮委托触发，引文必须通过本地定位校验 |
| **偏好与记忆维护** | `remember_preference`、`propose_memory`、`revise_memory`、`forget_memory`、`propose_research_question` | 受来源、删除墓碑、唯一目标与 `expected_revision` 校验保护；所有静默写入记录本地审计哈希 |
| **书库管理** | `list_library`、`prepare_local_import`、`create_shelf`、`rename_shelf`、`move_papers`、`prepare_delete_paper`、`prepare_delete_shelf` | 按明确意图开放；永久删除论文必须由窗口系统对话框确认 |

---

## 4. 本地 4-bit 语义检索与实测基线

### 为什么内置 4-bit 量化模型
早期对照实验比较了「纯词项 + 本地术语表（A 方案）」「原始 FP16 `multilingual-e5-small`（约 240 MB）」与「4-bit 调色板量化 Core ML 版（`per_tensor` k-means LUT，约 61 MB）」。静态术语表在未见过的科研表达上泛化明显受限（独立集 Top-1 仅 5/12，开放域 Tatoeba 1/100），而 4-bit 量化版在将模型体积压缩约 75%、峰值内存降至约 175–337 MiB 的同时，基本保持了与 FP16 一致的跨语言召回质量。

因此 **v0.4.0 已将 61 MB 的 4-bit 模型随 App 打包**（`Sources/PaperReaderKit/Resources/Embeddings/e5-int4/`，阈值 `minScore = 0.15`），并与 SQLite `FTS5` BM25 组成混合检索：
- **启动即搜（渐进式冷启动）**：首查不等模型预热，先返回词项结果（实测 100 条笔记约 64 ms），同时后台完成向量索引预热；全量就绪后自动切换混合语义检索，避免半截向量子集扭曲排序（覆盖度门控）。

### 实测对照数据（Apple M2 / 8 GiB）

| 数据集与指标 | 纯词项 / 本地术语表 | 4-bit 量化 + 混合 | 原 FP16 E5（参考） |
| --- | ---: | ---: | ---: |
| 12 条未调参独立科研集（Top-1 / Top-5） | 5/12 / 7/12 | **11/12 / 12/12** | 11/12 / 11/12 |
| 100 条 Tatoeba 中查英（Top-1 / Top-5） | 1/100 / 1/100 | **90/100 / 95/100** | 91/100 / 96/100 |
| 模型磁盘占用 | 0 MB | **61 MB** | 约 240 MB |
| 22 条笔记热查询 P95 / 峰值 RSS | 1–3 ms / 38 MiB | **约 20 ms / 175 MiB** | 27 ms / 489 MiB |

> 完整测试代码见 [SemanticQualityProbe.swift](../Tests/PaperReaderKitTests/Application/Retrieval/SemanticQualityProbe.swift)。公开语料来自 [LASER Tatoeba v1](https://github.com/facebookresearch/LASER/tree/fec5c7d63daa2bea9d127e8252b10e87278586c0/data/tatoeba/v1)，上游权重为 MIT 许可的 [intfloat/multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small)。更大书库、长笔记与 iPad 真机性能仍需单独验收。

### 本地复测命令
```sh
export PAGEWISE_BENCH_MODEL="$HOME/Library/Containers/dev.paperreader.mac/Data/Library/Application Support/PageWise/Models"
swift test --filter measureInstalledSemanticRetrieval
```

---

## 5. 数据流与架构参考

```text
书库事务 ──▶ research_events ──▶ 设备端词项 / FTS5 / 4-bit 向量索引
                 │                               │
                 ▼                               ▼
      空闲整理 (MemorySleep / NoteReview)   按作用域混合召回
                 │                               │
                 ▼                               ▼
         来源与版本校验后原子提交 ──────────▶ 论文助读 & 书库助理
```

设计参考了公开的异步记忆整理与客户端工具边界思路（Anthropic Dreams / Memory tool、LangMem、Letta、Mem0），并结合 PageWise 的本地单库特性补充了论文版式版本、引文级溯源与用户修订绝对优先规则。

---

## 6. 后续规划与评测门槛

### 已落地的评测底座
- **离线 HTTP Cassette 回放与轨迹评测**：[AgentHarnessSupport.swift](../Tests/PaperReaderWorkflowTests/Support/AgentHarnessSupport.swift) 与 [AgentTrajectoryEvalTests.swift](../Tests/PaperReaderWorkflowTests/Assistant/AgentTrajectoryEvalTests.swift) 支持脱敏录制/离线回放，自动化断言 Prompt Cache 前缀逐字节稳定、过期 `expected_revision` 拒绝、用户手改保护、正文内 Prompt Injection 防御与伪造引文清洗。

### 后续规划项（尚未实现）
- `MemorySleep` 跨论文主题级归纳与可回滚版本历史界面；
- 独立笔记关系浏览界面；
- 大规模书库（千级以上段落）下评估静态集成 `sqlite-vec`；
- 扩充至 30–50 条双语多轮合成学术轨迹基准并结合真模型定期盲评；
- iCloud 跨设备记忆合并与冲突保留。

### 关键质量门槛（作为迭代验收标准）
- **确定性安全红线**：用户修订被覆盖率 = 0%、已删记忆复活率 = 0%、幻觉引用率 = 0%、文档内注入越权率 = 0%、Prompt 前缀逐字节稳定率 = 100%。
- **跨语言检索目标（Apple M2 / 目标 iPad）**：混合检索 Recall@5 显著优于纯词项基线，离线精确编号命中率 100%，冷启动首查无阻塞且不返回未预热失真排序。
