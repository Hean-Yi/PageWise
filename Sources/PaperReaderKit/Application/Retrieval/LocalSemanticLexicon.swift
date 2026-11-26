import Foundation

/// A tiny, code-reviewed bilingual research vocabulary. It is deliberately not a general
/// translation dictionary: it only bridges common experimental language so the lexical fallback
/// does not miss obvious cross-language notes. No model, network or downloaded asset is involved.
public enum LocalSemanticLexicon {
    private static let concepts: [String: String] = [
        // Evaluation and statistics.
        "accuracy": "accuracy", "准确率": "accuracy", "准确": "accuracy", "正确率": "accuracy",
        "correctness": "correctness", "正确性": "correctness", "答对": "correctness",
        "error": "error", "误差": "error", "错误": "error",
        "calibration": "calibration", "校准": "calibration", "标定": "calibration",
        "confidence": "confidence", "置信": "confidence", "把握": "confidence", "信心": "confidence",
        "significance": "significance", "显著": "significance", "显著性": "significance",
        "statistical": "statistical", "统计": "statistical",
        "variance": "variance", "方差": "variance", "波动": "variance", "不确定性": "variance",
        "interval": "interval", "区间": "interval",
        "bootstrap": "bootstrap", "自助": "bootstrap", "重采样": "resampling", "resample": "resampling",
        "median": "median", "中位数": "median", "典型值": "median",
        "baseline": "baseline", "基线": "baseline", "对照": "baseline",
        "ablation": "ablation", "消融": "ablation", "拆开": "ablation", "部件": "component", "component": "component",
        "evaluation": "evaluation", "评估": "evaluation", "评测": "evaluation", "考卷": "test",
        "test": "test", "测试": "test", "验证": "validation", "validation": "validation",
        "contaminate": "contaminate", "污染": "contaminate", "泄漏": "contaminate", "偷看": "contaminate",
        "sample": "sample", "样本": "sample", "样本量": "sample_size", "sample size": "sample_size",
        "dataset": "dataset", "数据集": "dataset", "语料": "corpus", "corpus": "corpus",
        "duplicate": "duplicate", "重复": "duplicate", "去重": "deduplicate", "deduplicate": "deduplicate",
        "improvement": "improvement", "提升": "improvement", "增益": "improvement", "gain": "improvement",
        "dialect": "dialect", "方言": "dialect", "低资源": "low_resource", "low-resource": "low_resource",

        // Conditions, resources and time.
        "compute": "compute", "算力": "compute", "计算": "compute", "compute budget": "compute_budget",
        "计算预算": "compute_budget", "预算": "budget", "budget": "budget",
        "equal": "equal", "matched": "equal", "matching": "equal", "match": "equal", "相同": "equal",
        "匹配": "equal", "对齐": "equal", "相等": "equal",
        "training": "training", "训练": "training", "train": "training", "微调": "finetuning",
        "finetuning": "finetuning", "fine-tuning": "finetuning", "调参": "finetuning",
        "time": "time", "时间": "time", "时长": "duration", "duration": "duration", "wall": "wall",
        "clock": "wall", "总时长": "duration", "迭代": "steps", "steps": "steps", "步数": "steps",
        "optimizer": "optimizer", "优化器": "optimizer", "优化": "optimization", "optimization": "optimization",
        "latency": "latency", "延迟": "latency", "响应": "latency", "throughput": "throughput", "吞吐量": "throughput",
        "inference": "inference", "推理": "inference", "deployment": "deployment", "上线": "deployment", "部署": "deployment",

        // Models, methods and representations.
        "model": "model", "模型": "model", "method": "method", "方法": "method",
        "diffusion": "diffusion", "扩散": "diffusion", "denoising": "denoising", "去噪": "denoising",
        "image": "image", "图像": "image", "generation": "generation", "生成": "generation",
        "checkpoint": "checkpoint", "检查点": "checkpoint", "权重": "weight", "weight": "weight",
        "parameter": "parameter", "参数": "parameter", "backbone": "backbone", "骨干": "backbone",
        "adapter": "adapter", "适配器": "adapter", "旁路": "adapter", "low-rank": "low_rank", "低秩": "low_rank",
        "frozen": "frozen", "冻结": "frozen", "retrieval": "retrieval", "检索": "retrieval",
        "embedding": "embedding", "向量": "embedding", "vector": "vector", "向量库": "vector",
        "memory": "memory", "记忆": "memory", "cache": "cache", "缓存": "cache", "eviction": "eviction",
        "淘汰": "eviction", "discard": "discard", "丢弃": "discard", "recent": "recent", "最近": "recent",
        "note": "note", "笔记": "note", "citation": "citation", "引用": "citation",
        "evidence": "evidence", "证据": "evidence", "出处": "source", "source": "source",
        "document": "document", "文档": "document", "neighbor": "neighbor", "近邻": "neighbor",
        "withdrawn": "withdrawn", "撤回": "withdrawn", "deleted": "deleted", "删除": "deleted",
        "conflict": "conflict", "冲突": "conflict", "similar": "similar", "相似": "similar",
        "emotion": "emotion", "情绪": "emotion", "speech": "speech", "语音": "speech",
        "annotator": "annotator", "标注者": "annotator", "标注": "annotation", "annotation": "annotation",
        "disagreement": "disagreement", "分歧": "disagreement", "因人而异": "disagreement",
        "intervention": "intervention", "干预": "intervention", "random": "random", "随机": "random",
        "抽签": "random", "cause": "cause", "因果": "cause", "correlation": "correlation", "相关": "correlation",
        "battery": "battery", "电池": "battery", "capacity": "capacity", "容量": "capacity",
        "degradation": "degradation", "衰减": "degradation", "cycle": "cycle", "循环": "cycle",
        "token": "token", "词元": "token", "tokens": "token",
    ]

    public static func concepts(for token: String) -> Set<String> {
        let canonical = concepts[token].map { ["concept:\($0)"] } ?? []
        // Multiword English concepts are already split by the tokenizer; a token such as
        // "fine-tuning" remains one token and is handled directly by the dictionary.
        return Set(canonical)
    }
}
