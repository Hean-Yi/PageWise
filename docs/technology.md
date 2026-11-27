# 技术现状

本地应用基于 Swift 6、SwiftUI 与结构化并发构建，最低支持 macOS 15 / 暂定 iPadOS 18。下表仅列出仓库当前实际使用的技术与职责，不代表框架能力已全部接入。

| 技术 / 模块 | 当前实际用途 |
| --- | --- |
| SwiftUI / AppKit / UIKit | 页面布局、原生拖放、书架封面动画与平台桥接 |
| PDFKit | 原版导入校验、展示、选择、目录提取、逐句字符定位与历史固定页读取 |
| SwiftSoup / WebKit | 静态 HTML 净化与本地连续双语阅读、页边笔记卡片与实时 Markdown/LaTeX 编辑 |
| JavaScriptCore / KaTeX | 将受支持的 LaTeX 公式本地编译为静态 MathML |
| ImageIO / CoreGraphics | 源码图件与 PDF 裁剪区域本地解码，支持独立 PDF 图件 |
| SQLite（含 FTS5） | 按记录事务保存书库快照与显式迁移；代次校验防并发覆盖；内置 `FTS5` BM25 论文检索、研究来源事件表、事件水位与整理租约 |
| 词项索引、Core ML 与 Accelerate | 随包内置约 61 MB 的 4-bit 量化 `multilingual-e5-small` Core ML 模型（开发构建亦保留按需下载路径），结合渐进式冷启动与覆盖度门控执行设备端中英混合语义检索 |
| URLSession | arXiv / Crossref / DBLP / Semantic Scholar 多源并发检索、限量流式下载、模型 SSE（含思考流）与有界工具循环 |
| Keychain | 按服务地址隔离保存设备本地 API 凭据 |
| PencilKit | iPad 原版 PDF 与历史固定页手写批注 |

在线论文采用有界静态解析处理 TeX 或同版本 HTML；本地导入的 PDF 使用独立的设备端段落提取与图表裁片流程；双入口助理共用 `PaperReaderKit` 内的 `AgentLoopRunner` 与 `AgentContextCompactor`。

- 模块与目录归属见[工程结构](architecture.md)
- 研究记忆、Agent 工具与实测召回边界见[研究记忆](agent-memory.md)
- 离线回归评测与各版本实测记录见[验证记录](mvp-status.md)

CloudKit 自动同步、扫描件 OCR 与 HTML 手写仍属后续规划。默认自动化测试使用本地 fixture 与离线 HTTP Cassette / 假服务；真实模型与真机性能另行验收。
