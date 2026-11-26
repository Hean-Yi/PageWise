# E5-small 4-bit 量化实验

分支：`experiment/e5-int4-quantized`

## 方法

源模型是已转换的 `MultilingualE5Small.mlpackage`（FP16，weight 约 235 MB）。

1. 将 Core ML specification version 设为 9（macOS 15 / iOS 18 才能使用 4-bit 权重操作）；
2. 使用 `coremltools.optimize.coreml.palettize_weights`，`nbits=4`、`per_tensor`、k-means LUT；
3. 用 `xcrun coremlcompiler compile` 编译；
4. 保留原 SentencePiece tokenizer。

没有提交模型二进制；本地实验产物位于 `.local/e5-palette-parent`。

## 体积

| 文件 | 大小 |
| --- | ---: |
| 编译后权重 | 56 MB |
| tokenizer | 4.8 MB |
| 安装后目录 | **61 MB** |
| weight SHA-256 | `8a00cee41ea024a4850c6875fb7821ba09904b16f569b8f198e3b664929c8cf3` |

低于 100 MB 目标。

## 质量与性能

使用同一组 16 条跨语言 dev 查询、12 条独立集和 5 条无关查询。

### dev 集

| 模式 | Top-1 | Top-5 | MRR@5 | 无关误召回 |
| --- | ---: | ---: | ---: | ---: |
| 本地 A（词典） | 14/16 | 16/16 | 0.938 | 0/5 |
| 4-bit 纯语义 | 9/16 | 14/16 | 0.679 | 2/5 |
| **4-bit + 本地 A 混合，minScore 0.15** | **14/16** | **16/16** | **0.938** | **0/5** |
| 原 FP16 E5 | 8/16 | 13/16 | 0.630 | 0/5 |

### 未参与调参的 12 条独立集

| 模式 | Top-1 | Top-5 | MRR@5 |
| --- | ---: | ---: | ---: |
| 本地 A | 5/12 | 7/12 | 0.486 |
| **4-bit + 本地 A 混合，minScore 0.15** | **11/12** | **12/12** | **0.944** |
| 原 FP16 E5 | 11/12 | 11/12 | 0.917 |

量化模型在独立集上显著优于本地 A，且与 FP16 E5 的 Top-1 持平、Top-5 更高。

### 运行成本

| 指标 | 4-bit 量化 | 原 FP16 E5 | 本地 A |
| --- | ---: | ---: | ---: |
| 安装后磁盘 | 61 MB | 约 240 MB | 0 |
| 冷启动首个查询 | 约 2.7 s | 约 4.0 s | 0 |
| 22 条笔记准备 | 约 0.38 s | 约 0.43 s | 约 0.05 s |
| 检索 p50 | 约 18 ms | 22 ms | 0.5 ms |
| 检索 p95 | 约 20 ms | 27 ms | 1–3 ms |
| 峰值 RSS | 约 175 MiB | 约 489 MiB | 约 38 MiB |

## 结论与限制

- 61 MB 的 4-bit 模型在独立集上明显优于本地 A，达到“尽量优于 A”的目标；
- 必须使用 **minScore 0.15** 左右的新阈值；沿用原模型的 0.05 会产生 2/5 无关误召回；
- 阈值和混合权重需要在模型更新时重新校准；
- 量化模型仍需要托管 61 MB 资源并更新校验和，当前分支尚未接入下载服务，只完成离线量化与运行验证；
- `per_tensor` 4-bit 明显优于线性 int4（后者 dev 纯语义 6/16、混合 10/14，且无关误召回 5/5）。

## 复现

本机实验使用 `.local/qvenv` 的 coremltools 8.3.0。源模型和 tokenizer 均来自已固定的 Hugging Face revision；量化脚本不进入 App 运行时，也不依赖 Python 服务。

验证：

- 718 项串行测试通过；
- 严格格式检查通过；
- Mac 构建和离线冒烟在 A 分支通过；当前分支只改测试和实验文档，未改 App 运行时代码。
