# AI 结构化重排与翻译统一流程

日期：2026-11-15。状态：完整设计提案，待整体确认；本轮不实现产品代码、不调用真实模型、不更新已有论文库。

## 1. 已确认要求与设计边界

本轮用户明确要求：使用已接入 API 同时完成重排和翻译；保持真正流式输出；按块对应英文原文与中文译文；公式、图片、图表及无用信息不翻译；接入 OCR 辅助。用户进一步确认：普通正文发送文本，允许按需发送难以识别的局部图片给支持视觉的模型；模型必须输出可被本地直接解析使用的结构化数据。

本提案建议采用“本地证据提取 + 一次请求内的结构整理与翻译 + 本地校验发布”。下文的窗口大小、协议、重试预算与交互变化是设计建议，不是已实现或已实测能力。

继续遵守[需求基线](../../requirements.md)、[工程约定](../../engineering.md)与[目录职责](../../architecture.md)：Mac/iPad 独立运行，无 Mac 中转、Python 服务或自建服务器；原始 PDF 不覆盖；Keychain 保存密钥；旧固定页与批注不可改写；新结果仍为本地连续 HTML，HTML 手写另行设计。没有自动云同步或 Obsidian 写入。

这里的“重排”指恢复阅读顺序、标题层次、段落、列表与对象关系。模型不设计像素布局，不生成 HTML/CSS，不重绘图片或公式。最终样式由本地模板确定。

## 2. 当前问题：代码阅读结论

以下来自当前代码检查，不是本轮真实论文成功率评测。

- `PDFImporter` 在 HTML 缺图、部分覆盖不足或保留原页时，会整体放弃结构化 HTML 并重新进入 PDF 路径，局部问题容易影响整篇结果。
- `PDFProcessor` 对无文字、数学符号、复杂图形、旋转和不可靠坐标使用保守判断；区域恢复失败后仍可能保留整页。OCR 尚未接入产品。
- `startTranslation` 要求 `paper.canReflow`，且略过保留原页的块。`translateParagraphs` 只翻译已确定的段落，无法修正上游的分块、顺序或 OCR 错误。
- 现有 SSE、逐段保存和原始资源保留可复用，但现有“固定段落顺序 + 文本边界标记”协议不足以表达结构恢复。

不能通过降低覆盖门槛解决这些问题。新流程应把不确定性作为模型输入和局部修复任务，并保留可核验的来源。

## 3. 方案比较与选择

| Approach | Structure | Translation | Main trade-off |
| --- | --- | --- | --- |
| A: Evidence + joint stream | Model with local evidence | Same request | Recommended; requires protocol validation |
| B: Whole PDF vision | Model from page images | Same long request | High input cost; harder provenance and recovery |
| C: Two model passes | First request | Second request | Explicit stages; extra latency and consistency work |

推荐 A。B 可以减少本地提取工作，但把整篇图像识别、忠实转录和翻译压在一起，长文恢复和来源核验更困难。C 将结构确定后再翻译，工程上清晰，但每个窗口常态需要两轮模型调用。A 在一次响应中先给结构计划，再流式给对应译文，兼顾结构与恢复。

“一次完成”定义为每个正常处理窗口的一次模型请求同时产出结构与译文，而非整篇仅允许一个 HTTP 请求。OCR、本地提取和校验不属于额外翻译调用；局部视觉补救和失败重试可能追加请求，必须记录。

## 4. 总流程

```text
Original PDF ------------------------------> Original reader
     |
     v
Local evidence: PDF text + matched HTML + OCR + assets
     |
     v
Bounded window + source IDs + object IDs + context
     |
     v
One model stream
     |-- window_plan: order / groups / types / source refs
     |-- block_start
     |-- translation_delta ...
     |-- block_end
     `-- window_end
             |
             v
Local validation -> atomic commit -> append bilingual HTML
             |
             +-- unresolved region -> OCR / optional vision retry
             `-- still unresolved -> explicit source region + continue
```

导入先验证文件、计算哈希并安全保存原 PDF，原版立即可读，不等待全篇模型处理。已有模型配置时，由“生成双语版 / 继续”启动联合任务；不因单纯重新打开论文产生调用。无配置时保留原版和本地已准备证据。

前台优先处理开头的可发布窗口；本地预取下一窗口，后台逐步补齐全篇证据。章节目录随确认的标题增长，不等全篇处理完才开始生成译文。

### 与旧体验的明确差异

旧要求是“导入即得到全文英文 HTML，再填中文”。新模型可能合并跨页段落并重判顺序，不能在已经可批注的英文节点上随意重组。

建议新联合模式改为：完整原 PDF 始终可读；最终 HTML 随结构确认及翻译完成逐块出现，当前块的中文可实时预览。未确认部分通过原版查看，不伪装成最终全文 HTML。已入库的旧全文 HTML 继续读取，不自动转换。本项是需要整体确认的体验变更。

## 5. 本地证据与 OCR

### 5.1 证据不等于最终段落

先提取带稳定 ID 的文字碎片、源字符范围、坐标、候选区域和对象，不要求启发式算法已经决定最终段落。PDF 文本层与同版本 HTML 是优先证据；同版本 HTML 缺一个资源，只补该资源或受影响区域。无法证明区域对应时不混入不同来源的正文。

每份证据保存论文文件哈希、提取版本与来源类型。PDF/OCR 保存原页索引和归一化矩形，记录旋转、裁切坐标到原页的变换；HTML 保存来源版本与元素定位。只有验证过的位置才显示为 PDF 页码，无法匹配时允许定位到 HTML 来源块，不能让模型猜页码。

### 5.2 OCR 触发与去重

扫描页、乱码、文本与可见区域明显不符、坐标冲突，以及疑似遗漏正文的区域进入本地 OCR。采用 Apple Vision 的文字识别，保留候选文字、文字框及置信信息。文字识别接口适用于项目最低系统版本；它提供识别候选，不代表已解决论文语义结构或数学识别。[Apple 文档](https://developer.apple.com/documentation/vision/recognizing-text-in-images)；本轮还检查了本机 SDK `VNRecognizeTextRequest.h` 的 macOS 10.15 / iOS 13 起可用声明。

PDF 原文与 OCR 候选不是两份需要各输出一次的正文：为同一区域建立候选组，选取一个来源或保留冲突状态。去重结合位置、文本与候选关系，不能把论文中本来就重复出现的句子按字符串全局删除。

文字识别置信度仅用于安排复核，不能单凭高分宣布正确。对数字、负号、上下标、变量和引用号保守处理；模型提出的 OCR 校正必须引用具体候选或图像区域。不接受无证据的自由“补全文字”。空白页与无法识别的非空页必须区分。

### 5.3 局部视觉辅助

用户已允许按需发送局部图片。能预先识别为困难窗口时，直接在同一个联合请求中加入局部图及其文本/坐标；后续校验发现问题时，仅追加相关区域的补救请求。普通窗口始终以文本和对象引用为主。

图片输入限于所需局部和必要边缘上下文；坐标与本地原图绑定，响应中只能引用已登记图片/区域。扩大裁剪时记录范围；不能可靠确定局部边界时保留该页，不自动上传整篇 PDF。不会把局部截图放到公共图床。

必须显式记录所选服务的文本流式、图像输入、结构化输出支持情况。现有配置没有证明当前模型支持视觉；未支持时仍可使用本地 OCR + 文本联合流程，并提示需要视觉辅助的具体区域，不自动更换供应商或模型。

## 6. 内容分类与翻译策略

| Kind | Translate | Output |
| --- | --- | --- |
| title / heading / paragraph / list_item | Yes | Source + Chinese |
| figure_caption | Yes | Source + Chinese, linked to figure |
| inline_formula | No | Protected object in both languages |
| display_formula / figure / chart | No | Shared original object |
| table / table_caption / table_note | No | Original table group |
| code | No | Original code |
| bibliography | No | Original entries and links |
| front_matter | No | Collapsible source text |
| running_header / page_number / publisher_notice | No | Hidden source record |
| substantive_footnote | Yes | Source + Chinese |
| unknown | No | Visible source + review status |

延续已确认的图注规则：图内标签不翻译，独立图注仍翻译；表格连同表题、单元格及表下注释原样保留。无法与图片分离的图注先保留在原图，不再次生成重复图注。

“无用信息”不交给模型任意判断。页眉页脚、重复刊物标记与页码可隐藏；作者、机构和通讯信息折叠保留。参考文献、附录、方法细节和实质性脚注不是无用信息。模型只能提交分类及依据，自动隐藏还须通过位置、重复性、结构等本地规则；不符合规则的内容默认可见、不翻译。用户可展开被隐藏/折叠的来源。

行内公式由本地生成对象引用，中文中允许合理调整相对文字的位置，但不得改写公式内容、遗漏或复制公式；独立公式、图片和图表只在双语内容间出现一次，供双方选择与引用。可靠的 MathML/SVG 原样复用，否则保留原始局部裁图，不要求模型“修复”为 LaTeX。

## 7. 处理窗口与上下文

窗口按源区域和语义边界建立，不机械地按 PDF 页拆句。建议从约一至两页正文起步，以模型输入/输出预算、图像数量和结构复杂度决定实际大小；这是待测默认值。首窗可以更小以减少首次等待。

每窗包含待处理源片段、可引用对象、标题路径、只读邻接上下文和已确认术语。正文所有权由调度器分配；上下文只读，不得再次发布。跨栏/跨页未闭合段落放入 `carry`，下一窗口接续，前一窗口不把半段作为完整段落发布。

模型可在窗口内纠正顺序。跨窗口的顺序不确定时先扩展未发布窗口或保留原区域；已发布前缀不得重排。超长段落按可核验的源字符范围分成带连续关系的子块，每个子块独立对应译文，不截断句意后冒充完整段落。

缓存键包括原文件哈希、证据版本、源范围、目标语言、服务地址与模型 ID、协议/提示版本及影响输出的设置。没有来源身份一致性就不复用译文；模型温度或提示变更不会覆盖已发布内容。

## 8. 结构化流式协议：本地直接解析

### 8.1 协议边界

新增版本化的 `BilingualReflowStream v1`。传输沿用兼容接口的 SSE，模型 `content` 中输出逐行 JSON 事件（NDJSON），不输出 Markdown、说明段落、代码围栏或任意 HTML。本地使用有界缓冲、明确状态机与严格字段校验，绝不从自然语言猜块边界。

服务原生 JSON Schema 能力可作为额外约束，但必须确认其与多事件流的实际兼容性；不把“支持 JSON 模式”当作支持 NDJSON。基线协议通过提示规定事件格式并在本地强校验；不能遵守协议的模型标记不兼容，不静默转成自由文本解析。

智谱官方对话接口区分文本/视觉请求并提供流式响应。这只能证明供应商有相应接口形态，不能证明用户填写的任意模型或兼容代理都支持同样能力。[官方接口](https://docs.bigmodel.cn/api-reference/模型-api/对话补全.md)

### 8.2 必须包含的事件

| Event | Required payload | Local effect |
| --- | --- | --- |
| window_plan | blocks, dispositions, carry | Validate source coverage and order |
| block_start | block_index | Open current draft |
| translation_delta | block_index, parts | Append typed translation parts |
| block_end | block_index | Validate and commit complete block |
| window_end | block_count | Verify window completion |

所有事件有 `v`、`request_id`、`window_id`、严格递增 `seq` 与 `type`。类型字段使用封闭枚举，拒绝未知版本、非法类型、额外字段、超大事件、重复/缺失序号以及失配 ID。

`window_plan` 是同一响应最前面的结构事件，规模只覆盖当前小窗口。每个块定义 `kind`、有序 `source_segments`、`object_refs`、可选父标题/图注关系；每个源片段包含输入 ID 和明确的 UTF-16 半开范围。源片段的范围不能切断 Unicode 字符；本地验证范围再按原文构建英文。英文不由模型重新生成，因此不会因润色或漏抄而变成另一份“原文”。

空白合并、断行连词等规范化必须有版本化规则和原文映射。非确定的去连字符或 OCR 改字不能混在规范化中静默完成；未能核验时保留原字符或原图。图像识别补充文字先变成可审核的来源候选，再进入发布链路。

`dispositions` 为本窗所有非输出内容注明 `preserve_object`、`collapse_metadata`、`hide_noise` 等允许的去向和规则依据，不能只返回一个模糊 `ignore`。`carry` 是有界未闭合后缀，不能把窗口中间遗漏的任意内容塞入 carry；无法建立后缀关系时重新组织窗口。

`translation_delta.parts` 是有类型的增量数组：`text` 含纯文字，`object_ref` 含本地公式 ID，`citation_ref` 含已提供的引用 ID；不含可执行标签。显示层可把已完成 JSON 记录中的 text 立即追加到草稿，模型须使用短增量事件，不等整个段落 JSON 完成才开始显示。网络可以在任意字节、转义序列或 JSON 行中断开；只有一行完整且校验通过后才向 UI 发送增量。

完整事件序列示意：假设虚构源片段 `s1` 的文本是 `We propose a new estimation method.`，UTF-16 长度为 35。真实窗口计划还会包含其他段落和对象，各块仍按同样事件依次输出：

```json
{"v":1,"request_id":"r1","window_id":"w1","seq":0,"type":"window_plan","blocks":[{"block_index":0,"kind":"paragraph","source_segments":[{"source_id":"s1","start_utf16":0,"end_utf16":35}],"object_refs":[]}],"dispositions":[],"carry":[]}
{"v":1,"request_id":"r1","window_id":"w1","seq":1,"type":"block_start","block_index":0}
{"v":1,"request_id":"r1","window_id":"w1","seq":2,"type":"translation_delta","block_index":0,"parts":[{"type":"text","text":"我们提出一种"}]}
{"v":1,"request_id":"r1","window_id":"w1","seq":3,"type":"translation_delta","block_index":0,"parts":[{"type":"text","text":"新的估计方法。"}]}
{"v":1,"request_id":"r1","window_id":"w1","seq":4,"type":"block_end","block_index":0}
{"v":1,"request_id":"r1","window_id":"w1","seq":5,"type":"window_end","block_count":1}
```

协议实现时将这些事件固化为可随版本测试的 JSON Schema 与 Swift Codable 类型。初始建议每条事件最多 64 KiB、计划最多 128 个源片段引用、单次 text 增量不超过 128 个 Unicode 标量、每窗口响应总量不超过 2 MiB；超过预算则拒绝当前事件并缩小未完成窗口，不静默截断。预算是待离线夹具验证的默认值，不是供应商保证。

### 8.3 流式校验与提交

先收到并验证 `window_plan`，确定本窗全部源范围的去向、对象关系和允许顺序，再接受后续正文流。它是小型结构前奏，不需要等待全批译文。源覆盖必须没有不明缺口或重复所有权，所有引用必须指向输入。自动校验无法证明语义顺序绝对正确；无法由可靠结构证据支持的歧义需视觉复核或局部保留。

每个块按顺序 `start -> delta* -> end`。无翻译的对象块允许零个 delta；应翻译的文本块不允许空译文。正文、公式、引用、对象类型和译文状态完成校验才持久化；`block_end` 只是模型声明，本地提交成功才算完成。

块 ID 由本地生成并落盘，结合版式版本、已接受计划和有序源范围绑定；模型不能指定任意已有块 ID 覆盖用户内容。恢复复用已接受计划的块 ID，不因请求重试重新编号。

## 9. 直接渲染的数据契约与质量门槛

本地最终得到 `BilingualBlock`：稳定块/版本 ID、类型、可验证英文片段映射、中文有类型内容、共享对象、来源锚点、内容哈希和质量状态。模板按类型渲染标题、正文、列表、图注及对象，不依赖解析模型生成的网页。输入资料中的指令始终作为论文内容处理，不能触发工具、文件路径或外部 URL 请求。

质量检查分为三个层次：

1. 协议与来源：输入引用有效、范围合法、顺序状态正确、对象存在，已识别证据有且仅有明确去向。这里的覆盖只证明“已提取证据全部处理”，不能证明 OCR 没漏掉视觉内容。
2. 原页覆盖：可见文字/图形区域与证据区域核对，疑似未覆盖区域进入 OCR 或视觉复核；同时检查裁图是否丢标签、图例、子图和公式编号，是否重复包含已输出正文。避免使用全篇词集合或字符总数作为完整性证明。
3. 译文忠实度：保留数值、单位、引用、公式、否定/限定含义与术语一致性。结构校验和数值检测只能发现部分问题；真实样本需人工对照翻译质量，不用模型自评分宣布通过。

数字文本变体可按明确规则归一核对，异常标为待复核；不能要求所有英文/中文数字字符串机械相同。术语表从已确认结果维护，用户修正优先；不把模型推断当作论文事实。

## 10. 发布、流式交互与失败恢复

```text
evidence_ready -> planned -> streaming -> validated -> committed
                       |          |
                       +----------+-> retry_pending -> retry / preserve_source
                                         |
                                         `-> paused
```

英文来自已校验计划，可以在当前草稿中出现；中文随结构化增量增长。草稿明确处于生成中，不允许创建持久批注/笔记。块提交后开放中英文独立选文、高亮、书签和笔记；图表/公式保持共享对象行为。用户正在阅读的已发布节点不重建，追加时保留视口锚点，不强制滚到末尾。

新 HTML 延续自适应宽度和文本范围锚点，承诺内容/块身份不变，不承诺窗口变化或待译区域增长时屏幕像素坐标不变。原 PDF 和旧固定页的几何不变要求继续独立遵守。

局部内容失败建议最多两次自动补救：先对未发布区域重取 OCR/调整窗口，再在支持且必要时附局部图片。重试不能改动已提交块；预算耗尽后保留具体原文区域，显示“此区域保留原文”，继续后文。边界不能可靠裁出时才保留整页。只有全篇没有可发布正文时以原版为主要结果；不得把原图占位计入成功翻译。

网络、鉴权和存储错误区别处理：401/403 与参数/协议不兼容暂停；429 遵循有上限退避和 Retry-After；断网、未知计费结果默认暂停等待继续；输出上限只对未提交后缀缩小窗口，不无限提高预算。磁盘不足时暂停发布，保留此前提交，不能继续向 UI 宣布已保存。

已完整且本地校验通过的块可以早于整个响应结束提交。后续流失败不撤销它们；恢复从已持久化计划中的未完成块继续。重启丢弃未完成文字草稿、保留已接受计划和提交记录，不把半段译文写入搜索索引。

任务保存论文/版本、窗口/请求 ID、模型配置指纹、证据哈希、计划哈希、已提交块集合及待处理范围。每个块提交带唯一去重键，保证应用内重试不重复追加；不能保证供应商只执行或计费一次。取消或切换模型后，旧 request generation 的迟到事件拒绝发布。

Mac 窗口失焦继续；iPad 真正进入后台可暂停，恢复前台从提交点继续。默认每篇一个活动模型流、本地最多预备下一窗口；问答优先，批量重生成默认串行。OCR 图像按区域生成与释放，不把整篇高分辨率页图同时驻留内存。

UI 显示实际阶段与计数，例如已处理页、已完成双语块、保留原文区域数。未知总块数时不显示虚假百分比。详细报告可以展开错误位置与重试入口，不把协议字段铺满主阅读界面。

## 11. 存储、版本与旧库处理

每篇仍保留原始 PDF、一套当前 HTML 及去重资源。来源映射、最终英中内容、折叠原文、恢复点和质量记录是必要数据；OCR 工作图、未引用裁图、完整原始模型响应和下载中间文件不长期保存。运行日志仅记录 ID、耗时、状态与用量，不含论文原文或密钥。

先写并校验临时阅读制品，再原子发布文件，最后提交数据库引用及任务进度；启动清理仅处理本应用未引用制品。事件到文件/数据库之间崩溃时，以数据库提交记录恢复，不靠当前 HTML 字符数推算进度。继续复用当前 WebKit 文件引用保护。

“重新生成双语版”创建新的内容/版式版本，保留论文 ID、原 PDF 和所有旧用户记录。旧批注、笔记、书签仍打开原依赖版本，不模糊匹配后强行迁移。带依赖旧版属于保留例外，不能为追求一份 HTML 删除用户工作；无依赖旧版仅在新结果提交并释放阅读器引用后清理。

新版任务与来源模型使用显式数据库/快照迁移，迁移编号在实施时按当时最新 schema 分配。新增字段不解释成旧记录已经完成 AI 重排；未知版本拒绝读取而非删库。需覆盖当前旧快照与已发布 HTML/PDF 混合库。

修复已发布的局部原文保留区也产生新版本，不在原版本中插入或合并段落。待处理区域仍可在同一未完成任务中重试。

## 12. 工程职责与实施顺序

```text
PaperReaderKit/
|-- Domain/Papers/              Evidence, SourceSpan, BilingualBlock, Quality
|-- Domain/Reading/             ReflowJob, WindowPlan, CommitCheckpoint
|-- Application/Reading/        Window scheduling and validation rules
`-- Infrastructure/
    |-- PDF/Import/             PDF evidence and local OCR
    |-- HTML/                  Same-version evidence and resource reuse
    |-- Models/                Typed input and structured stream decoder
    |-- HTML/Reading/          Rendering and atomic artifact publication
    `-- Persistence/           Explicit migrations and recovery
PaperReaderUI/
|-- Application/Reading/        Task coordination and cancellation
|-- Features/Reader/            Progress, drafts and source-region status
`-- Platform/HTML/             Incremental DOM and existing selection bridge
```

复用现有网络传输、Keychain、HTML 安全模板、资源管理和批注桥。新流程不继续扩大 `canReflow` 全篇开关的职责，而使用区域质量与任务状态；旧数据适配器保持兼容。View 不直接调用 OCR、模型或数据库。

实施按一个功能的依赖顺序推进：先冻结协议与假服务夹具；再建立证据/OCR/对象层；接入联合流与校验发布；最后连接阅读器、旧库重生成和完整验收。阶段检查不能替代最终跨模块验收，不引入额外服务、云 OCR 必选项或全库自动迁移。

## 13. 验收标准

默认全部使用原创或获许可 fixture、假服务与模拟流。真实 API 与真实论文验证单独明确授权，本轮不执行。

- 协议：任意 UTF-8/JSON/SSE 切片、转义、额外字段、未知 ID、重复事件、截断、输出上限、错序与假 block_end；错误内容不能发布。
- 分块：单/双栏、跨页句子、长段、列表、参考文献、页眉和脚注；每条证据去向明确，重叠上下文不重复，carry 不丢内容。
- 对象：行内公式、独立公式、多面板图、表格/表题、图注及代码；对象哈希不变，图内文字不翻译，译文引用不遗漏不复制。
- OCR：扫描、旋转、坏文字层、PDF/OCR 冲突、识别遗漏、低对比文字；没有证据时不可凭空补写。
- 真流式：前一块中文增量可见时，后一块仍在生成；本地不等全批或全文完成。分别记录 OCR 时间、模型首个结构事件/文字增量时间、首块提交及全篇耗时，不能承诺未经测量的秒数。
- 恢复：在每个提交边界杀进程、断网、取消、磁盘不足、模型配置变化和迟到响应；原始文件、已完成块与批注不变，恢复不重复发布。
- 旧库：混合旧版本、中文/英文部分字符批注、图片书签、独立笔记和依赖旧版式的记录保持可访问；迁移不能删除数据库。
- 质量报告分别统计可翻译正文的完成率、保留原文比例、未识别区域与正文顺序问题；保留整页不能算重排成功。字符覆盖或模型自评分不能代替逐样本核对。
- 实施后运行相关自动化检查及 Mac/iPad 构建；所有视觉验收先构建 Mac 应用，再由 Computer Use 启动该构建检查实际窗口中的流式增长、对象、选文、滚动和恢复。iPad 模拟器构建不能替代触摸真机和内存验收。

## 14. 本轮交付与确认点

本轮交付为设计提案，已阅读现有实现和相关设计、核对 OCR API 可用性及供应商接口文档；未测试真实模型遵守本协议的能力，未完成实现或视觉验收。

整体确认重点是第 4 节的阅读体验变化：完整原版立即可读，最终双语 HTML 随 AI 确认后的内容增长。局部图片辅助、统一重排翻译和结构化输出已经由用户明确要求，无需重复确认。图注翻译与表格整体原样的规则沿用现有确认；其他工程默认值可在不改变产品范围的前提下通过离线测试调整。
