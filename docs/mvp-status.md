# MVP 交付状态

日期：2026-11-13。范围：可运行的本地 MVP，尚不是完整设计中的同步版本。

## 已实现

- SwiftUI Mac / iPad 工程，最低运行目标为 macOS 15 / iPadOS 18。Mac 本地 ad-hoc 签名包含沙盒、网络、用户选中文件与持久目录书签权限。
- Mac 拖拽一个或多个 PDF、系统选择器导入；复制并按哈希去重，不修改来源文件。
- 本地 PDF 单栏/简单双栏提取、可选文字的原文重排、分页、原文页码定位。生成页面不是整页截图。
- GLM / 兼容 HTTPS 接口、本机 Keychain、按段缓存、分批追加双语页、暂停和重启后继续。截断或无效响应不会作为完整译文发布。
- 原始 PDF、原文重排与双语页切换；文字高亮、iPad PencilKit 手写保存和 PNG 预览/笔记附件。
- 当前论文优先的文字问答，选区对应原块优先保留，辅助论文与授权目录中的笔记参与检索。引用 ID 验证，点击论文证据跳转原文页。
- 自动研究记忆：根据讨论提取有来源的关注点，提取失败时保留原问题。用户可修正和删除，旧记录不会自动重新生成。
- 论文总结；手动保存 Obsidian，讨论整理单独询问；管理区哈希冲突保护，写入恢复日志防止笔记与书库关联状态中断。
- 阅读日历、估计时长、补记及删除错误记录；同一天重叠时段取并集。
- 窄窗口优先展示阅读内容，讨论改为弹出面板；侧栏选择支持折叠导航。

## 实际技术与设计草案的区别

本地 MVP 使用 Core Text 原生排版分支，保留固定页契约；没有先实现 WebKit/HTML/KaTeX 路线。优点是直接验证 PDF 正文可选择和字符完整性，限制是复杂数学/图表目前明确回退。

持久化通过系统 SQLite 的小型 actor 包装保存版本化书库快照，支持事务与版本检查；尚未引入 GRDB 和 FTS5。检索采用 NaturalLanguage 分词及选区/结构优先排序。快照存储适合当前小型书库；扩大资料量前应迁移到按记录的表和全文索引，不能删库重建。

已经保留段落 ID、固定页 ID、原始页码、缓存与恢复进度。尚未实现完整 LayoutRevision 分支管理、云同步 outbox、跨设备合并、资料导出/导入包。这些属于完整设计后续阶段。

## 本轮验证

| Check | Result |
| --- | --- |
| swift-format strict | PASS |
| Swift tests | 26 PASS |
| PDF tests (subset) | 11 PASS |
| ReaderSmoke | PASS |
| macOS application build | PASS |
| iPad simulator application build | PASS |
| Mac ad-hoc signature + entitlements | PASS |
| PDF visual inspection | PASS |
| GUI interaction | NOT VERIFIED |
| Real GLM account | NOT VERIFIED |
| Physical Pencil device | NOT VERIFIED |
| macOS 15 / iPadOS 18 runtime | NOT VERIFIED |
| CloudKit | NOT IMPLEMENTED |

测试覆盖：本地原文保留、无效文件拒绝、单/双栏顺序、扫描/图形降级、原始批注不丢弃、双语长段落逐字符完整性、旧页面不变、源页映射、数据库重启、模型截断/鉴权失败、晚段落和中文选区的证据优先、Obsidian 用户区保留和中断恢复、阅读时间并集，以及带测试模型的导入→翻译→高亮→问答→重启工作流。

本轮也进行两阶段独立审查。修复了未提交页面可能显示、选区被上下文预算挤出、笔记写入与数据库关联中断、扫描件仅凭辅助资料作答、Mac 目录书签权限和 iPad 折叠导航问题。

页面视觉检查使用本地生成的原创文档，包括双语首页和长段落续页；不等于已用真实论文集证明普遍排版质量。26 项测试中的模型响应和 arXiv feed 使用测试 transport，未消费用户 API 额度。

## 尚需使用者验证

1. 在 Mac 实际从 Finder 拖拽自己的文字型 PDF，检查导入、文字选择和引用跳转。
2. 在模型设置填入真实账户的基础地址、模型名称与密钥，验证翻译、问答和讨论整理。
3. 在 iPad 真机验证 Pencil 工具、缩放/翻页后笔迹位置、目录授权和重启恢复。
4. 使用实际 Obsidian iCloud 子目录检查文件下载、外部编辑和冲突状态；当前测试使用本地临时目录。
5. 旧系统与多样真实论文验收后，再扩展 HTML/复杂图表解析及语义检索。

Computer Use 自动审批拒绝了操作 PaperReader 应用窗口。本轮保留构建、服务/工作流测试和离线页面视觉检查结果，未将它们冒充交互式验收。
