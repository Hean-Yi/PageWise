import Darwin
import Foundation
import PaperReaderKit
import Testing

/// Optional device benchmark. Supply the installed model directory; ordinary CI stays offline.
@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["PAGEWISE_BENCH_MODEL"] != nil
            || ProcessInfo.processInfo.environment["PAGEWISE_BENCH_LOCAL"] == "1"))
func measureInstalledSemanticRetrieval() async throws {
    let env = ProcessInfo.processInfo.environment
    let local = env["PAGEWISE_BENCH_LOCAL"] == "1"
    let encoder: DeviceSemanticEncoder? =
        local
        ? nil
        : DeviceSemanticEncoder(directory: URL(fileURLWithPath: try #require(env["PAGEWISE_BENCH_MODEL"])))
    if let encoder { #expect(await encoder.isInstalled()) }
    let clock = ContinuousClock()
    func ms(_ start: ContinuousClock.Instant) -> Double {
        let d = (clock.now - start).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
    let start = clock.now
    if let encoder {
        #expect(try await encoder.encode(["首次启动。"], as: .query).first?.count == 384)
        print("QUALITY cold_model_and_first_query_ms", ms(start))
    }
    var examples: [(text: String, query: String, category: String)] = [
        ("The diffusion sampler uses fewer denoising steps to generate each image.", "图像从噪点变清晰要迭代几次", "cross"),
        ("A smaller calibration error means confidence matches observed correctness.", "输出的把握程度是否符合实际答对的比例", "cross"),
        (
            "Comparisons match wall clock training time across the two optimization methods.", "两个优化器占用机器的总时长是否相等",
            "cross"
        ),
        ("Removing individual components reveals which module accounts for the gain.", "把各个部件拆开测才能看出是谁贡献了提升", "cross"),
        ("Selecting a checkpoint on the test split contaminates the evaluation.", "靠最终考卷挑模型是不是偷看答案", "cross"),
        ("The median hides occasional requests with extremely slow responses.", "典型值会不会掩盖少数请求卡很久的问题", "cross"),
        ("Low rank adapters leave most backbone parameters frozen during tuning.", "微调时只更新很小的旁路矩阵", "cross"),
        ("Annotators disagree about which emotion the speaker expresses.", "同一段语音的情绪标签为什么因人而异", "cross"),
        ("The intervention was randomly assigned to disentangle cause and correlation.", "抽签分组怎样帮助判断因果关系", "cross"),
        ("Bootstrap intervals quantify variability under resampling observations.", "重复抽取已有数据能估计统计结果的不确定性吗", "cross"),
        ("A cache eviction policy discards entries that have not been used recently.", "内存满了优先丢掉最久没访问的内容", "cross"),
        ("Training on earlier dates and evaluating on later dates mimics deployment.", "按时间先后拆分样本可以模拟上线吗", "cross"),
        ("电池充放电多次后，容量的下降幅度逐渐放缓。", "Does capacity degradation slow after repeated cycles?", "cross"),
        ("测试集中遗漏了资源最少的方言，所以平均成绩过于乐观。", "Missing low resource dialects could inflate measured accuracy.", "cross"),
        ("向量数据库记录的近邻不包含文档删除后遗留的片段。", "Are withdrawn documents excluded from nearest neighbors?", "cross"),
        ("作者让模型在回答前检索可定位证据，并逐项检查出处。", "Citations were checked against retrievable evidence.", "cross"),
        (
            "The corpus kept repeated training documents, so duplicates may explain the improvement.",
            "Which training set retained duplicates?", "polarity"
        ),
        (
            "The corpus removed repeated training documents before measuring improvement.",
            "Which training set eliminated duplicates?", "polarity"
        ),
        (
            "Training budget was fixed by the number of tokens rather than elapsed time.",
            "Which run used a fixed token count?", "polarity"
        ),
        ("RZQ-7391 indexes the multilingual evaluation split.", "RZQ-7391", "identifier"),
        ("LNKT-505 is the identifier of the kernel timing trace.", "LNKT-505", "identifier"),
        ("The negative control was registered as VBT-8073.", "VBT-8073", "identifier"),
    ]
    let publicSet = env["PAGEWISE_BENCH_CORPUS"]
    if let publicSet {
        let directory = URL(fileURLWithPath: publicSet)
        func lines(_ name: String) throws -> [String] {
            try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }
        let english = try lines("tatoeba.en")
        let chinese = try lines("tatoeba.zh")
        try #require(chinese.count == 1000 && english.count == chinese.count)
        examples = zip(english, chinese).map { ($0.0, $0.1, "public") }
    }
    let notes = examples.map { item in
        ReadingNote(paperID: UUID(), contentVersion: "bench", anchors: [], markdown: item.text)
    }
    let titles = Dictionary(uniqueKeysWithValues: notes.map { ($0.paperID, "Collection") })
    let index = ReadingNoteMemoryIndex(encoder: encoder)
    let build = clock.now
    _ = try await index.search(query: "", notes: notes, paperTitles: titles, limit: 0)
    print("QUALITY prepare_ms", notes.count, ms(build))
    for (label, mode) in [("lexical", RetrievalMode.lexical), ("semantic", .semantic), ("hybrid", .hybrid)] {
        var timings = [Double]()
        var ranks: [String: [Int]] = [:]
        // Every tenth public query against all 1,000 passages; no privately authored user text.
        for i in examples.indices where publicSet == nil || i % 10 == 0 {
            let now = clock.now
            let hits = try await index.search(
                query: examples[i].query, notes: notes, paperTitles: titles, limit: 5, mode: mode)
            timings.append(ms(now))
            let rank = hits.firstIndex { $0.readingNoteID == notes[i].id }.map { $0 + 1 } ?? 0
            ranks[examples[i].category, default: []].append(rank)
            if env["PAGEWISE_BENCH_DETAIL"] == "1", publicSet == nil {
                print(
                    "QUALITY_DETAIL", label, i, "rank", rank,
                    "query", examples[i].query,
                    "top", hits.prefix(3).map { String($0.text.prefix(60)) })
            }
        }
        for key in ranks.keys.sorted() {
            let r = ranks[key]!
            print(
                "QUALITY", label, key, "n", r.count, "hits@1", r.filter { $0 == 1 }.count, "hits@5",
                r.filter { $0 > 0 }.count,
                "mrr@5", r.reduce(0.0) { $0 + ($1 > 0 ? 1 / Double($1) : 0) } / Double(r.count))
        }
        if publicSet == nil {
            let irrelevant = [
                "歌剧院的演出几点开始", "如何做意式冰淇淋", "How much is a ticket to the opera house?", "谁赢了冬季冰壶比赛", "陶器上的青花纹样是何时出现的",
            ]
            var nonempty = 0
            for q in irrelevant {
                if try await !index.search(query: q, notes: notes, paperTitles: titles, mode: mode).isEmpty {
                    nonempty += 1
                }
            }
            print("QUALITY", label, "irrelevant_hits", nonempty, "/", irrelevant.count)
        }
        timings.sort()
        print(
            "QUALITY", label, "search_p50_ms", timings[timings.count / 2], "p95_ms",
            timings[Int(ceil(Double(timings.count) * 0.95)) - 1])
    }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print("QUALITY process_peak_rss_mib", Double(usage.ru_maxrss) / 1_048_576)
}
