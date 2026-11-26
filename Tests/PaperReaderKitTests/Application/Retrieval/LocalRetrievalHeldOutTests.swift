import Foundation
import Testing

@testable import PaperReaderKit

@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_BENCH_LOCAL_HELDOUT"] == "1"))
func localLexiconHeldOutCrossLanguageRanking() async throws {
    let pairs: [(String, String)] = [
        ("The optimizer used less wall-clock time per epoch.", "每个训练轮次占用的实际时间更少。"),
        ("The method is robust to missing labels.", "标签缺失时方法仍然稳定。"),
        ("Reranking improves retrieval precision.", "重排序提升了检索精度。"),
        ("The model overfits the small training set.", "模型在很小的训练集上过拟合。"),
        ("Calibration curves shift after quantization.", "量化后校准曲线发生偏移。"),
        ("The cache is cleared between runs.", "每次运行之间清空缓存。"),
        ("Annotations were aggregated by majority vote.", "标注通过多数投票汇总。"),
        ("The ablation removes the positional encoding.", "消融实验去掉了位置编码。"),
        ("Latency grows with the number of retrieved passages.", "检索到的段落越多，延迟越高。"),
        ("The baseline uses a larger batch size.", "基线使用更大的批大小。"),
        ("Inference cost dominates the total budget.", "推理成本占总预算的主要部分。"),
        ("The model was evaluated on a held-out test split.", "模型在留出的测试集上评估。"),
        ("The decoder attends to all previous tokens.", "解码器会关注此前出现过的所有词元。"),
        ("Sparse pruning reduces memory without losing accuracy.", "稀疏剪枝降低了内存占用，同时没有损失准确率。"),
        ("The sampler produces diverse outputs at higher temperature.", "提高温度后采样器会产生更多样的输出。"),
        ("The policy was trained with human preference feedback.", "该策略使用人类偏好反馈进行训练。"),
    ]
    let encoder: (any SemanticTextEncoder)? = nil
    let notes = pairs.map { pair in
        ReadingNote(paperID: UUID(), contentVersion: "heldout", anchors: [], markdown: pair.0)
    }
    let titles = Dictionary(uniqueKeysWithValues: notes.map { ($0.paperID, "Held-out collection") })
    let index = ReadingNoteMemoryIndex(encoder: encoder)
    var ranks: [Int] = []
    for (offset, pair) in pairs.enumerated() {
        let hits = try await index.search(
            query: pair.1, notes: notes, paperTitles: titles, limit: 5, mode: .lexical)
        let rank = hits.firstIndex(where: { $0.readingNoteID == notes[offset].id }).map { $0 + 1 } ?? 0
        ranks.append(rank)
        print("LOCAL_HELDOUT", offset, "rank", rank, "query", pair.1)
    }
    print(
        "LOCAL_HELDOUT_TOTAL", "top1", ranks.filter { $0 == 1 }.count, "top5", ranks.filter { $0 > 0 }.count,
        "mrr", ranks.reduce(0.0) { $0 + ($1 > 0 ? 1 / Double($1) : 0) } / Double(ranks.count))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_BENCH_LOCAL_UNSEEN"] == "1"))
func localLexiconUnseenCrossLanguageRanking() async throws {
    let pairs: [(String, String)] = [
        ("The model distills a larger teacher into a smaller student.", "模型把较大的教师网络蒸馏到较小的学生网络。"),
        ("Gradient clipping stabilizes training when the loss spikes.", "损失突然变大时，梯度裁剪能让训练更稳定。"),
        ("The classifier is biased toward the majority class.", "分类器偏向多数类。"),
        ("Beam search keeps the top candidates at every step.", "束搜索在每一步保留得分最高的候选。"),
        ("The dataset contains duplicated questions.", "数据集中包含重复的问题。"),
        ("The model uses mixed precision to save memory.", "模型使用混合精度来节省内存。"),
        ("Contrastive loss pulls positive pairs together.", "对比损失把正样本对拉近。"),
        ("The server batches requests to improve throughput.", "服务器批量处理请求以提高吞吐量。"),
        ("The paper reports confidence intervals for every metric.", "论文为每个指标报告置信区间。"),
        ("The model was pruned before deployment.", "模型在部署前被剪枝。"),
        ("The retriever uses a cross encoder for reranking.", "检索器使用交叉编码器进行重排序。"),
        ("The evaluation excludes examples with missing labels.", "评估排除了标签缺失的样本。"),
    ]
    let notes = pairs.map { pair in
        ReadingNote(paperID: UUID(), contentVersion: "unseen", anchors: [], markdown: pair.0)
    }
    let titles = Dictionary(uniqueKeysWithValues: notes.map { ($0.paperID, "Unseen collection") })
    let index = ReadingNoteMemoryIndex(encoder: nil)
    var ranks: [Int] = []
    for (offset, pair) in pairs.enumerated() {
        let hits = try await index.search(
            query: pair.1, notes: notes, paperTitles: titles, limit: 5, mode: .lexical)
        let rank = hits.firstIndex(where: { $0.readingNoteID == notes[offset].id }).map { $0 + 1 } ?? 0
        ranks.append(rank)
        print("LOCAL_UNSEEN", offset, "rank", rank, "query", pair.1)
    }
    print(
        "LOCAL_UNSEEN_TOTAL", "top1", ranks.filter { $0 == 1 }.count, "top5", ranks.filter { $0 > 0 }.count,
        "mrr", ranks.reduce(0.0) { $0 + ($1 > 0 ? 1 / Double($1) : 0) } / Double(ranks.count))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_BENCH_E5_UNSEEN"] == "1"))
func e5UnseenCrossLanguageRanking() async throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(
        fileURLWithPath: try #require(environment["PAGEWISE_BENCH_MODEL_PARENT"]), isDirectory: true)
    let encoder = DeviceSemanticEncoder(directory: directory)
    let pairs: [(String, String)] = [
        ("The model distills a larger teacher into a smaller student.", "模型把较大的教师网络蒸馏到较小的学生网络。"),
        ("Gradient clipping stabilizes training when the loss spikes.", "损失突然变大时，梯度裁剪能让训练更稳定。"),
        ("The classifier is biased toward the majority class.", "分类器偏向多数类。"),
        ("Beam search keeps the top candidates at every step.", "束搜索在每一步保留得分最高的候选。"),
        ("The dataset contains duplicated questions.", "数据集中包含重复的问题。"),
        ("The model uses mixed precision to save memory.", "模型使用混合精度来节省内存。"),
        ("Contrastive loss pulls positive pairs together.", "对比损失把正样本对拉近。"),
        ("The server batches requests to improve throughput.", "服务器批量处理请求以提高吞吐量。"),
        ("The paper reports confidence intervals for every metric.", "论文为每个指标报告置信区间。"),
        ("The model was pruned before deployment.", "模型在部署前被剪枝。"),
        ("The retriever uses a cross encoder for reranking.", "检索器使用交叉编码器进行重排序。"),
        ("The evaluation excludes examples with missing labels.", "评估排除了标签缺失的样本。"),
    ]
    let notes = pairs.map { pair in
        ReadingNote(paperID: UUID(), contentVersion: "unseen", anchors: [], markdown: pair.0)
    }
    let titles = Dictionary(uniqueKeysWithValues: notes.map { ($0.paperID, "Unseen collection") })
    let minimumScore = environment["PAGEWISE_BENCH_MINSCORE"].flatMap(Float.init)
    let index = ReadingNoteMemoryIndex(encoder: encoder, minimumScore: minimumScore)
    var ranks: [Int] = []
    for (offset, pair) in pairs.enumerated() {
        let hits = try await index.search(
            query: pair.1, notes: notes, paperTitles: titles, limit: 5, mode: .hybrid)
        let rank = hits.firstIndex(where: { $0.readingNoteID == notes[offset].id }).map { $0 + 1 } ?? 0
        ranks.append(rank)
    }
    print(
        "E5_UNSEEN_TOTAL", "top1", ranks.filter { $0 == 1 }.count, "top5", ranks.filter { $0 > 0 }.count,
        "mrr", ranks.reduce(0.0) { $0 + ($1 > 0 ? 1 / Double($1) : 0) } / Double(ranks.count))
}
