# 技术现状

本地 MVP 使用 Swift 6、SwiftUI 与结构化并发，最低 macOS 15 / 暂定 iPadOS 18。以下是仓库实际职责，不代表平台能力已全部接入。

| 技术 | 当前用途 |
| --- | --- |
| SwiftUI / AppKit / UIKit | 页面与平台交互 |
| PDFKit | 原版导入检查、展示、选择、目录、逐句字符定位和历史固定页读取 |
| SwiftSoup / WebKit | 静态 HTML 解析与本地连续阅读 |
| JavaScriptCore / KaTeX | 受支持 LaTeX 编译为 MathML |
| ImageIO / CoreGraphics | 源码图件本地解码，含独立 PDF 图片 |
| SQLite | 书库按记录事务保存，旧快照在打开时迁移；代次校验保护多个应用实例的写入 |
| 词项索引、Core ML 与 Accelerate | 分开检索原文、阅读笔记和研究记忆。可选的 multilingual-e5-small 在设备上编码中英文，SQLite 保存可重建的向量，查询按书库范围和来源修订筛选。 |
| URLSession | 多源在线检索、限量流式下载、模型 SSE 与工具调用 |
| Keychain | 设备独立凭据 |
| PencilKit | iPad 原版 PDF 与历史固定页笔迹 |

在线论文采用有界静态解析处理 TeX 或同版本 HTML。本地导入的 PDF 使用独立的设备端段落提取与图表裁片流程。图片、翻译、文件发布和界面协调的代码位置见[工程结构](architecture.md)。科研助手的记忆来源、撤回与查询方式见[研究记忆](agent-memory.md)。

CloudKit 自动同步与 HTML 手写属于后续规划。默认测试使用本地素材和假服务；真实模型和真机性能另行验收。
