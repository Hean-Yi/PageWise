# 技术现状

PageWise 基于 **Swift 6、SwiftUI 与结构化并发**实现，最低支持 **macOS 15** / 暂定 **iPadOS 18**。下表仅列出当前代码实际使用的技术组件与职责，不把系统框架能力等同于已上线功能。

| 技术 / 组件 | 当前实际职责 |
| --- | --- |
| **SwiftUI / AppKit / UIKit** | 主界面、原生拖放、书架封面 GPU 动画与平台交互桥接 |
| **PDFKit** | 原版 PDF 校验、展示、文本选择、目录识别、逐句字符定位与历史固定页读取 |
| **SwiftSoup / WebKit** | 静态 HTML 净化、连续双语阅读画布、独立语言选区与实时 Markdown/LaTeX 页边笔记 |
| **JavaScriptCore / KaTeX** | 将受支持的 LaTeX 公式在本地编译为静态 MathML |
| **ImageIO / CoreGraphics** | 源码图件与 PDF 原页裁片本地解码（含独立 PDF 图件） |
| **SQLite（含 FTS5）** | 按记录事务保存书库快照与显式迁移；代次并发保护；`FTS5` BM25 论文检索、研究来源事件表与整理租约 |
| **Core ML / Accelerate / 词项索引** | 随包内置约 61 MB 的 4-bit 量化 `multilingual-e5-small` Core ML 模型，结合渐进式冷启动与覆盖度门控执行设备端中英混合检索 |
| **URLSession** | arXiv / Crossref / DBLP / Semantic Scholar 多源并发检索、限量流式下载、模型 SSE（含思考流）与有界工具循环 |
| **Keychain** | 按服务地址隔离保存设备本地 API 密钥 |
| **PencilKit** | iPad 原版 PDF 与历史固定页手写批注 |

## 处理路线与边界
- **在线论文**：采用有界静态解析处理同版本 TeX 或 HTML，不执行源码中的宏脚本。
- **本地 PDF**：在设备上独立完成自然段提取、图表与规则表格识别及按页缓存翻译。
- **双入口科研助理**：共用 `PaperReaderKit` 中的 `AgentLoopRunner` 与 `AgentContextCompactor`，支持离线 HTTP Cassette 轨迹回归。
- **尚未接入**：iCloud / CloudKit 自动同步、扫描件 OCR 与 HTML 手写仍属后续规划。

相关文档：[工程结构](architecture.md) · [研究记忆设计](agent-memory.md) · [验证记录](mvp-status.md)
