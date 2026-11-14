# 技术选型草案

日期：2026-11-13。此文保留已评审的长期选型方向。截至 2026-11-14，MVP 使用 Core Text 处理普通文字，WKWebView 处理净化后的 HTML/MathML，并使用系统 SQLite；未引入 GRDB、FTS5 或 KaTeX；实现与验证结果见 [MVP 状态](mvp-status.md)。下面的候选技术不能视为已经全部接入。

## 1. 总体方案比较

三种方案都可以使用 SwiftUI 应用外壳。主要差别在于论文排版与持久化方式。

| Option | Reader | Strength | Cost | Recommendation |
| --- | --- | --- | --- | --- |
| A | WebKit typesetting -> immutable PDF pages -> PDFKit + ink | Fixed geometry; rich layout | Pagination and anchor mapping | Preferred, validate first |
| B | Core Text / native typesetting -> PDFKit + ink | Native rendering control | Math and complex table layout | Fallback renderer |
| C | Live HTML / WebKit + ink overlay | Flexible reflow | Ink movement and cross-device drift | Not for the fixed-page reader |

推荐 A：SwiftUI 管理书库、导航、问答、日历和设置；受控的 WebKit 负责双语内容排版；完整且通过检查的页面转为不可变 PDF 页面；PDFKit 展示，iPad 用 PencilKit 采集手写。WebKit 在此是应用内排版工具，不是在线网站，不依赖部署服务。

B 可以作为 A 的局部替代：若 WebKit 导出导致正文不可选择、字体不稳定或锚点不可靠，则使用原生文字排版加公式/图表资源，保持外部页面契约不变。C 适合预览，但不满足已确定的跨设备固定手写版面，因此不作为正式阅读器。

Apple 提供 [WebKit PDF 导出接口](https://developer.apple.com/documentation/webkit/wkwebview/createpdf(configuration:completionhandler:))，也介绍了 [PDFKit 页面叠加视图与 PencilKit 的结合](https://developer.apple.com/videos/play/wwdc2022/10089/)。这些能力支持原型方向，但不保证复杂论文会自动正确分页；分页、文字选择、公式及坐标映射必须自行验证。

## 2. 推荐技术组合

| Area | Choice | Status |
| --- | --- | --- |
| App UI | Swift 6 + SwiftUI | Preferred |
| Platform bridge | AppKit / UIKit | At platform boundaries |
| PDF reader | PDFKit | Prototype required |
| Handwriting | PencilKit + portable preview | iPad capture; Mac display |
| Typesetting | Local HTML/CSS + WKWebView; Core Text | Implemented; limited fixture validation |
| Math | Existing MathML / bundled KaTeX / source crop | Capability-based fallback |
| Local records | SQLite + GRDB | Preferred |
| Search | FTS5 + bilingual tokenization + structural retrieval | Initial RAG baseline |
| Model transport | URLSession + GLM / compatible chat adapter | No provider SDK required |
| Credentials | Keychain | Device-local |
| App sync | CKSyncEngine + private CloudKit database | After membership |
| Obsidian files | User-selected directory + coordinated writes | Independent of app sync |
| Tests | Swift Testing + XCTest / XCUITest | After project creation |

SwiftUI 的多平台目标能共享代码，平台框架和交互仍需要边界适配，见 [Apple 多平台配置文档](https://developer.apple.com/documentation/xcode/configuring-a-multiplatform-app-target)。macOS 最低 15，iPadOS 暂定 18；不依赖系统大模型或仅新硬件可用的能力。

公式优先保留来源中的数学结构；KaTeX 仅处理其支持的内容，资源随应用打包。设置不信任输入并限制展开；不支持的公式不得以红色错误文本充当成功渲染，可改用有原始锚点的图像或回退原始 PDF。[KaTeX 选项文档](https://github.com/KaTeX/KaTeX/blob/main/docs/options.md)

## 3. 为什么采用显式本地存储

SQLite + GRDB 便于把领域记录、恢复检查点、全文检索和同步 outbox 放在明确的事务边界中。[GRDB 官方项目](https://github.com/groue/GRDB.swift) 支持所需 Apple 平台，提供迁移与 FTS5 能力。具体版本在创建工程时锁定，不使用浮动分支。

SwiftData + 自动 CloudKit 同步也是可选方案，通常能减少初期代码；本项目需要不可变页面、手写冲突分支和可追踪的记忆修订，因此倾向于显式控制同步与迁移。代价是同步逻辑和测试工作更多，必须单独安排阶段，不能当作启用开关即完成。

## 4. 论文来源与解析

首先实现 arXiv 检索和本地 PDF 导入。通过 [arXiv 官方 API](https://info.arxiv.org/help/api/user-manual.html) 获取真实元数据与候选结果，缓存并遵守服务限流；模型仅帮助理解查询或解释候选。

优先使用与选定论文版本对应的结构化 HTML，并下载原始 PDF。arXiv 明确说明 HTML 覆盖和转换质量尚不完整，不能假设每篇论文都存在或完全正确。[arXiv HTML 说明](https://info.arxiv.org/about/accessible_HTML.html)

普通 PDF 先做本地文字与布局分析，只在阅读顺序、资源完整性和锚点可靠时重排。当前混合文档中的复杂页完整保留原始页面，可靠文字页重排；纯扫描件与全篇复杂文档进入普通 PDF 模式。OCR 不是第一阶段必须成功的环节；不引入必须由服务器运行的 PDF 转换服务。

非 arXiv 元数据来源放在独立检索适配器中扩展；首版先通过可测的来源和手动导入完成闭环，不宣称可搜索整个互联网的所有论文。

## 5. GLM 与 RAG

使用 URLSession 直接调用用户配置的端点；GLM 官方标准 API 默认候选地址为 `https://open.bigmodel.cn/api/paas/v4/`，具体使用的区域、套餐端点和模型由用户配置，不把某个模型名或上下文窗口写死。智谱提供兼容接口，同时说明部分场景存在差异。[GLM 兼容文档](https://docs.bigmodel.cn/cn/guide/develop/openai/introduction)

翻译、问答和 Memory 默认共享服务及模型设置；用不同提示模板和预算管理任务。能力描述单独记录流式输出、视觉输入、上下文长度等。对话接口具备的能力不等于所选模型都支持，接入时按实际模型验证。[GLM 对话接口](https://docs.bigmodel.cn/api-reference/模型-api/对话补全)

RAG 不以向量数据库为前提。第一阶段采用结构化全文块 + 本地 FTS5 检索 + 查询改写/必要的候选重排；中文笔记增加分词索引并保留原始字符位置，英文使用对应分词策略。需要以实际中英文问答集衡量召回率，不能只验证英文关键词搜索。

预留 EmbeddingProvider；若语义检索评估不达标，再选择可在两端运行的多语言嵌入模型或同服务的独立 embedding API。聊天模型不自动等于 embedding 模型，第一阶段不要求用户新增供应商或密钥。

## 6. iCloud、Obsidian 与开发者会员

应用的正式同步采用私人 CloudKit 数据库 + CKSyncEngine；每位使用者访问自己的 iCloud 数据。数据库、附件和冲突语义由应用管理。Apple 的 [CKSyncEngine 官方样例](https://github.com/apple/sample-cloudkit-sync-engine) 给出了本地状态与云端同步的参考，也明确要求有效会员创建 CloudKit 容器。

本地构建不包含必须依赖会员的 CloudKit entitlement。未来再加入启用云能力的构建配置，完成真机同步和账号隔离验证。中间阶段通过版本化导出/导入包验证资料跨设备保真；它不等价于自动同步。

Obsidian 继续使用现有 iCloud Drive 笔记库，通过系统文件选择器获得指定目录权限，采用协调读写及书签恢复。Apple 支持 [用户选择外部目录及后续访问](https://developer.apple.com/documentation/uikit/providing-access-to-directories)，但 Obsidian 实际目录在两端的授权、移动和下载行为仍需真机验证。

不同时实现另一套通用 iCloud Drive 应用数据同步系统：用户已经接受成熟后购买会员，先做第二套冲突引擎会增加维护成本。系统选择器访问 Obsidian 文件与 CloudKit 应用同步保持独立。

免费账号可用于自己的设备测试，但个人团队的设备配置描述文件有期限；不能把它包装为朋友长期使用的完成方案。[Apple 账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account) 成熟后再用会员支持的分发方式，见 [Apple 分发说明](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)。

## 7. 尚需实测、不会在文档中假定通过的事项

- WebKit 生成页面的文字选择、字体、数学渲染与 PDF 坐标是否满足固定页契约；失败则选择 B 或降低支持文档范围。
- iPad 上解析与排版的内存峰值、字体资源、图表完整性和持续运行表现。
- PencilKit 笔迹在缩放、翻页、重启及 Mac 展示时的位置和清晰度。
- iPad 对实际 Obsidian iCloud 目录的持久授权及冲突处理。
- 中文问句检索英文论文和中文笔记时的证据召回；不足则扩展语义检索。
- CloudKit 自动同步与会员分发属于后续真实验证，当前不能替代为模拟通过。

## 2026-11-14 已接入的 HTML 分支

SwiftSoup 固定为 2.14.3（MIT，Swift 6，最低 macOS 12 / iOS 13，满足本工程目标），解析并重新构造允许的正文元素与属性。许可证随 PaperReaderKit 资源包提供。MathML 使用系统 WebKit 渲染，不执行下载的 TeX 或脚本。WebKit 使用非持久化存储与禁止外部请求的 CSP；只加载应用模板和验证后内嵌的图片。

固定页通过 CSS 分栏和显式 PDF 导出生成；文字、公式和资源边界接受几何检查，内容块跨页保留稳定 ID。HTML/PDF 页码只做唯一文字匹配，另以逐页普通词项覆盖检查拦截明显缺失的转换，不能视为语义完整性的证明。正文、图表复杂性和真实 arXiv 覆盖率仍需更多样本验证。

规范化富内容只在对应固定页提交前存在，提交后移除；完成时执行 SQLite 空间回收。临时制品清理不会删除已提交页面、原版或用户批注。详见 [重排设计](superpowers/specs/2026-11-14-structured-reflow-design.md)。

## 2026-11-14 统一图片处理

图片按字节识别格式，扩展名与响应 MIME 仅是来源信息。SVG 通过 XMLParser 构造静态图片文档，保留路径、文字、变换、渐变、裁剪、遮罩、内部引用和受限样式，去掉脚本、事件和 SMIL 动画；嵌套图片按同一版本规则本地化。作为独立 data URI 图片交给 WebKit，避免多个图件的样式和 ID 相互污染。外部样式/字体、CSS 动画或未支持元素会触发单图提示，不执行作者程序。SVG 内文字不翻译。

位图经 ImageIO 解码和方向修正，保留透明度，统一成兼容 PNG；最长边超过 4096 像素时缩小并提示。GIF/APNG/WebP 动画取首帧并提示；TIFF/HEIF 多图和 PDF 图件最多 16 页，逐页呈现，超出预算不悄悄丢页。PDF 图件当前使用 CoreGraphics 以最高 3 倍、最长边 4096 像素绘制为图片，不宣称 PDF 图件也保持矢量。实际格式覆盖取决于目标系统的 ImageIO 解码器。

图件与图注保持内容块关联，使用独立页；宽幅图增加页宽，长图增加页高，生成后不可重算。极端长图保持比例并限制显示高度 3500 点，多页图件允许在图片之间分页；几何检查仍阻止越界内容发布。资源限制为单次下载 12 MB、累计下载 60 MB、嵌入 HTML 80 MB，SVG 嵌套最多 3 层；超限只替换对应图件。不能可靠恢复的原页位置不猜测。

SVG 原生文本及导出器 `data-text` 字形标记可辅助逐页词项覆盖核验，避免把已经在图中保留的文字误判为正文缺失。这是启发式检查，不证明图中文字阅读顺序，相关标记不会发送给翻译模型或进入正文证据；对应固定页提交后与富内容一起清除。
