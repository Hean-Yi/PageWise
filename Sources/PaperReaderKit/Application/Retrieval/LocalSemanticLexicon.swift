import Foundation

/// A tiny, code-reviewed bilingual research vocabulary. It is deliberately not a general
/// translation dictionary: it only bridges common experimental language so the lexical fallback
/// does not miss obvious cross-language notes. No model, network or downloaded asset is involved.
public enum LocalSemanticLexicon {
    private static let phrases: [(String, String)] = [
        ("重复抽取", "resampling"), ("重复采样", "resampling"), ("重采样", "resampling"),
        ("wall clock", "wall_clock"), ("training set", "training_set"), ("test split", "test_set"),
        ("low resource", "low_resource"), ("nearest neighbor", "neighbor"),
        ("positional encoding", "positional_encoding"),
        ("majority vote", "majority_vote"), ("batch size", "batch_size"), ("held-out", "heldout"),
        ("held out", "heldout"), ("overfits", "overfit"), ("overfit", "overfit"),
    ]

    private static let concepts: [String: String] = [
        "accuracy": "accuracy", "准确率": "accuracy", "准确": "accuracy", "正确率": "accuracy",
        "correctness": "correctness", "正确性": "correctness", "答对": "correctness", "error": "error",
        "误差": "error", "错误": "error", "calibration": "calibration", "校准": "calibration",
        "标定": "calibration", "confidence": "confidence", "置信": "confidence", "把握": "confidence",
        "信心": "confidence", "significance": "significance", "显著": "significance", "显著性": "significance",
        "statistical": "statistical", "统计": "statistical", "variance": "variance", "方差": "variance",
        "波动": "variance", "不确定性": "variance", "interval": "interval", "区间": "interval",
        "bootstrap": "bootstrap", "自助": "bootstrap", "重采样": "resampling", "resample": "resampling",
        "median": "median", "中位数": "median", "典型值": "median", "baseline": "baseline",
        "基线": "baseline", "对照": "baseline", "ablation": "ablation", "消融": "ablation",
        "拆开": "ablation", "部件": "component", "component": "component", "evaluation": "evaluation",
        "评估": "evaluation", "评测": "evaluation", "考卷": "test", "test": "test",
        "测试": "test", "验证": "validation", "validation": "validation", "contaminate": "contaminate",
        "污染": "contaminate", "泄漏": "contaminate", "偷看": "contaminate", "sample": "sample",
        "样本": "sample", "样本量": "sample_size", "sample size": "sample_size", "dataset": "dataset",
        "数据集": "dataset", "语料": "corpus", "corpus": "corpus", "duplicate": "duplicate",
        "重复": "duplicate", "去重": "deduplicate", "deduplicate": "deduplicate", "improvement": "improvement",
        "提升": "improvement", "增益": "improvement", "gain": "improvement", "dialect": "dialect",
        "方言": "dialect", "低资源": "low_resource", "low-resource": "low_resource", "compute": "compute",
        "算力": "compute", "计算": "compute", "compute budget": "compute_budget", "计算预算": "compute_budget",
        "预算": "budget", "budget": "budget", "equal": "equal", "matched": "equal",
        "matching": "equal", "match": "equal", "相同": "equal", "匹配": "equal",
        "对齐": "equal", "相等": "equal", "training": "training", "训练": "training",
        "train": "training", "微调": "finetuning", "finetuning": "finetuning", "fine-tuning": "finetuning",
        "调参": "finetuning", "time": "time", "时间": "time", "时长": "duration",
        "duration": "duration", "wall": "wall", "clock": "wall", "总时长": "duration",
        "迭代": "steps", "steps": "steps", "步数": "steps", "optimizer": "optimizer",
        "优化器": "optimizer", "优化": "optimization", "optimization": "optimization", "latency": "latency",
        "延迟": "latency", "响应": "latency", "throughput": "throughput", "吞吐量": "throughput",
        "inference": "inference", "推理": "inference", "deployment": "deployment", "上线": "deployment",
        "部署": "deployment", "model": "model", "模型": "model", "method": "method",
        "方法": "method", "diffusion": "diffusion", "扩散": "diffusion", "denoising": "denoising",
        "去噪": "denoising", "image": "image", "图像": "image", "generation": "generation",
        "生成": "generation", "checkpoint": "checkpoint", "检查点": "checkpoint", "权重": "weight",
        "weight": "weight", "parameter": "parameter", "参数": "parameter", "backbone": "backbone",
        "骨干": "backbone", "adapter": "adapter", "适配器": "adapter", "旁路": "adapter",
        "low-rank": "low_rank", "低秩": "low_rank", "frozen": "frozen", "冻结": "frozen",
        "retrieval": "retrieval", "检索": "retrieval", "embedding": "embedding", "向量": "embedding",
        "vector": "vector", "向量库": "vector", "memory": "memory", "记忆": "memory",
        "cache": "cache", "缓存": "cache", "eviction": "eviction", "淘汰": "eviction",
        "discard": "discard", "丢弃": "discard", "recent": "recent", "最近": "recent",
        "note": "note", "笔记": "note", "citation": "citation", "引用": "citation",
        "evidence": "evidence", "证据": "evidence", "出处": "source", "source": "source",
        "document": "document", "文档": "document", "neighbor": "neighbor", "近邻": "neighbor",
        "withdrawn": "withdrawn", "撤回": "withdrawn", "deleted": "deleted", "删除": "deleted",
        "conflict": "conflict", "冲突": "conflict", "similar": "similar", "相似": "similar",
        "emotion": "emotion", "情绪": "emotion", "speech": "speech", "语音": "speech",
        "annotator": "annotator", "标注者": "annotator", "标注": "annotation", "annotation": "annotation",
        "disagreement": "disagreement", "分歧": "disagreement", "因人而异": "disagreement", "intervention": "intervention",
        "干预": "intervention", "random": "random", "随机": "random", "抽签": "random",
        "cause": "cause", "因果": "cause", "correlation": "correlation", "相关": "correlation",
        "battery": "battery", "电池": "battery", "capacity": "capacity", "容量": "capacity",
        "degradation": "degradation", "衰减": "degradation", "cycle": "cycle", "循环": "cycle",
        "token": "token", "词元": "token", "tokens": "token", "request": "request",
        "requests": "request", "请求": "request", "slow": "slow", "卡": "slow",
        "慢": "slow", "响应慢": "slow", "hide": "hide", "hides": "hide",
        "掩盖": "hide", "隐藏": "hide", "occasional": "occasional", "少数": "occasional",
        "偶尔": "occasional", "tuning": "finetuning", "调优": "finetuning", "matrix": "matrix",
        "矩阵": "matrix", "update": "update", "更新": "update", "kept": "retain",
        "retained": "retain", "remove": "remove", "removed": "remove", "eliminate": "remove",
        "eliminated": "remove", "消除": "remove", "去掉": "remove", "resampling": "resampling",
        "重复抽取": "resampling", "抽取": "resampling", "内存": "cache", "full": "full",
        "满": "full", "entry": "entry", "entries": "entry", "条目": "entry",
        "内容": "entry", "access": "access", "访问": "access", "unused": "recent",
        "最久没访问": "recent", "low": "low_resource", "resource": "resource", "资源": "resource",
        "missing": "missing", "遗漏": "missing", "inflate": "inflate", "夸大": "inflate",
        "乐观": "inflate", "measured": "measured", "测量": "measured", "成绩": "accuracy",
        "exclude": "exclude", "excluded": "exclude", "不包含": "exclude", "排除": "exclude",
        "nearest": "neighbor", "neighbors": "neighbor", "select": "select", "selecting": "select",
        "挑": "select", "选择": "select", "final": "final", "最终": "final",
        "answer": "answer", "答案": "answer", "machine": "machine", "机器": "machine",
        "individual": "individual", "各个": "individual", "single": "individual", "单独": "individual",
        "module": "module", "模块": "module", "reveal": "reveal", "reveals": "reveal",
        "看出": "reveal", "account": "account", "accounts": "account", "contribution": "account",
        "贡献": "account", "components": "component", "decoder": "decoder", "decoders": "decoder",
        "解码器": "decoder", "关注": "attend", "attends": "attend", "attend": "attend",
        "previous": "previous", "此前": "previous", "之前": "previous", "all": "all",
        "所有": "all", "sampler": "sampler", "采样器": "sampler", "temperature": "temperature",
        "温度": "temperature", "diverse": "diverse", "多样": "diverse", "output": "output",
        "outputs": "output", "输出": "output", "robust": "robust", "鲁棒": "robust",
        "稳定": "robust", "overfit": "overfit", "overfits": "overfit", "过拟合": "overfit",
        "quantization": "quantization", "量化": "quantization", "shift": "shift", "偏移": "shift",
        "sparse": "sparse", "稀疏": "sparse", "pruning": "pruning", "剪枝": "pruning",
        "cost": "cost", "成本": "cost", "batch": "batch", "批": "batch",
        "retain": "retain", "保留": "retain",
    ]

    public static func phraseConcepts(in value: String) -> Set<String> {
        let lowered = value.lowercased()
        var result: Set<String> = []
        for (phrase, concept) in phrases where lowered.contains(phrase) {
            result.insert("concept:\(concept)")
        }
        return result
    }

    public static func concepts(for token: String) -> Set<String> {
        if let canonical = concepts[token] { return ["concept:\(canonical)"] }
        // Small deterministic morphology for English plurals/inflections. It is intentionally
        // conservative; irregular forms stay covered by explicit entries.
        for suffix in ["ies", "es", "s", "ing", "ed"] where token.count > suffix.count + 2 {
            guard token.hasSuffix(suffix) else { continue }
            let stem = String(token.dropLast(suffix.count))
            if let canonical = concepts[stem] { return ["concept:\(canonical)"] }
        }
        return []
    }
}
