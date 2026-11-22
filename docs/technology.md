# 技术现状

本地 MVP 使用 Swift 6、SwiftUI 与结构化并发，最低 macOS 15 / 暂定 iPadOS 18。以下是仓库实际职责，不代表平台能力已全部接入。

| 技术 | 当前用途 |
| --- | --- |
| SwiftUI / AppKit / UIKit | 页面与平台交互 |
| PDFKit | 原版导入检查、展示、选择、目录、逐句字符定位和历史固定页读取 |
| SwiftSoup / WebKit | 静态 HTML 解析与本地连续阅读 |
| JavaScriptCore / KaTeX | 受支持 LaTeX 编译为 MathML |
| ImageIO / CoreGraphics | 源码图件本地解码，含独立 PDF 图片 |
| SQLite | 版本化本地快照与事务保存 |
| URLSession | arXiv 下载与模型 SSE / 工具调用 |
| Keychain | 设备独立凭据 |
| PencilKit | iPad 原版 PDF 与历史固定页笔迹 |

TeX 采用有界静态解析，不执行下载包。源码双语重排只接受 TeX 或同版本 HTML；没有 PDF 正文转换/OCR 依赖。图片、翻译、文件发布和业务/UI 协调分别组织，见 [工程结构](architecture.md)。

CloudKit 自动同步、HTML 手写、向量检索尚未接入。默认测试使用本地素材和假服务；真实模型和真机性能另行验收。
